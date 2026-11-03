#!/usr/bin/env bash
# agent-accounts tests. A throwaway sandbox, a fake `claude`, no network and no
# touching of the real ~/.claude:
#
#   bash agent-accounts/test/run.sh
#
# Covers: owner routing in the wrapper, the merged `agent-acct agents` list,
# `agent-acct handoff` (incl. the double-writer guards), `doctor`'s job check and
# the entry guard (`claude -u X` while another account is busy).
set -uo pipefail

# The suite must behave the same whether or not it is started from a terminal.
# With a tty on stdin, `agent-acct handoff` rightly asks questions (e.g. "stop or
# fork?") and would sit waiting for an answer nobody can see. Tests that need
# input pipe it in explicitly.
exec </dev/null

AA="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
cleanup() {
  [ -f "$T/sleeper.pid" ] && kill "$(cat "$T/sleeper.pid")" 2>/dev/null
  [ -f "$T/zparent.pid" ] && kill "$(cat "$T/zparent.pid")" 2>/dev/null
  if [ -f "$T/spawned.pids" ]; then
    while read -r p; do kill -KILL "$p" 2>/dev/null; done < "$T/spawned.pids"
  fi
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAILN=0
t_ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
t_bad() { FAILN=$((FAILN + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2-}" ] && printf '        %s\n' "${2//$'\n'/$'\n        '}"; return 0; }
has()   { case "$2" in *"$3"*) t_ok "$1" ;; *) t_bad "$1" "expected to contain: $3"$'\n'"got: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) t_bad "$1" "must not contain: $3"$'\n'"got: $2" ;; *) t_ok "$1" ;; esac; }
eq()    { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected: $3"$'\n'"got: $2"; fi; }
nonzero() { if [ "$2" -ne 0 ]; then t_ok "$1"; else t_bad "$1" "expected a non-zero exit, got 0"; fi; }
zero()    { if [ "$2" -eq 0 ]; then t_ok "$1"; else t_bad "$1" "expected exit 0, got $2"; fi; }

# --------------------------------------------------------------------------- #
# sandbox: alpha (native), beta + gamma (overlays), all logged in
# --------------------------------------------------------------------------- #
export HOME="$T/home"; mkdir -p "$HOME"
export AGENT_ACCT_CLAUDE_HOME="$T/claude" AGENT_ACCT_CODEX_HOME="$T/codex"
export AGENT_ACCT_REGISTRY="$T/claude/.accounts/registry.json"
export AGENT_ACCT_REAL_CLAUDE="$T/fake/claude"
export FAKE_LOG="$T/fake.log" FAKE_FIXTURES="$T/fixtures" FAKE_SLEEPER_PID="$T/sleeper.pid"
unset CLAUDE_CONFIG_DIR AGENT_ACCT_ACTIVE AGENT_ACCT_NO_ROUTE AGENT_ACCT_DEBUG AGENT_ACCT_FORCE_INTERACTIVE \
      AGENT_ACCT_ALLOW_MIXED AGENT_ACCT_TAKEOVER AGENT_ACCT_TERM_WAIT CLAUDE_CODE_SESSION_ID
S="$T/claude"
mkdir -p "$S/sessions" "$S/.accounts/beta" "$S/.accounts/gamma" "$T/work/alpha" "$T/fake" "$T/fixtures"
: > "$FAKE_LOG"

python3 "$AA/registry.py" add alpha --mode claude=native >/dev/null
python3 "$AA/registry.py" add beta >/dev/null
python3 "$AA/registry.py" add gamma >/dev/null
printf '{"x":1}' > "$S/.credentials.json"
printf '{"x":1}' > "$S/.accounts/beta/.credentials.json"
printf '{"x":1}' > "$S/.accounts/gamma/.credentials.json"
"$AA/agent-acct" sync >/dev/null 2>&1

sid() { printf '%s-0000-4000-8000-000000000000' "$1"; }
mkjob() { # store id name state cwd [respawnFlags json]
  mkdir -p "$1/jobs/$2"
  printf '{"sessionId":"%s","name":"%s","state":"%s","cwd":"%s","respawnFlags":%s}\n' \
    "$(sid "$2")" "$3" "$4" "$5" "${6:-[]}" > "$1/jobs/$2/state.json"
}
W="$T/work/alpha"
mkjob "$S" aaaa1111 "alpha idle job" done "$W" \
  '["--reply-on-resume","--permission-mode","auto","--model","sonnet","--dangerously-skip-permissions"]'
mkjob "$S" aaaa2222 "alpha live job" working "$W"
mkjob "$S/.accounts/beta" bbbb3333 "beta shared-id job" done "$W"
mkjob "$S/.accounts/beta" bbbb7777 "beta only job" done "$W"
mkjob "$S/.accounts/beta" dddd1111 "beta d1" done "$W"
mkjob "$S/.accounts/beta" dddd2222 "beta d2" done "$W"
mkjob "$S/.accounts/gamma" bbbb3333 "gamma shared-id job" done "$W"   # same id as beta's

# aaaa2222 is "running": a real process, registered the way the CLI registers it
( sleep 600 </dev/null >/dev/null 2>&1 & echo $! > "$T/sleeper.pid" )
SL="$(cat "$T/sleeper.pid")"
stat="$(cat "/proc/$SL/stat")"; rest="${stat##*) }"; read -r -a fields <<< "$rest"; START="${fields[19]}"
printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"bg"}\n' "$SL" "$(sid aaaa2222)" "$START" > "$S/sessions/$SL.json"

row() { # id name state startedAt [extra json fields]
  printf '{"id":"%s","name":"%s","state":"%s","cwd":"%s","kind":"background","startedAt":%s,"sessionId":"%s"%s}' \
    "$1" "$2" "$3" "$W" "$4" "$(sid "$1")" "${5:-}"
}
printf '[%s,%s]\n' "$(row aaaa2222 'alpha live job' working 4000 ",\"pid\":$SL,\"status\":\"idle\"")" \
  "$(row aaaa1111 'alpha idle job' done 3000)" > "$T/fixtures/agents-alpha.json"
printf '[%s,%s,%s,%s]\n' "$(row bbbb3333 'beta shared-id job' done 2000)" "$(row bbbb7777 'beta only job' done 1000)" \
  "$(row dddd1111 'beta d1' done 900)" "$(row dddd2222 'beta d2' done 800)" > "$T/fixtures/agents-beta.json"
printf '[%s]\n' "$(row bbbb3333 'gamma shared-id job' done 1500)" > "$T/fixtures/agents-gamma.json"

cat > "$T/fake/claude" <<'EOF'
#!/usr/bin/env bash
# stands in for the real CLI: records how it was called, answers `agents --json`,
# and makes `stop` really end the "running" process.
line="$(printf 'CFG=%s ACTIVE=%s CWD=%s ARGS=%s' "${CLAUDE_CONFIG_DIR-}" "${AGENT_ACCT_ACTIVE-}" "$PWD" "$*")"
printf '%s\n' "$line" >> "$FAKE_LOG"
case "${1-}" in
  agents) cat "$FAKE_FIXTURES/agents-${AGENT_ACCT_ACTIVE:-alpha}.json" ;;
  stop)   printf '%s\n' "$line"
          if [ -f "$FAKE_FIXTURES/stop-${2-}.pid" ]; then kill -KILL $(cat "$FAKE_FIXTURES/stop-$2.pid") 2>/dev/null
          elif [ -f "$FAKE_SLEEPER_PID" ]; then kill "$(cat "$FAKE_SLEEPER_PID")" 2>/dev/null; fi ;;
  *)      printf '%s\n' "$line" ;;
