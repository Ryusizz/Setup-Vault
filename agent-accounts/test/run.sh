#!/usr/bin/env bash
# agent-accounts tests. A throwaway sandbox, a fake `claude`, no network and no
# touching of the real ~/.claude:
#
#   bash agent-accounts/test/run.sh
#
# Covers: owner routing in the wrapper, the merged `agent-acct agents` list,
# `agent-acct handoff` (incl. the double-writer guards) and `doctor`'s job check.
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
unset CLAUDE_CONFIG_DIR AGENT_ACCT_ACTIVE AGENT_ACCT_NO_ROUTE AGENT_ACCT_DEBUG AGENT_ACCT_FORCE_INTERACTIVE
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
  stop)   printf '%s\n' "$line"; [ -f "$FAKE_SLEEPER_PID" ] && kill "$(cat "$FAKE_SLEEPER_PID")" 2>/dev/null ;;
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

before="$(count_bg)"
out="$("$ACCT" handoff aaaa2222 --to beta --yes 2>&1)"; rc=$?
nonzero "running job without --stop/--fork is refused" "$rc"
has   "  ...naming the options" "$out" "--stop 또는 --fork"
eq    "  ...and nothing was launched" "$(count_bg)" "$before"

out="$("$ACCT" handoff aaaa2222 --to beta --yes --fork 2>&1)"; rc=$?
zero  "running job with --fork" "$rc"
has   "  ...starts a copy" "$(last_call)" "--fork-session"
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
