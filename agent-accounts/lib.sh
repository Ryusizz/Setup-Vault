#!/usr/bin/env bash
# agent-accounts — shared helpers for the claude/codex account wrappers.
#
# Model: each CLI keeps ONE real "shared store" (~/.claude, ~/.codex) that holds
# everything that should be common across accounts — session transcripts,
# history, settings, skills, plugins. An extra account gets an *overlay*
# directory under <shared>/.accounts/<id>/ in which every entry is a symlink
# back into the shared store, except a short private list (auth tokens and the
# account-scoped config file). Pointing CLAUDE_CONFIG_DIR / CODEX_HOME at the
# overlay therefore swaps the login while keeping all work visible.

AA_ROOT="${AA_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
AA_REGISTRY_PY="$AA_ROOT/registry.py"

AA_CLAUDE_SHARED="${AGENT_ACCT_CLAUDE_HOME:-$HOME/.claude}"
AA_CODEX_SHARED="${AGENT_ACCT_CODEX_HOME:-$HOME/.codex}"

export AGENT_ACCT_REGISTRY="${AGENT_ACCT_REGISTRY:-$AA_CLAUDE_SHARED/.accounts/registry.json}"

# Entries that must NOT be shared between accounts.
#   claude: oauth tokens, the account-scoped config blob and its backups, and the
#           background-agent daemon (its lock/state assume one identity; sharing
#           it would run jobs under whichever account happened to start it).
#   codex:  oauth tokens and the per-tier model cache.
AA_PRIVATE_claude=(.credentials.json .claude.json .claude.json.backup backups
                   daemon daemon.lock daemon.log daemon.status.json
                   jobs statsig tmp .tmp)
AA_PRIVATE_codex=(auth.json models_cache.json tmp .tmp)

# Never symlinked (overlay parent / registry home).
AA_SKIP=(.accounts)

# Transient SQLite sidecars. Never linked: SQLite resolves the symlink of the
# main .sqlite file and writes -wal/-shm next to the REAL file, so linking them
# only produces dangling clutter. (Verified: a write through the symlink lands
# in the shared database.)
aa_is_transient() {
  case "$1" in
    *-wal|*-shm|*.sqlite-journal|*.lock|*.aa-bak) return 0 ;;
    *) return 1 ;;
  esac
}

aa_msg()  { printf '\033[36m[agent-acct]\033[0m %s\n' "$*" >&2; }
aa_warn() { printf '\033[33m[agent-acct]\033[0m %s\n' "$*" >&2; }
aa_err()  { printf '\033[31m[agent-acct]\033[0m %s\n' "$*" >&2; }
aa_die()  { aa_err "$*"; exit 1; }

aa_reg() { python3 "$AA_REGISTRY_PY" "$@"; }

aa_tools() { printf '%s\n' claude codex; }

aa_shared_dir() {
  case "$1" in
    claude) printf '%s\n' "$AA_CLAUDE_SHARED" ;;
    codex)  printf '%s\n' "$AA_CODEX_SHARED" ;;
    *) aa_die "unknown tool: $1" ;;
  esac
}

aa_env_var() {
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR\n' ;;
    codex)  printf 'CODEX_HOME\n' ;;
    *) aa_die "unknown tool: $1" ;;
  esac
}

aa_private_entries() {
  case "$1" in
    claude) printf '%s\n' "${AA_PRIVATE_claude[@]}" ;;
    codex)  printf '%s\n' "${AA_PRIVATE_codex[@]}" ;;
    *) aa_die "unknown tool: $1" ;;
  esac
}

# aa_store_dir <tool> <id> -> directory to use as the CLI home
aa_store_dir() {
  local tool="$1" id="$2" shared
  shared="$(aa_shared_dir "$tool")"
  if [ "$(aa_reg mode "$id" "$tool")" = native ]; then
    printf '%s\n' "$shared"
  else
    printf '%s\n' "$shared/.accounts/$id"
  fi
}