esac
EOF
chmod +x "$T/fake/claude"

CLAUDE="$AA/bin/claude"; ACCT="$AA/agent-acct"
count_bg() { grep -c -e '--bg' "$FAKE_LOG" || true; }
last_call() { tail -n 1 "$FAKE_LOG"; }

# --------------------------------------------------------------------------- #
echo "routing: claude [-u X] <attach|logs|stop|rm|respawn> <id>"
out="$("$CLAUDE" -u beta logs aaaa1111 2>&1)"
has   "job owned by alpha, asked as beta -> runs as alpha" "$out" "CFG=$S ACTIVE=alpha"
has   "  ...and says so" "$out" "'alpha' 계정의 잡입니다"

out="$("$CLAUDE" -u alpha logs aaaa1111 2>&1)"
has   "job in the requested account is left alone" "$out" "CFG=$S ACTIVE=alpha"
hasnt "  ...silently" "$out" "계정의 잡입니다"

out="$("$CLAUDE" logs aaaa1111 2>&1)"
has   "no -u, job in the default store: environment untouched" "$out" "CFG= ACTIVE= "
hasnt "  ...silently" "$out" "계정의 잡입니다"

out="$("$CLAUDE" logs bbbb7777 2>&1)"
has   "no -u, job only in beta -> runs as beta" "$out" "CFG=$S/.accounts/beta ACTIVE=beta"

out="$("$CLAUDE" -u beta logs zzzzzzzz 2>&1)"
has   "unknown ref falls through to the real CLI as beta" "$out" "CFG=$S/.accounts/beta ACTIVE=beta"
hasnt "  ...without routing" "$out" "계정의 잡입니다"

out="$("$CLAUDE" logs dddd 2>&1)"
has   "ref matching two jobs in one other account is ambiguous" "$out" "자동으로 고르지 않습니다"
has   "  ...and runs unrouted" "$out" "CFG= ACTIVE= "

out="$("$CLAUDE" logs bbbb3333 2>&1)"
has   "same id in two other accounts is ambiguous" "$out" "자동으로 고르지 않습니다"
out="$("$CLAUDE" -u gamma logs bbbb3333 2>&1)"
has   "same id: the requested account wins" "$out" "ACTIVE=gamma"
hasnt "  ...without routing" "$out" "계정의 잡입니다"

out="$(AGENT_ACCT_NO_ROUTE=1 "$CLAUDE" -u beta logs aaaa1111 2>&1)"
has   "AGENT_ACCT_NO_ROUTE=1 disables routing" "$out" "CFG=$S/.accounts/beta ACTIVE=beta"

out="$("$CLAUDE" -u beta rm aaaa1111 --force-remove-worktree xyz 2>&1)"
has   "rm: the first non-option argument is the ref" "$out" "ACTIVE=alpha"
has   "  ...other arguments pass through" "$out" "ARGS=rm aaaa1111 --force-remove-worktree xyz"

out="$("$CLAUDE" -u beta attach "ALPHA idle" 2>&1)"
has   "attach by part of the name (case-insensitive)" "$out" "ACTIVE=alpha"

