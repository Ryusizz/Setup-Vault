#!/usr/bin/env bash
# Stop VS Code from prepending a Python-env activation (e.g. `source activate` /
# `conda activate`) to every new integrated terminal, by writing the relevant
# keys into your LOCAL VS Code *User* settings.json.
#
# Why User settings and not the project: these keys apply to remote/devcontainer
# sessions too (they flow from your machine into the container), and living on
# your machine they survive any container rebuild. Run this ON THE PC where you
# actually run VS Code — for a container attached from Windows, that is the
# Windows side, so use vscode-disable-python-autoactivate.ps1 there instead.
#
# Idempotent: it looks for each key and only adds the ones that are missing,
# leaving the rest of the file (including comments) untouched. A timestamped
# backup is made before any edit.
#
# Usage:
#   ./vscode-disable-python-autoactivate.sh            # VS Code (stable)
#   ./vscode-disable-python-autoactivate.sh --insiders # VS Code - Insiders
#   ./vscode-disable-python-autoactivate.sh --path /custom/settings.json
#   ./vscode-disable-python-autoactivate.sh --check    # report only, no writes
set -euo pipefail

# key | json-value. Add a row to enforce another setting the same way.
# - python-envs.terminal.autoActivationType : current Python extension setting
# - python.terminal.activateEnvironment      : legacy key, still honoured
SETTINGS=(
  'python-envs.terminal.autoActivationType|"off"'
  'python.terminal.activateEnvironment|false'
)

FLAVOR="Code"      # "Code" = stable, "Code - Insiders" = insiders
SETTINGS_PATH=""
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --insiders)  FLAVOR="Code - Insiders"; shift ;;
    --path)      SETTINGS_PATH="$2"; shift 2 ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }

# --- locate the User settings.json -------------------------------------------
if [ -z "$SETTINGS_PATH" ]; then
  case "$(uname -s)" in
    Darwin) SETTINGS_PATH="$HOME/Library/Application Support/${FLAVOR}/User/settings.json" ;;
    *)      SETTINGS_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/${FLAVOR}/User/settings.json" ;;
  esac
fi
info "settings file: $SETTINGS_PATH"

# --- which keys are missing? -------------------------------------------------
present() { [ -f "$SETTINGS_PATH" ] && grep -qF "\"$1\"" "$SETTINGS_PATH"; }

MISSING=()
for row in "${SETTINGS[@]}"; do
  key="${row%%|*}"
  if present "$key"; then
    ok "already set: $key (left as-is)"
  else
    MISSING+=("$row")
    info "missing: $key"
  fi
done

if [ ${#MISSING[@]} -eq 0 ]; then
  ok "nothing to do — all keys already present"
  exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
  warn "${#MISSING[@]} key(s) missing (run without --check to add them)"
  exit 0
fi

# --- build the block to insert (trailing comma: settings.json is JSONC) ------
INS=""
for row in "${MISSING[@]}"; do
  key="${row%%|*}"; val="${row#*|}"
  INS+="    \"$key\": ${val},"$'\n'
done

mkdir -p "$(dirname "$SETTINGS_PATH")"

# Fresh file, or one that holds no object yet: just write a clean object.
if [ ! -f "$SETTINGS_PATH" ] || ! grep -q '{' "$SETTINGS_PATH"; then
  { printf '{\n'; printf '%s' "$INS"; printf '}\n'; } > "$SETTINGS_PATH"
  ok "created $SETTINGS_PATH with ${#MISSING[@]} key(s)"
else
  cp "$SETTINGS_PATH" "${SETTINGS_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
  # Insert the block right after the first '{'. Splitting at that brace keeps
  # everything else — comments, formatting — exactly as it was.
  tmp="$(mktemp)"
  INS="$INS" awk '
    done { print; next }
    {
      p = index($0, "{")
      if (p == 0) { print; next }
      print substr($0, 1, p)
      printf "%s", ENVIRON["INS"]
      rest = substr($0, p + 1)
      if (rest != "") print rest
      done = 1
    }
  ' "$SETTINGS_PATH" > "$tmp"
  mv "$tmp" "$SETTINGS_PATH"
  ok "added ${#MISSING[@]} key(s) (backup: ${SETTINGS_PATH}.bak-*)"
fi

# --- verify ------------------------------------------------------------------
fail=0
for row in "${SETTINGS[@]}"; do
  key="${row%%|*}"
  present "$key" || { warn "still missing after write: $key"; fail=1; }
done
[ "$fail" = 0 ] && ok "done — reopen a terminal in VS Code; no activation line should appear"
exit "$fail"
