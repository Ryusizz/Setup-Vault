#!/usr/bin/env bash
# Apply personal Claude Code settings into the local ~/.claude/settings.json,
# idempotently. Run it on any machine where you use Claude Code.
#
# Default: disable the session-quality survey prompt (feedbackSurveyRate = 0).
# Add rows to SETTINGS to enforce more keys the same way — values are JSON
# literals, so numbers (0), booleans (true/false) and strings ("dark") all work.
#
# It only changes keys that are missing or set to a different value, preserves
# every other key, and writes a timestamped backup before any edit.
#
# Usage:
#   ./claude-code-settings.sh                 # apply to ~/.claude/settings.json
#   ./claude-code-settings.sh --check         # report only, change nothing
#   ./claude-code-settings.sh --path /x/settings.json
#
# Needs python3 (settings.json is strict JSON; python round-trips it safely).
set -euo pipefail

# key <TAB/space-free> | json-value
SETTINGS=(
  'feedbackSurveyRate|0'
  # examples you might add later:
  #   'feedbackDrafts|false'
  #   'theme|"dark"'
)

SETTINGS_PATH="${HOME}/.claude/settings.json"
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --path)  SETTINGS_PATH="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
info "settings file: $SETTINGS_PATH"

# Build a JSON object of the desired settings from the table.
desired="{"
first=1
for row in "${SETTINGS[@]}"; do
  key="${row%%|*}"; val="${row#*|}"
  [ "$first" = 1 ] || desired+=","
  desired+="$(printf '%s' "$key" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'):${val}"
  first=0
done
desired+="}"

CHECK_ONLY="$CHECK_ONLY" SETTINGS_PATH="$SETTINGS_PATH" DESIRED="$desired" python3 - <<'PY'
import json, os, shutil, sys, time

path = os.environ["SETTINGS_PATH"]
desired = json.loads(os.environ["DESIRED"])
check = os.environ["CHECK_ONLY"] == "1"

data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as e:
            print(f"  settings.json is not valid JSON ({e}); refusing to touch it.")
            sys.exit(1)

changes = {k: v for k, v in desired.items() if data.get(k) != v}
for k, v in desired.items():
    if k in changes:
        print(f"  will set  {k} = {json.dumps(v)}  (was {json.dumps(data.get(k)) if k in data else 'unset'})")
    else:
        print(f"  ok        {k} = {json.dumps(v)} (already)")

if not changes:
    print("  nothing to do — all settings already applied")
    sys.exit(0)
if check:
    print(f"  {len(changes)} change(s) pending (run without --check to apply)")
    sys.exit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    bak = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, bak)
    print(f"  backup: {bak}")
data.update(changes)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
print(f"  applied {len(changes)} change(s) to {path}")
PY

[ "$CHECK_ONLY" = 0 ] && ok "done" || true