out="$("$CLAUDE" -u beta respawn --all 2>&1)"
has   "respawn --all has no ref: untouched" "$out" "CFG=$S/.accounts/beta ACTIVE=beta"
out="$("$CLAUDE" -u beta --version 2>&1)"
has   "non-job commands are untouched" "$out" "CFG=$S/.accounts/beta ACTIVE=beta"

# --------------------------------------------------------------------------- #
echo "agent-acct agents"
out="$("$ACCT" agents --all --json 2>/dev/null)"
eq    "--json merges every account" \
      "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), ",".join(sorted({r["account"] for r in d})))')" \
      "7 alpha,beta,gamma"
out="$("$ACCT" agents --all 2>/dev/null)"
has   "table has an ACCOUNT column" "$out" "ACCOUNT"
eq    "same job id under two accounts shows as two rows" "$(printf '%s\n' "$out" | grep -c bbbb3333)" "2"
has   "  ...and says it is the same session" "$out" "같은 세션: gamma"
eq    "a session in only one account has no NOTE" "$(printf '%s\n' "$out" | grep aaaa1111 | grep -c '같은 세션')" "0"
eq    "--json marks them with sharedWith" \
      "$("$ACCT" agents --all --json 2>/dev/null | python3 -c 'import json,sys; print(sorted(r["account"]+">"+",".join(r["sharedWith"]) for r in json.load(sys.stdin) if r.get("sharedWith")))')" \
      "['beta>gamma', 'gamma>beta']"
out="$("$ACCT" agents --all --account beta --json 2>/dev/null)"
eq    "--account narrows to one account" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" "4"

# --------------------------------------------------------------------------- #
echo "agent-acct handoff"
out="$("$ACCT" handoff aaaa1111 --to beta --yes 2>&1)"; rc=$?
zero  "finished job -> other account" "$rc"
call="$(last_call)"
has   "  ...resumes the same session in the background" "$call" "ARGS=--bg --resume $(sid aaaa1111) --permission-mode auto --model sonnet"
has   "  ...as the target account" "$call" "ACTIVE=beta"
has   "  ...from the job's directory" "$call" "CWD=$W"
hasnt "  ...as the same ID, not a fork" "$call" "--fork-session"
hasnt "  ...without internal --reply-on-resume" "$call" "--reply-on-resume"
hasnt "  ...without widening permissions" "$call" "--dangerously-skip-permissions"
has   "  ...and says what it left behind" "$out" "승계 안 함: --reply-on-resume --dangerously-skip-permissions"
has   "  ...warns that the original entry still exists" "$out" "같은 세션이 alpha 에도 항목(aaaa1111)으로 남아 있습니다"
has   "  ...keeps the job's name (a new job would start nameless)" "$call" "--name alpha idle job"
has   "  ...and shows it in the plan" "$out" "이름      : alpha idle job"
hasnt "  ...and by default adds no --settings (the job isolates itself as usual)" "$call" "--settings"
hasnt "  ...and says nothing about isolation" "$out" "격리"

out="$("$ACCT" handoff aaaa1111 --to beta --yes -- --name mine 2>&1)"; rc=$?
zero  "a --name given after -- is respected" "$rc"
call="$(last_call)"
has   "  ...as given" "$call" "--name mine"
hasnt "  ...not doubled by the original's name" "$call" "alpha idle job"

cp "$T/fixtures/agents-gamma.json" "$T/fixtures/agents-gamma.json.orig"
printf '[%s]\n' "$(row bbbb3333 '' done 1500)" > "$T/fixtures/agents-gamma.json"
out="$("$ACCT" handoff bbbb3333 --from gamma --to alpha --yes 2>&1)"; rc=$?
zero  "original without a name" "$rc"
hasnt "  ...gets no empty --name" "$(last_call)" "--name"
has   "  ...and the plan says why" "$out" "(원본에 이름 없음)"
mv "$T/fixtures/agents-gamma.json.orig" "$T/fixtures/agents-gamma.json"

# A job set up to edit in place (bgIsolation "none") would have every write refused
# in its successor, which isolates itself by default -- so the setting goes along.
sed -i 's/}$/,"bgIsolation":"none"}/' "$S/jobs/aaaa1111/state.json"
out="$("$ACCT" handoff aaaa1111 --to beta --yes 2>&1)"; rc=$?
zero  "original set up to work in place" "$rc"
call="$(last_call)"
has   "  ...the new job is allowed to edit in place too" "$call" '--settings {"worktree":{"bgIsolation":"none"}}'
has   "  ...and the plan says so" "$out" "제자리 편집 허용"
# a --name recorded in the original's flags is passed on explicitly, not "left behind"
sed -i 's/"--reply-on-resume",/"--reply-on-resume","--name","alpha idle job",/' "$S/jobs/aaaa1111/state.json"
out="$("$ACCT" handoff aaaa1111 --to beta --dry-run 2>&1)"
has   "  ...only flags that really stay behind are listed" "$out" "승계 안 함: --reply-on-resume --dangerously-skip-permissions"
sed -i 's/"--name","alpha idle job",//' "$S/jobs/aaaa1111/state.json"
out="$("$ACCT" handoff aaaa1111 --to beta --yes -- --settings /tmp/mine.json 2>&1)"; rc=$?
call="$(last_call)"
has   "  ...an explicit --settings is respected" "$call" "--settings /tmp/mine.json"
hasnt "  ...and not overridden" "$call" "bgIsolation"
sed -i 's/"bgIsolation":"none"/"bgIsolation":"worktree"/' "$S/jobs/aaaa1111/state.json"
out="$("$ACCT" handoff aaaa1111 --to beta --yes 2>&1)"; rc=$?
hasnt "  ...any other value is left to the default" "$(last_call)" "--settings"
sed -i 's/,"bgIsolation":"worktree"//' "$S/jobs/aaaa1111/state.json"

