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
# talking to the real CLI through the wrapper
# --------------------------------------------------------------------------- #
def run_claude(claude, acct, args, timeout=60, capture=True, cwd=None):
    # AGENT_ACCT_NO_ROUTE: we already picked the account, never re-route.
    env = dict(os.environ, AGENT_ACCT_NO_ROUTE="1")
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
    cmd = ["--bg", "--resume", sid] + (["--fork-session"] if mode == "fork" else []) + keep + extra
    stop_cmd = ["stop", jobid]
    print(f"원본      : {owner} / {jobid}  {row.get('name') or ''}")
    print(f"대상      : {target}")
    print(f"세션      : {sid}  ({'복사본(fork)으로' if mode == 'fork' else '같은 ID 로'} 이어받기)")
    print(f"디렉터리  : {tilde(cwd)}")
    print(f"승계 플래그: {' '.join(keep) or '(없음)'}")
    if drop:
        print(f"승계 안 함: {' '.join(drop)}  (필요하면 -- 뒤에 직접 지정)")
    if a.stop:
        print(f"실행      : claude -u {owner} {' '.join(stop_cmd)}")
    print(f"실행      : (cd {tilde(cwd)} && claude -u {target} {' '.join(cmd)})")
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
        return cmd_summary(a)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # the wrapper must never break `claude` over a lookup
        if a.cmd == "route" and not os.environ.get("AGENT_ACCT_DEBUG"):
            return 1
        raise exc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
