#!/usr/bin/env python3
"""agent-accounts jobs — see and move Claude background jobs across accounts.

Every Claude account has its own background-agent daemon and jobs/ directory
(lib.sh AA_PRIVATE_claude keeps them out of the shared store on purpose: a
shared daemon would run every job on whichever account happened to start it).
The price is that `claude agents`, `attach`, `logs`, `stop` ... only know the
jobs of the account they run as.  This helper reads across all account stores.

  route    <ref> --current DIR   which other account owns <ref>?   (wrapper.sh)
  agents   [--json] [--all]      one merged list of every account's jobs
  handoff  [<ref>] [--to ACCT]   continue a job's conversation as another account
  live     <session-id>          is a process running that session?
  running  [--json]              every live session, with the account it runs as
  takeover --store DIR           entering an account: other accounts busy? stop them?
  summary                        per-account job counts + isolation checks

Account stores come from the registry (same rule as aa_store_dir in lib.sh: the
native account is the shared dir itself, the others live in <shared>/.accounts).
Listing and acting on jobs go through the wrapper (`bin/claude -u <acct>`) so the
environment is set up exactly as for a normal `claude -u`; only owner lookup
reads files directly (jobs/<id>/state.json), which is cheap and never starts a
daemon.
"""
import argparse
import glob
import json
import os
import shlex
import signal
import subprocess
import sys
import time
import unicodedata

import registry

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
# Flags worth carrying from the original job to its continuation.  Anything else
# in respawnFlags is internal (--reply-on-resume ...) or widens permissions
# (--dangerously-skip-permissions); the latter is better re-stated by the user
# after `--`.
CARRY_FLAGS = ("--model", "--permission-mode", "--effort")
# Entries that must stay real directories in an overlay (see lib.sh).
ISOLATED = ("daemon", "jobs")


# --------------------------------------------------------------------------- #
# output helpers
# --------------------------------------------------------------------------- #
def msg(text):
    print(f"\033[36m[agent-acct]\033[0m {text}", file=sys.stderr)


def warn(text):
    print(f"\033[33m[agent-acct]\033[0m {text}", file=sys.stderr)


def die(text, code=1):
    print(f"\033[31m[agent-acct]\033[0m {text}", file=sys.stderr)
    sys.exit(code)


def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def clip(text, limit):
    if width(text) <= limit:
        return text
    out, used = "", 0
    for c in text:
        if used + width(c) > limit - 1:
            break
        out, used = out + c, used + width(c)
    return out + "…"


def render_table(rows):
    """Header row + aligned columns; pads by display width so CJK lines up.
    (Same output as aa_render_table in lib.sh.)"""
    widths = [max(width(r[i]) for r in rows) for i in range(len(rows[0]))]

    def emit(cells):
        print("  ".join(c + " " * (widths[i] - width(c)) for i, c in enumerate(cells)).rstrip())

    emit(rows[0])
    emit(["-" * w for w in widths])
    for row in rows[1:]:
        emit(row)


def tilde(path):
    return "~" + path[len(HOME):] if path and path.startswith(HOME) else (path or "")


def interactive():
    # AGENT_ACCT_FORCE_INTERACTIVE lets the tests drive the prompts through a pipe.
    return sys.stdin.isatty() or bool(os.environ.get("AGENT_ACCT_FORCE_INTERACTIVE"))


def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        die("입력이 끝나 취소했습니다.")


# --------------------------------------------------------------------------- #
# stores and jobs on disk
# --------------------------------------------------------------------------- #
def shared_dir():
    return os.environ.get("AGENT_ACCT_CLAUDE_HOME") or os.path.join(HOME, ".claude")


def account_stores():
    """[(account id, store dir)] for registered accounts whose store exists."""
    data = registry.load()
    shared = shared_dir()
    out = []
    for acct in sorted(data["accounts"]):
        if registry.mode(data, acct, "claude") == "none":
            continue  # claude disabled for this account (agent-acct disable)
        if registry.mode(data, acct, "claude") == "native":
            path = shared
        else:
            path = os.path.join(shared, ".accounts", acct)
        if os.path.isdir(path):
            out.append((acct, path))
    return out


def has_creds(store):
    try:
        return os.path.getsize(os.path.join(store, ".credentials.json")) > 0
    except OSError:
        return False


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def realpath(path):
    return os.path.realpath(path)