before="$(count_bg)"
out="$("$ACCT" handoff aaaa2222 --to beta --yes 2>&1)"; rc=$?
nonzero "running job without --stop/--fork is refused" "$rc"
has   "  ...naming the options" "$out" "--stop 또는 --fork"
eq    "  ...and nothing was launched" "$(count_bg)" "$before"

out="$("$ACCT" handoff aaaa2222 --to beta --yes --fork 2>&1)"; rc=$?
zero  "running job with --fork" "$rc"
has   "  ...starts a copy" "$(last_call)" "--fork-session"
has   "  ...named so it can be told from the original" "$(last_call)" "--name alpha live job (fork)"
hasnt "  ...no 'original entry' warning: a copy has its own session" "$out" "같은 세션이 alpha 에도"

out="$(printf '2\n' | AGENT_ACCT_FORCE_INTERACTIVE=1 "$ACCT" handoff aaaa2222 --to beta --yes 2>&1)"; rc=$?
zero  "running job, menu choice 2" "$rc"
has   "  ...starts a copy" "$(last_call)" "--fork-session"

# a recycled pid must not look like the running session
printf '{"pid":%s,"sessionId":"%s","procStart":"1"}\n' "$SL" "$(sid aaaa1111)" > "$S/sessions/9999.json"
out="$("$ACCT" handoff aaaa1111 --to beta --yes 2>&1)"; rc=$?
zero  "stale registry entry (pid reused) is not 'running'" "$rc"
rm -f "$S/sessions/9999.json"

before="$(count_bg)"
out="$("$ACCT" handoff aaaa1111 --to beta --dry-run 2>&1)"; rc=$?
zero  "--dry-run" "$rc"
has   "  ...prints the plan" "$out" "원본      : alpha / aaaa1111"
eq    "  ...and launches nothing" "$(count_bg)" "$before"

out="$(printf '2\n' | AGENT_ACCT_FORCE_INTERACTIVE=1 "$ACCT" handoff --to beta --dry-run 2>&1)"; rc=$?
zero  "no ref: pick from the list" "$rc"
has   "  ...list shows jobs of every account" "$out" "gamma"
has   "  ...#2 is the second row" "$out" "원본      : alpha / aaaa1111"

out="$("$ACCT" handoff --to beta </dev/null 2>&1)"; rc=$?
nonzero "no ref and no terminal is an error" "$rc"
has   "  ...explaining" "$out" "대화형 터미널이 아닙니다"

out="$("$ACCT" handoff aaaa1111 --to alpha --yes 2>&1)"; rc=$?
nonzero "handing a job to its own account is an error" "$rc"

out="$("$ACCT" handoff bbbb3333 --to alpha --dry-run 2>&1)"; rc=$?
nonzero "same id under two accounts needs --from" "$rc"
out="$("$ACCT" handoff bbbb3333 --from beta --to alpha --dry-run 2>&1)"; rc=$?
zero  "  ...--from disambiguates" "$rc"

out="$("$ACCT" handoff aaaa1111 --to beta 2>&1 </dev/null)"; rc=$?
nonzero "no terminal and no --yes is an error" "$rc"

out="$("$ACCT" handoff nosuchjob --to beta --yes 2>&1)"; rc=$?
nonzero "unknown job is an error" "$rc"

out="$("$ACCT" handoff aaaa2222 --to beta --stop --yes 2>&1)"; rc=$?
zero  "running job with --stop" "$rc"
has   "  ...stops it on its own account first" "$(grep -e 'ARGS=stop aaaa2222' "$FAKE_LOG")" "ACTIVE=alpha"
has   "  ...then resumes it as a same-ID continuation" "$(last_call)" "--bg --resume $(sid aaaa2222)"
hasnt "  ...not as a fork" "$(last_call)" "--fork-session"