# Claude Code keeps its account-scoped config next to the config dir when
# CLAUDE_CONFIG_DIR is unset (~/.claude.json) but INSIDE it when the env var is
# set. aa_config_file resolves whichever applies to a given store.
# aa_config_file <tool> <dir>
aa_config_file() {
  case "$1" in
    claude)
      if [ "$2" = "$AA_CLAUDE_SHARED" ]; then
        printf '%s\n' "${AA_CLAUDE_SHARED}.json"
      else
        printf '%s\n' "$2/.claude.json"
      fi ;;
    codex) printf '%s\n' "$2/config.toml" ;;
  esac
}

# aa_creds_file <tool> <dir>
aa_creds_file() {
  case "$1" in
    claude) printf '%s\n' "$2/.credentials.json" ;;
    codex)  printf '%s\n' "$2/auth.json" ;;
  esac
}

# `codex login` deletes the existing auth.json the moment it starts, so an
# abandoned login — Ctrl-C, a dropped SSH session, a killed terminal — logs you
# out of an account that was working. (Verified: kill a login mid-flow and the
# file is gone.) aa_with_creds_guard stashes the credentials first and puts them
# back if the login produced nothing.
#
# A login killed outright (SIGKILL) cannot run the trap, so its stash is left
# behind; aa_recover_creds puts it back on the next run.
aa_recover_creds() {
  local tool="$1" store="$2" creds
  creds="$(aa_creds_file "$tool" "$store")"
  [ -s "$creds.aa-bak" ] || return 0
  if [ -s "$creds" ]; then
    rm -f "$creds.aa-bak"
  else
    cp -p "$creds.aa-bak" "$creds" && rm -f "$creds.aa-bak" \
      && aa_warn "중단된 로그인이 남긴 백업에서 $tool 로그인 정보를 복구했습니다."
  fi
}

# aa_with_creds_guard <tool> <store> <command...>
aa_with_creds_guard() {
  local tool="$1" store="$2"; shift 2
  aa_recover_creds "$tool" "$store"

  local creds backup=""
  creds="$(aa_creds_file "$tool" "$store")"
  if [ -s "$creds" ]; then
    backup="$creds.aa-bak"
    cp -p "$creds" "$backup" || backup=""
  fi
  if [ -n "$backup" ]; then
    # shellcheck disable=SC2064  # expand the paths now, not at trap time
    trap "[ -s '$creds' ] || cp -p '$backup' '$creds' 2>/dev/null; rm -f '$backup'" EXIT INT TERM
  fi

  "$@"
  local rc=$?

  if [ -n "$backup" ]; then
    trap - EXIT INT TERM
    if [ -s "$creds" ]; then
      rm -f "$backup"
    else
      cp -p "$backup" "$creds" && rm -f "$backup"
      aa_warn "로그인이 끝나지 않아 이전 $tool 로그인 정보를 되돌렸습니다."
    fi
  fi
  return $rc
}

aa_has_creds() {
  aa_recover_creds "$1" "$2"
  local f; f="$(aa_creds_file "$1" "$2")"
  [ -s "$f" ]
}

# --------------------------------------------------------------------------- #
# Overlay maintenance
# --------------------------------------------------------------------------- #