def store_jobs(store):
    """{job id: {id, name, sessionId}} from jobs/<id>/state.json and the roster."""
    jobs = {}
    jobs_dir = os.path.join(store, "jobs")
    try:
        names = os.listdir(jobs_dir)
    except OSError:
        names = []
    for name in names:
        if name.startswith(".") or not os.path.isdir(os.path.join(jobs_dir, name)):
            continue  # pins.json, .draft-*
        st = read_json(os.path.join(jobs_dir, name, "state.json")) or {}
        jobs[name] = {"id": name, "name": st.get("name") or "", "sessionId": st.get("sessionId") or ""}
    roster = read_json(os.path.join(store, "daemon", "roster.json")) or {}
    for short, worker in (roster.get("workers") or {}).items():
        job = jobs.setdefault(short, {"id": short, "name": "", "sessionId": ""})
        job["sessionId"] = job["sessionId"] or (worker or {}).get("sessionId") or ""
    return jobs


def match_tier(job, ref):
    """0 exact id/session, 1 id/session prefix, 2 exact name, 3 name substring."""
    jid, sid, name = job["id"], job["sessionId"], job["name"]
    if ref == jid or (sid and ref == sid):
        return 0
    if len(ref) >= 4 and (jid.startswith(ref) or (sid and sid.startswith(ref))):
        return 1
    if name and ref == name:
        return 2
    if name and ref.lower() in name.lower():
        return 3
    return None


def best_matches(jobs, ref):
    """(tier, [job ids]) for the best tier that matches, else (None, [])."""
    hits = [(match_tier(j, ref), j["id"]) for j in jobs.values()]
    hits = [(t, i) for t, i in hits if t is not None]
    if not hits:
        return None, []
    best = min(t for t, _ in hits)
    return best, sorted(i for t, i in hits if t == best)


def find_all(ref, stores, only_acct=None):
    """Best-tier matches across stores: [(tier, account, job id, store)]."""
    found = []
    for acct, path in stores:
        if only_acct and acct != only_acct:
            continue
        tier, ids = best_matches(store_jobs(path), ref)
        found += [(tier, acct, i, path) for i in ids]
    if not found:
        return []
    best = min(f[0] for f in found)
    return [f for f in found if f[0] == best]


# --------------------------------------------------------------------------- #
# liveness: shared sessions/<pid>.json
# --------------------------------------------------------------------------- #
def proc_stat(pid):
    """(state letter, starttime) from /proc/<pid>/stat, or (None, None)."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as fh:
            rest = fh.read().rsplit(")", 1)[1].split()
        return rest[0], rest[19]
    except (OSError, IndexError):
        return None, None


def pid_alive(pid, proc_start):
    """True if pid is running *and* is the process the registry file describes
    (procStart is /proc starttime, so a recycled pid does not count; a zombie
    has exited and does not count either)."""
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (PermissionError, ValueError, TypeError):
        pass
    state, started = proc_stat(pid)
    if state == "Z":
        return False
    return not (started is not None and proc_start is not None and str(started) != str(proc_start))


def live_sessions(stores):
    """{sessionId: [pid]} for sessions with a running process, over every
    account's sessions/ dir (shared by symlink, so usually one directory)."""
    dirs = {realpath(os.path.join(p, "sessions")) for _, p in stores}
    dirs.add(realpath(os.path.join(shared_dir(), "sessions")))
    live = {}
    for d in sorted(dirs):
        for path in glob.glob(os.path.join(d, "*.json")):
            info = read_json(path) or {}
            sid, pid = info.get("sessionId"), info.get("pid")
            if sid and pid and pid_alive(pid, info.get("procStart")):
                live.setdefault(sid, []).append(pid)
    return live


# --------------------------------------------------------------------------- #
# who is running where
# --------------------------------------------------------------------------- #
# Busy = working, waiting = blocked on you.  An idle worker uses nothing, so it
# is not "running" for the purpose of keeping accounts apart.
ACTIVE = ("busy", "waiting")