# --------------------------------------------------------------------------- #
echo "entry guard: claude -u X while another account is busy"
# Real processes (sleep) that look like sessions of an account: the account is read
# from the process's CLAUDE_CONFIG_DIR, exactly as the guard does for the real CLI.
SPN=0
alive() { local st; st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; st="${st##*) }"; [ "${st:0:1}" != Z ]; }
gone_soon() { local i; for i in $(seq 1 60); do alive "$1" || return 0; sleep 0.1; done; return 1; }
spawn() { # <CLAUDE_CONFIG_DIR or ""> <kind> <status> <name> [jobId] [stubborn|spare|reused]
  local cfg="$1" kind="$2" status="$3" name="$4" jobid="${5-}" mode="${6-}" pf="$T/spawn.pid" body extra="" st rest f start i
  rm -f "$pf"
  if [ "$mode" = stubborn ]; then body='trap "" TERM; echo $$ > "$1"; while :; do sleep 1; done'
  else body='echo $$ > "$1"; exec sleep 600'; fi
  if [ -n "$cfg" ]; then ( export CLAUDE_CONFIG_DIR="$cfg"; bash -c "$body" _ "$pf" </dev/null >/dev/null 2>&1 & )
  else ( bash -c "$body" _ "$pf" </dev/null >/dev/null 2>&1 & ); fi
  for i in $(seq 1 60); do [ -s "$pf" ] && break; sleep 0.05; done
  SP_PID="$(cat "$pf")"; echo "$SP_PID" >> "$T/spawned.pids"
  st="$(cat "/proc/$SP_PID/stat")"; rest="${st##*) }"; read -r -a f <<< "$rest"; start="${f[19]}"
  [ "$mode" = spare ] && extra=',"spare":true'
  [ "$mode" = reused ] && start=1
  SPN=$((SPN + 1)); SP_SID="$(printf 'sp%06d-0000-4000-8000-000000000000' "$SPN")"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"%s","status":"%s","name":"%s","jobId":"%s"%s}\n' \
    "$SP_PID" "$SP_SID" "$start" "$kind" "$status" "$name" "$jobid" "$extra" > "$S/sessions/$SP_PID.json"
}
unspawn() { kill -KILL "$1" 2>/dev/null; rm -f "$S/sessions/$1.json"; }
launched() { case "$1" in *"CFG=$2 ACTIVE=$3 "*) return 0 ;; *) return 1 ;; esac; }
ENTER() { AGENT_ACCT_FORCE_INTERACTIVE=1 "$CLAUDE" "$@" 2>&1; }   # reads the menu answers from stdin
BETA="$S/.accounts/beta"

# -- what counts as "running elsewhere" -------------------------------------
spawn "$BETA" interactive busy "own account";                OWN=$SP_PID
spawn "" interactive idle "idle elsewhere";                  IDLE=$SP_PID
spawn "" interactive busy "spare" "" spare;                  SPARE=$SP_PID
spawn "" interactive busy "pid reused" "" reused;            REUSED=$SP_PID
spawn "$T/not-an-account" interactive busy "unmanaged dir";  OTHER=$SP_PID
out="$(printf '3\n' | ENTER -u beta)"; rc=$?
zero  "nothing busy elsewhere (own account, idle, spare, reused pid, unknown dir): no question" "$rc"
hasnt "  ...silently" "$out" "작업 중인 세션"
launched "$out" "$BETA" beta && t_ok "  ...and claude starts as beta" || t_bad "  ...and claude starts as beta" "$out"
for p in $OWN $IDLE $SPARE $REUSED $OTHER; do unspawn "$p"; done

# -- the menu -------------------------------------------------------------
spawn "" interactive busy "alpha busy chat";                 X=$SP_PID
out="$(printf '1\n' | ENTER -u beta)"; rc=$?
zero  "busy session in another account, answer 1 (enter anyway)" "$rc"
has   "  ...names the account being entered" "$out" "지금 들어가려는 계정: beta"
has   "  ...lists the session with its account" "$out" "alpha"
has   "  ...and its name" "$out" "alpha busy chat"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
alive "$X" && t_ok "  ...and the other session is left running" || t_bad "  ...and the other session is left running"

for answer in 3 ""; do
  out="$(printf '%s\n' "$answer" | ENTER -u beta)"; rc=$?
  nonzero "answer '${answer:-Enter}' cancels" "$rc"
  has   "  ...says so" "$out" "취소했습니다"
  launched "$out" "$BETA" beta && t_bad "  ...claude does not start" "$out" || t_ok "  ...claude does not start"
  alive "$X" && t_ok "  ...and the other session is left running" || t_bad "  ...and the other session is left running"
done
out="$(ENTER -u beta </dev/null)"; rc=$?
nonzero "end of input cancels" "$rc"
alive "$X" && t_ok "  ...and the other session is left running" || t_bad "  ...and the other session is left running"
out="$(printf 'x\n' | ENTER -u beta)"; rc=$?
nonzero "an unknown answer cancels" "$rc"

out="$(printf '2\n' | ENTER -u beta)"; rc=$?
zero  "answer 2 (stop them and enter)" "$rc"
has   "  ...reports it" "$out" "1개를 끊었습니다"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
gone_soon "$X" && t_ok "  ...the other session is gone" || t_bad "  ...the other session is gone"
unspawn "$X"

# -- background job: ended through `claude stop`, on its own account -----------
spawn "" bg busy "alpha bg job" bgjob9999 stubborn;          X=$SP_PID
printf '%s\n' "$X" > "$T/fixtures/stop-bgjob9999.pid"
out="$(printf '2\n' | ENTER -u beta)"; rc=$?
zero  "bg session (ignores SIGTERM) is stopped" "$rc"
has   "  ...with 'claude stop <job>' as its own account" "$out" "ACTIVE=alpha CWD="
has   "  ...naming the job" "$out" "ARGS=stop bgjob9999"
gone_soon "$X" && t_ok "  ...and it is gone" || t_bad "  ...and it is gone"
rm -f "$T/fixtures/stop-bgjob9999.pid"; unspawn "$X"