_aa_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# aa_sync_overlay <tool> <id> [--quiet]
#
# Idempotent. Called before every launch so that files the CLI invents later
# (a new sqlite version, a new cache dir) get folded into the shared store
# automatically instead of silently diverging per account.
aa_sync_overlay() {
  local tool="$1" id="$2" quiet="${3:-}"
  local shared overlay
  shared="$(aa_shared_dir "$tool")"
  overlay="$shared/.accounts/$id"

  local private=() ; mapfile -t private < <(aa_private_entries "$tool")

  mkdir -p "$overlay" || aa_die "cannot create overlay: $overlay"
  chmod 700 "$overlay"

  # 1. shared -> overlay: link anything shared that the overlay lacks.
  local path name
  while IFS= read -r path; do
    name="$(basename "$path")"
    _aa_in_list "$name" "${AA_SKIP[@]}" && continue
    _aa_in_list "$name" "${private[@]}" && continue
    aa_is_transient "$name" && continue
    if [ -e "$overlay/$name" ] || [ -L "$overlay/$name" ]; then continue; fi
    ln -s "$shared/$name" "$overlay/$name"
  done < <(find "$shared" -mindepth 1 -maxdepth 1 2>/dev/null)

  # 2. overlay -> shared: promote real entries the CLI created here, drop
  #    symlinks whose target disappeared.
  while IFS= read -r path; do
    name="$(basename "$path")"
    if [ -L "$path" ]; then
      # drop dangling links, and any link to a transient sqlite sidecar
      if [ ! -e "$path" ] || aa_is_transient "$name"; then rm -f "$path"; fi
      continue
    fi
    _aa_in_list "$name" "${AA_SKIP[@]}" && continue
    _aa_in_list "$name" "${private[@]}" && continue
    aa_is_transient "$name" && continue   # moved together with its .sqlite below
    if [ -e "$shared/$name" ]; then
      [ -n "$quiet" ] || aa_warn "'$name' exists in both $overlay and the shared store; leaving the account-local copy alone."
      continue
    fi
    mv "$path" "$shared/$name" || continue
    # carry a promoted database's sidecars with it, then link the main file
    case "$name" in
      *.sqlite|*.db)
        local side
        for side in "$overlay/$name"-wal "$overlay/$name"-shm "$overlay/$name"-journal; do
          [ -e "$side" ] && mv "$side" "$shared/$(basename "$side")"
        done ;;
    esac
    ln -s "$shared/$name" "$overlay/$name"
    [ -n "$quiet" ] || aa_msg "promoted new entry '$name' to the shared store"
  done < <(find "$overlay" -mindepth 1 -maxdepth 1 2>/dev/null)

  # 3. claude: seed .claude.json so a fresh account skips onboarding but still
  #    has to log in. Account-scoped keys and caches are stripped.
  local native_json
  native_json="$(aa_config_file claude "$shared")"
  if [ "$tool" = claude ] && [ ! -e "$overlay/.claude.json" ] && [ -s "$native_json" ]; then
    python3 - "$native_json" "$overlay/.claude.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
DROP = {
    "oauthAccount", "userID", "claudeCodeFirstTokenDate", "firstStartTime",
    "numStartups", "cachedGrowthBookFeatures", "cachedGrowthBookFeaturesAt",
    "cachedExperimentFeatures", "cachedExperimentData", "modelAccessCache",
    "orgModelDefaultCache", "passesEligibilityCache", "clientDataCacheSlots",
    "additionalModelOptionsCache", "additionalModelCostsCache",
    "cachedExtraUsageDisabledReason", "passesLastSeenRemaining",
    "passesUpsellSeenCount", "hasVisitedPasses", "groveConfigCache",
}
try:
    with open(src, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}
seed = {k: v for k, v in data.items() if k not in DROP}
# keep per-project trust/MCP config so the new login does not re-prompt
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(seed, fh, indent=2, ensure_ascii=False)
os.chmod(dst, 0o600)
PY
  fi
}

# Pad by terminal display width so CJK labels and long email ids still line up;
# printf's %-14s counts characters, not columns.
# aa_render_table [noheader]  — reads TSV on stdin, writes aligned columns.
aa_render_table() {
  AA_TABLE_HEADER="${1:-header}" python3 -c '
import sys, unicodedata

def width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)

rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
if not rows:
    raise SystemExit
cols = max(len(r) for r in rows)
rows = [r + [""] * (cols - len(r)) for r in rows]
widths = [max(width(r[i]) for r in rows) for i in range(cols)]

def emit(cells):
    out = [c + " " * (widths[i] - width(c)) for i, c in enumerate(cells)]
    print("  ".join(out).rstrip())

import os
if os.environ.get("AA_TABLE_HEADER") == "noheader":
    for row in rows:
        emit(row)
else:
    emit(rows[0])
    emit(["-" * w for w in widths])
    for row in rows[1:]:
        emit(row)
'
}