def proc_ppid(pid):
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as fh:
            return int(fh.read().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def ancestor_pids(pid=None):
    """This process and everything above it: never something to stop."""
    seen, pid = set(), pid or os.getpid()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        pid = proc_ppid(pid)
    return seen


def account_of_pid(pid, store_map, default):
    """The account a running claude belongs to, from the environment the wrapper
    gave it: CLAUDE_CONFIG_DIR names its store, none at all means the default
    (native) account.  None when it cannot be told (not ours, or an unknown dir)."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as fh:
            env = dict(kv.split(b"=", 1) for kv in fh.read().split(b"\0") if b"=" in kv)
    except OSError:
        return None
    cfg = env.get(b"CLAUDE_CONFIG_DIR")
    if not cfg:
        return default
    return store_map.get(realpath(cfg.decode(errors="replace")))


def running_sessions(stores):
    """Live claude sessions and the account each runs as (pool spares excluded)."""
    store_map = {realpath(p): a for a, p in stores}
    default = registry.native_holder(registry.load(), "claude")
    dirs = {realpath(os.path.join(p, "sessions")) for _, p in stores}
    dirs.add(realpath(os.path.join(shared_dir(), "sessions")))
    out = []
    for d in sorted(dirs):
        for path in sorted(glob.glob(os.path.join(d, "*.json"))):
            info = read_json(path) or {}
            pid = info.get("pid")
            if not pid or info.get("spare") or not pid_alive(pid, info.get("procStart")):
                continue
            acct = account_of_pid(pid, store_map, default)
            if acct:
                out.append({"account": acct, "pid": pid, "kind": info.get("kind") or "?",
                            "status": info.get("status") or "-", "name": info.get("name") or "",
                            "jobId": info.get("jobId") or "", "sessionId": info.get("sessionId") or "",
                            "procStart": info.get("procStart")})
    return out


def session_table(rows, numbered=False):
    out = [(["#"] if numbered else []) + ["ACCOUNT", "KIND", "STATUS", "NAME", "PID", "JOB"]]
    for n, row in enumerate(rows, 1):
        out.append((["%d" % n] if numbered else []) +
                   [row["account"], row["kind"], row["status"], clip(row["name"] or row["jobId"], 40),
                    str(row["pid"]), row["jobId"] or "-"])
    return out


# A background shell a job started (a dev server, a watcher...) lives in a session
# of its own with parent 1, so it is not under the job's process tree and stopping
# the job does not necessarily end it.  The job's own record (`fan` in state.json)
# names such shells; /proc tells whether one is still there.
MIN_LABEL = 8  # shorter commands would match unrelated processes


def proc_cmdlines():
    """pid -> command line, for every process we may read (zombies have none)."""
    out = {}
    for d in glob.glob("/proc/[0-9]*"):
        try:
            with open(d + "/cmdline", "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if raw:
            out[int(d.rsplit("/", 1)[1])] = raw.replace(b"\0", b" ").decode("utf-8", "replace")
    return out


def background_shells(rows, stores):
    """Running shells that the background jobs in `rows` started:
    [{account, job, label, pids}].  Only what the job's record lists *and* a live
    process matches, so a stale record does not raise a false alarm."""
    store = dict(stores)
    skip = ancestor_pids() | {r["pid"] for r in rows}
    procs, found = None, []
    for r in rows:
        if r["kind"] != "bg" or not r["jobId"] or r["account"] not in store:
            continue
        state = read_json(os.path.join(store[r["account"]], "jobs", r["jobId"], "state.json")) or {}
        for task in state.get("fan") or []:
            label = str(task.get("label") or "").strip()
            if task.get("kind") != "shell" or len(label) < MIN_LABEL:
                continue
            procs = proc_cmdlines() if procs is None else procs
            pids = sorted(p for p, cmd in procs.items() if label in cmd and p not in skip)
            if pids:
                found.append({"account": r["account"], "job": r["name"] or r["jobId"],
                              "label": label, "pids": pids})
    return found


def shells_still_running(found):
    """The entries of `found` that still have a live process (gives them 2s to wind down)."""
    def survivors():
        procs = proc_cmdlines()
        return [dict(f, pids=[p for p in f["pids"] if f["label"] in procs.get(p, "")]) for f in found]
    wait_until(lambda: not any(f["pids"] for f in survivors()), 2)
    return [f for f in survivors() if f["pids"]]


def shell_lines(found):
    return [f"     {f['account']} / {clip(f['job'], 30)}: {clip(f['label'], 90)}  "
            f"(pid {', '.join(str(p) for p in f['pids'])})" for f in found]


def kill_hint(found):
    """A command that ends these shells.  Their own process group when the first
    process leads one (its children, which the command line does not name, go too)."""
    targets = []
    for f in found:
        root = min(f["pids"])
        try:
            lead = os.getpgid(root) == root
        except OSError:
            lead = False
        targets.append(f"-{root}" if lead else " ".join(str(p) for p in f["pids"]))
    return "kill -- " + " ".join(targets)


# --------------------------------------------------------------------------- #
# talking to the real CLI through the wrapper
# --------------------------------------------------------------------------- #
def run_claude(claude, acct, args, timeout=60, capture=True, cwd=None):
    # AGENT_ACCT_NO_ROUTE / _ALLOW_MIXED: we already picked the account and know
    # what is running elsewhere; never re-route and never ask again.
    env = dict(os.environ, AGENT_ACCT_NO_ROUTE="1", AGENT_ACCT_ALLOW_MIXED="1")
    return subprocess.run([claude, "-u", acct] + args, env=env, cwd=cwd,
                          stdin=subprocess.DEVNULL if capture else None,
                          capture_output=capture, text=True, timeout=timeout)


def fetch_rows(stores, claude, include_all, only_acct=None):
    """Merged `claude agents --json` rows, tagged with their account."""
    rows = []
    for acct, _ in stores:
        if only_acct and acct != only_acct:
            continue
        args = ["agents", "--json"] + (["--all"] if include_all else [])
        try:
            res = run_claude(claude, acct, args, timeout=45)
        except (subprocess.TimeoutExpired, OSError) as exc:
            warn(f"{acct}: 목록을 가져오지 못했습니다 ({exc})")
            continue
        try:
            data = json.loads(res.stdout) if res.returncode == 0 else None
        except ValueError:
            data = None
        if not isinstance(data, list):
            warn(f"{acct}: 목록을 가져오지 못했습니다 (exit {res.returncode}) {res.stderr.strip()[:160]}")
            continue
        rows += [dict(x, account=acct) for x in data if isinstance(x, dict)]

    # Interactive sessions live in the shared sessions/ dir, so every account
    # reports them.  Collapse those; only background jobs belong to one account.
    merged, seen = [], {}
    for row in rows:
        if row.get("kind") == "background":
            merged.append(row)
            continue
        key = (row.get("kind"), row.get("sessionId") or row.get("pid"))
        if key in seen:
            seen[key]["account"] = "*"
        else:
            seen[key] = row
            merged.append(row)
    merged.sort(key=lambda r: -(r.get("startedAt") or 0))

    # A conversation continued under another account under the same session id
    # shows up once per account.  sessions/ is shared, so the live process (and
    # hence STATUS) is reported on both rows; say so instead of leaving it a puzzle.
    by_session = {}
    for row in merged:
        if row.get("kind") == "background" and row.get("sessionId"):
            by_session.setdefault(row["sessionId"], set()).add(row["account"])
    for row in merged:
        others = sorted(by_session.get(row.get("sessionId"), set()) - {row["account"]})
        if others:
            row["sharedWith"] = others
    return merged


def table_rows(rows, numbered=False):
    """Header + one line per job; a NOTE column appears only when some session
    exists under more than one account."""
    note = any(r.get("sharedWith") for r in rows)
    out = [(["#"] if numbered else []) + ["ACCOUNT", "ID", "STATE", "STATUS", "NAME", "CWD"] + (["NOTE"] if note else [])]
    for n, row in enumerate(rows, 1):
        out.append((([str(n)] if numbered else []) +
                    [row.get("account", ""), row.get("id") or (row.get("sessionId") or "")[:8],
                     row.get("state") or "-", row.get("status") or "-",
                     clip(row.get("name") or "", 40), tilde(row.get("cwd"))] +
                    ([("같은 세션: " + ",".join(row["sharedWith"])) if row.get("sharedWith") else ""] if note else [])))
    return out


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_route(a):
    """exit 0 + "<account>\\t<job id>" when <ref> is not in --current but is in
    exactly one other account; 1 when there is nothing to route; 4 when ambiguous."""
    _, ids = best_matches(store_jobs(a.current), a.ref)
    if ids:
        return 1  # the requested account has it: never second-guess that
    here = realpath(a.current)
    found = find_all(a.ref, [(n, p) for n, p in account_stores() if realpath(p) != here])
    if not found:
        return 1
    if len(found) == 1:
        print(f"{found[0][1]}\t{found[0][2]}")
        return 0
    for _, acct, jid, path in found:
        print(f"  {acct}\t{jid}\t{store_jobs(path)[jid]['name']}", file=sys.stderr)
    return 4


def cmd_agents(a):
    rows = fetch_rows(account_stores(), a.claude, a.all, a.account and resolve_account(a.account))
    if a.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    elif rows:
        render_table(table_rows(rows))
    else:
        msg("표시할 에이전트가 없습니다." + ("" if a.all else " (끝난 잡까지 보려면 --all)"))
    return 0


def resolve_account(name):
    acct = registry.resolve(registry.load(), name)
    if acct is None:
        die(f"알 수 없는 계정: {name}")
    return acct


def carried_flags(store, jobid):
    """(flags to pass on, flags left behind) from the job's recorded respawnFlags."""
    flags = (read_json(os.path.join(store, "jobs", jobid, "state.json")) or {}).get("respawnFlags") or []
    keep, drop, i = [], [], 0
    while i < len(flags):
        name, eq, _ = flags[i].partition("=")
        if name in CARRY_FLAGS and (eq or i + 1 < len(flags)):
            keep += [flags[i]] if eq else flags[i:i + 2]
            i += 1 if eq else 2
        else:
            if flags[i].startswith("-"):
                drop.append(flags[i])
            i += 1
    return keep, drop


def pick_job(stores, claude):
    rows = [r for r in fetch_rows(stores, claude, True) if r.get("kind") == "background"]
    if not rows:
        die("넘길 수 있는 백그라운드 잡이 없습니다.")
    render_table(table_rows(rows, numbered=True))
    choice = ask("넘길 잡 번호 (q=취소): ")
    if not choice.isdigit() or not 1 <= int(choice) <= len(rows):
        die("취소했습니다." if choice.lower() in ("q", "") else f"잘못된 번호: {choice}")
    return rows[int(choice) - 1]


def cmd_handoff(a, extra):
    stores = account_stores()
    by_acct = dict(stores)
    can_ask = interactive()

    # 1. which job -------------------------------------------------------------
    if a.ref:
        found = find_all(a.ref, stores, a.source and resolve_account(a.source))
        if not found:
            die(f"'{a.ref}' 와(과) 일치하는 잡이 없습니다. 'agent-acct agents --all' 로 확인하세요.")
        if len(found) > 1:
            for _, acct, jid, path in found:
                print(f"  {acct}\t{jid}\t{store_jobs(path)[jid]['name']}", file=sys.stderr)
            die(f"'{a.ref}' 가 여러 잡과 일치합니다. --from <계정> 으로 계정을 지정하거나 id 를 더 길게 쓰세요.")
        _, owner, jobid, _ = found[0]
        row = next((r for r in fetch_rows([(owner, by_acct[owner])], a.claude, True) if r.get("id") == jobid), None)
        if row is None:
            die(f"{owner} 의 'claude agents' 목록에서 {jobid} 를 찾지 못했습니다.")
    else:
        if not can_ask:
            die("대화형 터미널이 아닙니다. 잡을 지정하세요: agent-acct handoff <id|이름> --to <계정>")
        row = pick_job(stores, a.claude)
        owner, jobid = row["account"], row["id"]
    sid, cwd = row.get("sessionId"), row.get("cwd")
    if not sid:
        die(f"{jobid}: 세션 ID 를 알 수 없어 넘길 수 없습니다.")
    if not cwd or not os.path.isdir(cwd):
        die(f"{jobid}: 작업 디렉터리({cwd})가 없습니다. 대화는 디렉터리 기준으로 찾으므로 이어받을 수 없습니다.")

    # 2. who takes it ----------------------------------------------------------
    if a.to:
        target = resolve_account(a.to)
        if target == owner:
            die(f"원본과 같은 계정입니다 ({owner}). 다른 계정을 --to 로 지정하세요.")
    else:
        options = [n for n, p in stores if n != owner and has_creds(p)]
        if not options:
            die("넘겨받을 수 있는 로그인된 다른 claude 계정이 없습니다.")
        if len(options) == 1:
            target = options[0]
        elif can_ask:
            for n, name in enumerate(options, 1):
                print(f"  {n}  {name}")
            pick = ask("넘겨받을 계정 번호: ")
            if not pick.isdigit() or not 1 <= int(pick) <= len(options):
                die("취소했습니다.")
            target = options[int(pick) - 1]
        else:
            die("넘겨받을 계정이 여러 개입니다. --to <계정> 으로 지정하세요: " + ", ".join(options))
    if target not in by_acct or not has_creds(by_acct[target]):
        die(f"'{target}' 에는 claude 로그인 정보가 없습니다. 먼저 'claude -u {target}' 로 로그인하세요.")

    # 3. same transcript twice? ------------------------------------------------
    is_live = sid in live_sessions(stores)
    mode = "fork" if a.fork else "same"
    if is_live and not (a.stop or a.fork):
        if not can_ask:
            die(f"{jobid} 는 지금 실행 중입니다. 같은 대화에 두 프로세스가 쓰지 않도록 --stop 또는 --fork 를 지정하세요.")
        print(f"{jobid} 는 지금 실행 중입니다.\n"
              f"  [1] {owner} 에서 멈춘 뒤 이어받기   (대화 유지, 원본 중지)\n"
              f"  [2] 복사본(fork)으로 이어받기        (원본은 계속 실행)\n  [3] 취소")
        choice = ask("선택: ")
        if choice == "1":
            a.stop = True
        elif choice == "2":
            mode = "fork"
        else:
            die("취소했습니다.")
    if a.stop and not is_live:
        msg(f"{jobid} 는 이미 실행 중이 아니라 멈추기는 건너뜁니다.")
        a.stop = False

    # 4. plan ------------------------------------------------------------------
    keep, drop = carried_flags(by_acct[owner], jobid)
    # the name is passed on explicitly below, so it is not "left behind"
    drop = [d for d in drop if d not in ("--name", "-n") and not d.startswith("--name=")]
    # The new job is a new record: without --name it starts nameless, and the name
    # the original had stays behind with it.  A copy gets a suffix to tell them apart.
    name = (row.get("name") or "").strip()
    name_given = any(x in ("-n", "--name") or x.startswith("--name=") for x in extra)
    new_name = "" if not name or name_given else name + (" (fork)" if mode == "fork" else "")
    # A background job is by default made to edit in a worktree of its own.  One that
    # was set up to work in place (bgIsolation "none", recorded in its state) would be
    # refused every write by its successor, so the setting goes along, as a launch-time
    # --settings.  Only "none" is carried: it is the one value checked to work this way.
    original = read_json(os.path.join(by_acct[owner], "jobs", jobid, "state.json")) or {}
    settings_given = any(x == "--settings" or x.startswith("--settings=") for x in extra)
    in_place = original.get("bgIsolation") == "none"
    iso_flags = (["--settings", json.dumps({"worktree": {"bgIsolation": "none"}}, separators=(",", ":"))]
                 if in_place and not settings_given else [])
    cmd = (["--bg", "--resume", sid] + (["--fork-session"] if mode == "fork" else []) + keep
           + (["--name", new_name] if new_name else []) + iso_flags + extra)
    stop_cmd = ["stop", jobid]
    print(f"원본      : {owner} / {jobid}  {row.get('name') or ''}")
    print(f"대상      : {target}")
    print(f"세션      : {sid}  ({'복사본(fork)으로' if mode == 'fork' else '같은 ID 로'} 이어받기)")
    print(f"디렉터리  : {tilde(cwd)}")
    print(f"이름      : {new_name or ('(직접 지정: -- 뒤의 --name)' if name_given else '(원본에 이름 없음)')}")
    if in_place:
        print("격리      : " + ("제자리 편집 (직접 지정한 --settings 를 따름)" if settings_given
                               else "제자리 편집 허용 (원본의 bgIsolation=none 승계)"))
    print(f"승계 플래그: {' '.join(keep) or '(없음)'}")
    if drop:
        print(f"승계 안 함: {' '.join(drop)}  (필요하면 -- 뒤에 직접 지정)")
    if a.stop:
        print(f"실행      : claude -u {owner} {' '.join(stop_cmd)}")
    print(f"실행      : (cd {tilde(cwd)} && claude -u {target} {' '.join(shlex.quote(x) for x in cmd)})")
    if mode == "same" and jobid in store_jobs(by_acct[target]):
        warn(f"{target} 에 같은 ID({jobid})의 잡이 이미 있습니다. 그 잡이 이어서 실행될 수 있습니다.")
    if a.dry_run:
        return 0
    if not a.yes:
        if not can_ask:
            die("비대화형이라 확인할 수 없습니다. 진행하려면 --yes 를 추가하세요.")
        if ask("진행할까요? [Y/n] ").lower().startswith("n"):
            die("취소했습니다.")

    # 5. go --------------------------------------------------------------------
    if a.stop:
        if run_claude(a.claude, owner, stop_cmd, capture=False).returncode != 0:
            die(f"{owner} 에서 {jobid} 를 멈추지 못했습니다.")
        deadline = time.time() + 15
        while sid in live_sessions(stores):
            if time.time() > deadline:
                die(f"{jobid} 를 멈췄지만 같은 세션의 프로세스가 아직 살아 있어 이어받지 않습니다. "
                    "다른 계정에서 이미 이어받은 세션일 수 있습니다 (agent-acct agents --all 로 확인).")
            time.sleep(0.5)
    res = run_claude(a.claude, target, cmd, timeout=120, capture=False, cwd=cwd)
    if res.returncode != 0:
        die(f"{target} 에서 이어받기에 실패했습니다 (exit {res.returncode}).")
    msg(f"{target} 에서 이어받았습니다. 확인: agent-acct agents --all")
    if mode == "same":
        warn(f"같은 세션이 {owner} 에도 항목({jobid})으로 남아 있습니다. 그쪽에서 attach/resume 하면 같은 대화에 "
             f"두 프로세스가 쓰게 되니, 이어서 쓸 때는 {target} 쪽만 사용하세요. 둘 다 쓰려면 --fork 로 넘기세요.")
    return 0


def wait_until(cond, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if cond():
            return True
        time.sleep(0.2)
    return cond()


def terminate(session, claude, wait, can_ask):
    """Stop one session; True once its process is gone.

    A background job goes through `claude stop` (clean, keeps the conversation);
    anything else gets SIGTERM.  If it is still there after `wait` seconds,
    SIGKILL is only sent when the user says so (same policy as codex-unlock)."""
    pid, started = session["pid"], session["procStart"]

    def gone():
        return not pid_alive(pid, started)

    if gone():
        return True
    if session["kind"] == "bg" and session["jobId"]:
        res = run_claude(claude, session["account"], ["stop", session["jobId"]], capture=False)
        if res.returncode != 0:
            warn(f"{session['account']} 에서 {session['jobId']} 를 멈추지 못했습니다.")
            return False
        wait = max(wait, 15)
    else:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return True
        except PermissionError:
            warn(f"pid {pid}: 종료 권한이 없습니다.")
            return False
    if wait_until(gone, wait):
        return True
    label = session["name"] or session["jobId"] or session["kind"]
    if can_ask and ask(f"{session['account']} / {label} (pid {pid}) 가 {wait:g}초 뒤에도 남아 있습니다. "
                       "강제 종료(SIGKILL)할까요? [y/N] ").lower().startswith("y"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return True
        return wait_until(gone, 5)
    return False


def cmd_takeover(a):
    """Called by the wrapper before an interactive `claude` starts as the account
    that owns --store.  If other accounts have sessions that are working or waiting
    on you, say so and offer to stop them.  Exit 0 = go ahead, 1 = do not start."""
    stores = account_stores()
    here = realpath(a.store)
    target = next((n for n, p in stores if realpath(p) == here), None)
    if target is None:
        return 0  # not an account store we manage: nothing to compare against
    skip, own_session = ancestor_pids(), os.environ.get("CLAUDE_CODE_SESSION_ID")
    others = [r for r in running_sessions(stores)
              if r["account"] != target and r["status"] in ACTIVE and r["pid"] not in skip
              and not (own_session and r["sessionId"] == own_session)]
    auto = os.environ.get("AGENT_ACCT_TAKEOVER") == "stop"
    can_ask = interactive()
    if not others or not (auto or can_ask):
        return 0  # nothing to flag, or nobody to ask: leave things as they were
    others.sort(key=lambda r: (r["account"], r["kind"], r["pid"]))

    names = ", ".join(sorted({r["account"] for r in others}))
    warn(f"{names} 에서 작업 중인 세션이 {len(others)}개 있습니다 (지금 들어가려는 계정: {target}):")
    render_table(session_table(others))
    shells = background_shells(others, stores)
    if shells:
        print("  ※ 이 잡들이 띄운 백그라운드 셸이 실행 중입니다. 잡을 멈춰도 꺼지지 않을 수 있습니다:")
        print("\n".join(shell_lines(shells)))
    if not auto:
        print("  [1] 그대로 들어가기   [2] 위 세션을 끊고 들어가기   [3] 취소")
        choice = ask("선택 [3]: ")
        if choice == "1":
            return 0
        if choice != "2":
            die("취소했습니다.")

    wait = float(os.environ.get("AGENT_ACCT_TERM_WAIT") or 8)
    stuck = [r for r in others if not terminate(r, a.claude, wait, can_ask)]
    left = shells_still_running(shells) if shells else []
    if left:
        warn("백그라운드 셸이 남아 있습니다 (자동으로 끄지 않습니다):")
        print("\n".join(shell_lines(left)))
        print("  끄려면: " + kill_hint(left))
    if not stuck:
        msg(f"{len(others)}개를 끊었습니다. {target} 로 들어갑니다.")
        return 0
    warn(f"끊지 못한 세션이 {len(stuck)}개 남았습니다.")
    if not can_ask or not ask("그래도 들어갈까요? [y/N] ").lower().startswith("y"):
        die("취소했습니다.")
    return 0


def cmd_running(a):
    rows = running_sessions(account_stores())
    if a.account:
        rows = [r for r in rows if r["account"] == resolve_account(a.account)]
    rows.sort(key=lambda r: (r["account"], r["kind"], r["pid"]))
    if a.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    elif rows:
        render_table(session_table(rows))
    else:
        msg("실행 중인 세션이 없습니다.")
    return 0


def cmd_live(a):
    pids = live_sessions(account_stores()).get(a.session_id)
    if pids:
        print(" ".join(str(p) for p in pids))
    return 0 if pids else 1


def cmd_summary(a):
    """One line per account + isolation checks; exit 1 if anything looks wrong."""
    problems = 0
    for acct, path in account_stores():
        n = len(store_jobs(path))
        login = has_creds(path)
        print(f"  {acct:<14} jobs={n:<3} login={'yes' if login else 'no':<3} {path}")
        for name in ISOLATED:
            if os.path.islink(os.path.join(path, name)):
                problems += 1
                print(f"    \033[31m! {name} 가 심볼릭 링크입니다 — 계정 간 데몬/잡이 섞입니다\033[0m")
        if n and not login:
            problems += 1
            print(f"    \033[33m! 로그인 정보가 없는데 잡 {n}개가 남아 있습니다 "
                  f"(agent-acct handoff 로 다른 계정에 넘길 수 있습니다)\033[0m")
    return 1 if problems else 0


# --------------------------------------------------------------------------- #
def build_parser():
    p = argparse.ArgumentParser(prog="jobs.py")
    default_claude = os.environ.get("AGENT_ACCT_WRAPPER") or os.path.join(HERE, "bin", "claude")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("route")
    r.add_argument("ref")
    r.add_argument("--current", required=True)

    g = sub.add_parser("agents")
    g.add_argument("--json", action="store_true")
    g.add_argument("--all", action="store_true")
    g.add_argument("--account")
    g.add_argument("--claude", default=default_claude)

    h = sub.add_parser("handoff")
    h.add_argument("ref", nargs="?")
    h.add_argument("--to")
    h.add_argument("--from", dest="source")
    mode = h.add_mutually_exclusive_group()
    mode.add_argument("--stop", action="store_true")
    mode.add_argument("--fork", action="store_true")
    h.add_argument("--yes", "-y", action="store_true")
    h.add_argument("--dry-run", action="store_true")
    h.add_argument("--claude", default=default_claude)

    lv = sub.add_parser("live")
    lv.add_argument("session_id")

    rn = sub.add_parser("running")
    rn.add_argument("--json", action="store_true")
    rn.add_argument("--account")

    tk = sub.add_parser("takeover")
    tk.add_argument("--store", required=True)
    tk.add_argument("--claude", default=default_claude)

    sub.add_parser("summary")
    return p


def main(argv):
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    a = build_parser().parse_args(argv)
    sys.stdout.reconfigure(line_buffering=True)  # keep our output ordered with the CLI's when piped
    try:
        if a.cmd == "route":
            return cmd_route(a)
        if a.cmd == "agents":
            return cmd_agents(a)
        if a.cmd == "handoff":
            return cmd_handoff(a, extra)
        if a.cmd == "live":
            return cmd_live(a)
        if a.cmd == "running":
            return cmd_running(a)
        if a.cmd == "takeover":
            return cmd_takeover(a)
        return cmd_summary(a)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # the wrapper must never break `claude` over a lookup
        if os.environ.get("AGENT_ACCT_DEBUG"):
            raise
        if a.cmd == "route":
            return 1
        if a.cmd == "takeover":
            warn(f"계정 간 실행 확인에 실패해 건너뜁니다 ({exc!r}). AGENT_ACCT_DEBUG=1 로 자세히 볼 수 있습니다.")
            return 0
        raise exc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