# -- background shells a job leaves behind: told about, never killed -------------
# A job's dev server runs in a session of its own with parent 1, so the process
# tree cannot find it; the job's record (`fan`) names it and /proc confirms it.
mkjobfan() { # <jobId> <fan json array>
  mkdir -p "$S/jobs/$1"
  printf '{"state":"working","name":"alpha dev job","sessionId":"%s","fan":%s}\n' "$(sid "$1")" "$2" > "$S/jobs/$1/state.json"
}
spawn_shell() { # a detached background shell: own session, parent 1
  rm -f "$T/sh.pid"
  ( bash -c 'echo $$ > "$1"; exec setsid sleep 7654.31' _ "$T/sh.pid" </dev/null >/dev/null 2>&1 & )
  local i; for i in $(seq 1 60); do [ -s "$T/sh.pid" ] && break; sleep 0.05; done
  SH="$(cat "$T/sh.pid")"; echo "$SH" >> "$T/spawned.pids"
}
FAN='[{"id":"s1","kind":"shell","label":"sleep 7654.31"},{"id":"a1","kind":"agent","label":"sleep 7654.31"},{"id":"s2","kind":"shell","label":"sleep 7"}]'

mkjobfan bgjob7777 "$FAN"
spawn "" bg busy "alpha dev job" bgjob7777 stubborn;         X=$SP_PID
spawn_shell
printf '%s\n' "$X" > "$T/fixtures/stop-bgjob7777.pid"
out="$(printf '1\n' | ENTER -u beta)"; rc=$?
zero  "job with a running background shell, answer 1" "$rc"
has   "  ...the menu warns before you choose" "$out" "백그라운드 셸이 실행 중입니다"
has   "  ...shows its command" "$out" "sleep 7654.31"
has   "  ...and its pid" "$out" "(pid $SH)"
eq    "  ...once (an 'agent' entry is not a shell)" "$(printf '%s\n' "$out" | grep -c 'sleep 7654.31')" "1"
hasnt "  ...a command too short to match safely is ignored" "$out" "sleep 7  (pid"
alive "$SH" && alive "$X" && t_ok "  ...nothing is stopped" || t_bad "  ...nothing is stopped"

out="$(printf '2\n' | ENTER -u beta)"; rc=$?
zero  "same job, answer 2 (the job stops, its shell does not)" "$rc"
gone_soon "$X" && t_ok "  ...the job is stopped" || t_bad "  ...the job is stopped"
has   "  ...says the shell is still there" "$out" "백그라운드 셸이 남아 있습니다"
has   "  ...with a command that ends it (its process group)" "$out" "끄려면: kill -- -$SH"
alive "$SH" && t_ok "  ...and the guard does not kill it" || t_bad "  ...and the guard does not kill it"
launched "$out" "$BETA" beta && t_ok "  ...claude still starts as beta" || t_bad "  ...claude still starts as beta" "$out"
kill -KILL "$SH" 2>/dev/null; unspawn "$X"; rm -f "$T/fixtures/stop-bgjob7777.pid"

spawn "" bg busy "alpha dev job" bgjob7777 stubborn;         X=$SP_PID
spawn_shell
printf '%s\n%s\n' "$X" "$SH" > "$T/fixtures/stop-bgjob7777.pid"   # this time the stop takes the shell along
out="$(printf '2\n' | ENTER -u beta)"; rc=$?
zero  "the shell ends together with the job" "$rc"
has   "  ...still announced up front" "$out" "백그라운드 셸이 실행 중입니다"
hasnt "  ...nothing left to report" "$out" "남아 있습니다"
kill -KILL "$SH" 2>/dev/null; unspawn "$X"; rm -f "$T/fixtures/stop-bgjob7777.pid"

mkjobfan bgjob7778 '[{"id":"s1","kind":"shell","label":"no-such-command-anywhere"}]'
spawn "" bg busy "alpha dev job 2" bgjob7778;                X=$SP_PID
out="$(printf '1\n' | ENTER -u beta)"; rc=$?
hasnt "a recorded shell that is not running raises no alarm" "$out" "백그라운드 셸"
unspawn "$X"
spawn "" interactive busy "alpha chat";                      X=$SP_PID
spawn_shell
out="$(printf '1\n' | ENTER -u beta)"; rc=$?
hasnt "an interactive session has no job record: no notice" "$out" "백그라운드 셸"
kill -KILL "$SH" 2>/dev/null; unspawn "$X"
rm -rf "$S/jobs/bgjob7777" "$S/jobs/bgjob7778"

# -- never touches itself ------------------------------------------------------
# The caller is a registered, busy session of another account (alpha) that runs the
# wrapper as its child -- what happens when a claude session's Bash tool runs
# `claude -u beta`. (A real parent: the test shell's own environ is not ours to rely on.)
rm -f "$T/go" "$T/anc.pid" "$T/anc.out" "$T/anc.out.rc"
( printf '3\n' | AGENT_ACCT_FORCE_INTERACTIVE=1 bash -c \
    'echo $$ > "$1"; while [ ! -f "$2" ]; do sleep 0.05; done; "$3" -u beta > "$4" 2>&1; echo $? > "$4.rc"' \
    _ "$T/anc.pid" "$T/go" "$CLAUDE" "$T/anc.out" >/dev/null 2>&1 & )
for i in $(seq 1 60); do [ -s "$T/anc.pid" ] && break; sleep 0.05; done
ANC="$(cat "$T/anc.pid")"; echo "$ANC" >> "$T/spawned.pids"
st="$(cat "/proc/$ANC/stat")"; rest="${st##*) }"; read -r -a f <<< "$rest"
printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"interactive","status":"busy","name":"the caller"}\n' \
  "$ANC" "selfsess-0000-4000-8000-000000000000" "${f[19]}" > "$S/sessions/$ANC.json"