# --------------------------------------------------------------------------- #
# Locating the real CLI (the wrapper shadows it on PATH)
# --------------------------------------------------------------------------- #
aa_real_bin() {
  local tool="$1" override wrapper_dir candidate
  override="AGENT_ACCT_REAL_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!override:-}" ]; then printf '%s\n' "${!override}"; return 0; fi

  wrapper_dir="$(cd -- "$AA_ROOT/bin" 2>/dev/null && pwd)" || wrapper_dir=""
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    candidate="$dir/$tool"
    [ -x "$candidate" ] || continue
    [ -d "$candidate" ] && continue
    # skip our own wrapper (compare resolved dirs, so symlinked bin dirs match)
    if [ -n "$wrapper_dir" ] && [ "$(cd -- "$dir" 2>/dev/null && pwd)" = "$wrapper_dir" ]; then continue; fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# --------------------------------------------------------------------------- #
# Login helpers
# --------------------------------------------------------------------------- #
# `codex login` defaults to a browser flow that binds localhost:1455 and waits
# for a callback there — unreachable from a container or an SSH shell, and codex
# exposes no config key or env var for the alternative (checked: --device-auth
# is flag-only). So we add it ourselves. Set AGENT_ACCT_CODEX_LOGIN_ARGS="" to
# get the browser flow back, or to any other flags you want.
AA_CODEX_LOGIN_ARGS_DEFAULT="--device-auth"

aa_codex_login_args() {
  local raw="${AGENT_ACCT_CODEX_LOGIN_ARGS-$AA_CODEX_LOGIN_ARGS_DEFAULT}"
  [ -n "$raw" ] || return 0
  # shellcheck disable=SC2086  # deliberate word splitting
  printf '%s\n' $raw
}

# aa_login <tool> <id> [extra args...]
# Runs the CLI's own login flow against that account's store. Extra args are
# forwarded, e.g. `agent-acct login codex beta --device-auth` on a headless box
# where the localhost:1455 browser callback cannot work.
aa_login() {
  local tool="$1" id="$2"; shift 2
  local store real
  store="$(aa_store_dir "$tool" "$id")"
  real="$(aa_real_bin "$tool")" || aa_die "cannot find the real '$tool' executable on PATH"
  [ "$(aa_reg mode "$id" "$tool")" = native ] || aa_sync_overlay "$tool" "$id" quiet

  local extra=() rc
  case "$tool" in
    claude)
      aa_with_creds_guard "$tool" "$store" \
        env CLAUDE_CONFIG_DIR="$store" "$real" auth login "$@"
      rc=$? ;;
    codex)
      # only supply the default when the caller named no login flags of its own
      [ $# -eq 0 ] && mapfile -t extra < <(aa_codex_login_args)
      aa_with_creds_guard "$tool" "$store" \
        env CODEX_HOME="$store" "$real" login ${extra+"${extra[@]}"} "$@"
      rc=$? ;;
  esac
  [ "$(aa_reg mode "$id" "$tool")" = native ] || aa_sync_overlay "$tool" "$id" quiet
  return $rc
}

aa_login_status() {
  local tool="$1" id="$2" store
  store="$(aa_store_dir "$tool" "$id")"
  if ! aa_has_creds "$tool" "$store"; then printf 'logged out\n'; return; fi
  case "$tool" in
    claude)
      python3 - "$(aa_config_file claude "$store")" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        acct = json.load(fh).get("oauthAccount") or {}
except Exception:
    acct = {}
email = acct.get("emailAddress") or "?"
org = acct.get("organizationType") or ""
print(f"{email}" + (f" ({org})" if org else ""))
PY
      ;;
    codex)
      python3 - "$store/auth.json" <<'PY'
import base64, json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        auth = json.load(fh)
except Exception:
    print("?"); raise SystemExit
tok = (auth.get("tokens") or {}).get("id_token") or ""
email = None
parts = tok.split(".")
if len(parts) >= 2:
    body = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(body))
        email = claims.get("email")
        plan = ((claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type"))
    except Exception:
        plan = None
else:
    plan = None
print((email or auth.get("auth_mode") or "?") + (f" ({plan})" if plan else ""))
PY
      ;;
  esac
}