: > "$T/go"
for i in $(seq 1 100); do [ -s "$T/anc.out.rc" ] && break; sleep 0.1; done
out="$(cat "$T/anc.out" 2>/dev/null)"; rc="$(cat "$T/anc.out.rc" 2>/dev/null)"
eq    "a busy session that is an ancestor of the wrapper is not offered" "$rc" "0"
hasnt "  ...no question" "$out" "작업 중인 세션"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
unspawn "$ANC"

spawn "" interactive busy "my own session";                  X=$SP_PID
out="$(printf '3\n' | CLAUDE_CODE_SESSION_ID="$SP_SID" ENTER -u beta)"; rc=$?
zero  "the session named by CLAUDE_CODE_SESSION_ID is not offered" "$rc"
hasnt "  ...no question" "$out" "작업 중인 세션"

# -- without a person to ask ---------------------------------------------------
out="$("$CLAUDE" -u beta 2>&1 </dev/null)"; rc=$?
zero  "no terminal: the guard stays out of the way" "$rc"
hasnt "  ...no question" "$out" "작업 중인 세션"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
alive "$X" && t_ok "  ...and nothing is stopped" || t_bad "  ...and nothing is stopped"

out="$(AGENT_ACCT_TAKEOVER=stop "$CLAUDE" -u beta 2>&1 </dev/null)"; rc=$?
zero  "AGENT_ACCT_TAKEOVER=stop works without a terminal" "$rc"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
gone_soon "$X" && t_ok "  ...and stops the other session" || t_bad "  ...and stops the other session"
unspawn "$X"

# -- a session that will not stop ----------------------------------------------
spawn "" interactive busy "stubborn chat" "" stubborn;       X=$SP_PID
export AGENT_ACCT_TERM_WAIT=1
out="$(printf '2\nn\nn\n' | ENTER -u beta)"; rc=$?
nonzero "won't stop; no SIGKILL, don't enter anyway -> cancel" "$rc"
has   "  ...offers SIGKILL" "$out" "강제 종료"
has   "  ...says how many are left" "$out" "끊지 못한 세션이 1개"
alive "$X" && t_ok "  ...and it is still running" || t_bad "  ...and it is still running"
launched "$out" "$BETA" beta && t_bad "  ...claude does not start" "$out" || t_ok "  ...claude does not start"

out="$(printf '2\nn\ny\n' | ENTER -u beta)"; rc=$?
zero  "won't stop; no SIGKILL, enter anyway" "$rc"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
alive "$X" && t_ok "  ...and it is still running" || t_bad "  ...and it is still running"

out="$(printf '2\ny\n' | ENTER -u beta)"; rc=$?
zero  "won't stop; SIGKILL" "$rc"
launched "$out" "$BETA" beta && t_ok "  ...claude starts as beta" || t_bad "  ...claude starts as beta" "$out"
gone_soon "$X" && t_ok "  ...and it is gone" || t_bad "  ...and it is gone"
unset AGENT_ACCT_TERM_WAIT
unspawn "$X"

# -- which starts are guarded --------------------------------------------------
spawn "" interactive busy "alpha busy chat";                 X=$SP_PID
for cmd in "-p hi" "--print hi" "--bg task" "--version" "--help" "logs zzzzzzzz" "agents" "mcp list" "doctor" "stop zzzzzzzz"; do
  out="$(printf '3\n' | ENTER -u beta $cmd)"; rc=$?
  hasnt "not an interactive start, no question: claude -u beta $cmd" "$out" "작업 중인 세션"
done
out="$(printf '3\n' | AGENT_ACCT_ALLOW_MIXED=1 ENTER -u beta)"; rc=$?
zero  "AGENT_ACCT_ALLOW_MIXED=1 skips the guard" "$rc"
hasnt "  ...no question" "$out" "작업 중인 세션"
for cmd in "fix the bug" "--resume abc" "--continue" "attach somejob"; do
  out="$(printf '3\n' | ENTER -u beta $cmd)"; rc=$?
  has   "interactive start asks: claude -u beta $cmd" "$out" "작업 중인 세션"
done
unspawn "$X"

# -- bare `claude` is an entry into the default account too ---------------------
spawn "$BETA" interactive busy "beta busy chat";             X=$SP_PID
out="$(printf '3\n' | ENTER)"; rc=$?
nonzero "bare claude: busy session in another account -> asks (cancel)" "$rc"
has   "  ...names the default account" "$out" "지금 들어가려는 계정: alpha"
has   "  ...and the busy one" "$out" "beta busy chat"
out="$(printf '1\n' | ENTER)"; rc=$?
zero  "bare claude, answer 1" "$rc"
has   "  ...runs the real CLI untouched" "$out" "CFG= ACTIVE= "
out="$(printf '3\n' | ENTER -p hi)"; rc=$?
hasnt "bare claude -p: no question" "$out" "작업 중인 세션"
out="$(printf '3\n' | ENTER -u alpha)"; rc=$?
has   "claude -u alpha (the default account, by name) asks as well" "$out" "지금 들어가려는 계정: alpha"
unspawn "$X"
spawn "" interactive busy "alpha busy chat";                 X=$SP_PID
out="$(printf '3\n' | ENTER)"; rc=$?
zero  "bare claude with only the default account busy: no question" "$rc"
unspawn "$X"

# -- a check that cannot run must not lock anyone out ------------------------------
printf '{broken' > "$T/bad-registry.json"
out="$(AGENT_ACCT_REGISTRY="$T/bad-registry.json" python3 "$AA/jobs.py" takeover --store "$S" 2>&1 </dev/null)"; rc=$?
zero  "the check itself failing: warn and let the start go ahead" "$rc"
has   "  ...says it was skipped" "$out" "건너뜁니다"
out="$(AGENT_ACCT_DEBUG=1 AGENT_ACCT_REGISTRY="$T/bad-registry.json" python3 "$AA/jobs.py" takeover --store "$S" 2>&1 </dev/null)"; rc=$?
nonzero "  ...with AGENT_ACCT_DEBUG=1 the error is shown instead" "$rc"
out="$(python3 "$AA/jobs.py" takeover --store "$T/not-an-account" 2>&1 </dev/null)"; rc=$?
zero  "a store that is not a managed account: nothing to compare, go ahead" "$rc"

# -- agent-acct running ----------------------------------------------------------
spawn "" interactive busy "alpha chat";                      A=$SP_PID
spawn "$BETA" bg waiting "beta bg" bgjob1234;                B=$SP_PID
out="$("$ACCT" running 2>&1)"; rc=$?
zero  "agent-acct running" "$rc"
has   "  ...lists the default account's session" "$out" "alpha"
has   "  ...and the other account's, with its job id" "$out" "bgjob1234"
eq    "  ...--json is one row per live session, with the account" \
      "$("$ACCT" running --json | python3 -c 'import json,sys; print(sorted((r["account"], r["pid"]) for r in json.load(sys.stdin) if r["pid"] in ('"$A,$B"')))')" \
      "[('alpha', $A), ('beta', $B)]"
out="$("$ACCT" running --account beta 2>&1)"
has   "  ...--account narrows" "$out" "beta bg"
hasnt "  ...(the other account is gone)" "$out" "alpha chat"
unspawn "$A"; unspawn "$B"

# --------------------------------------------------------------------------- #
echo "consistency with lib.sh"
for acct in alpha beta gamma; do
  eq "store path of $acct matches aa_store_dir" \
     "$(cd "$AA" && python3 -c "import jobs; print(dict(jobs.account_stores())['$acct'])")" \
     "$("$ACCT" path claude "$acct")"
done

echo "liveness: an exited-but-unreaped process is not 'running'"
# the parent never waits for its child, so the child stays a zombie
( bash -c 'sleep 0.05 & echo $! > "$1"; exec sleep 30' _ "$T/zombie.pid" </dev/null >/dev/null 2>&1 & echo $! > "$T/zparent.pid" )
sleep 0.5
ZP="$(cat "$T/zombie.pid")"
zstat="$(cat "/proc/$ZP/stat")"; zrest="${zstat##*) }"; read -r -a zf <<< "$zrest"
eq    "test setup: the process is a zombie" "${zf[0]}" "Z"
printf '{"pid":%s,"sessionId":"zzzz0000-0000-4000-8000-000000000000","procStart":"%s"}\n' "$ZP" "${zf[19]}" > "$S/sessions/$ZP.json"
python3 "$AA/jobs.py" live "zzzz0000-0000-4000-8000-000000000000" >/dev/null 2>&1; rc=$?
nonzero "zombie with a matching procStart does not count as live" "$rc"
# control: the zombie's parent is a live process, which must count
ZPAR="$(cat "$T/zparent.pid")"
pstat="$(cat "/proc/$ZPAR/stat")"; prest="${pstat##*) }"; read -r -a pf <<< "$prest"
printf '{"pid":%s,"sessionId":"zzzz1111-0000-4000-8000-000000000000","procStart":"%s"}\n' "$ZPAR" "${pf[19]}" > "$S/sessions/$ZPAR.json"
python3 "$AA/jobs.py" live "zzzz1111-0000-4000-8000-000000000000" >/dev/null 2>&1; rc=$?
zero  "a live process with a matching procStart does count" "$rc"
rm -f "$S/sessions/$ZP.json" "$S/sessions/$ZPAR.json"

echo "doctor: isolation check"
out="$(python3 "$AA/jobs.py" summary 2>&1)"; rc=$?
zero  "healthy layout" "$rc"
mv "$S/.accounts/gamma/jobs" "$S/.accounts/gamma/jobs.bak"; ln -s "$S/jobs" "$S/.accounts/gamma/jobs"
out="$(python3 "$AA/jobs.py" summary 2>&1)"; rc=$?
nonzero "jobs/ turned into a symlink is flagged" "$rc"
has   "  ...naming it" "$out" "jobs 가 심볼릭 링크입니다"
rm "$S/.accounts/gamma/jobs"; mv "$S/.accounts/gamma/jobs.bak" "$S/.accounts/gamma/jobs"
mv "$S/.accounts/gamma/.credentials.json" "$T/gamma.creds"
out="$(python3 "$AA/jobs.py" summary 2>&1)"; rc=$?
nonzero "jobs stranded in a logged-out account are flagged" "$rc"
has   "  ...pointing at handoff" "$out" "agent-acct handoff"
mv "$T/gamma.creds" "$S/.accounts/gamma/.credentials.json"

# --------------------------------------------------------------------------- #
echo
echo "passed: $PASS   failed: $FAILN"
[ "$FAILN" -eq 0 ]
