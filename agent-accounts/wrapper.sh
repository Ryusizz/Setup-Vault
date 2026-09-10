#!/usr/bin/env bash
# agent-accounts wrapper — installed on PATH as `claude` and `codex`.
#
#   claude              -> real claude, untouched (current login)
#   claude -u d2 ...    -> real claude with CLAUDE_CONFIG_DIR pointed at d2's store
#   codex --user=alice  -> real codex with CODEX_HOME pointed at alice's store
#
# Everything except the account flag is forwarded verbatim.
set -uo pipefail

AA_SELF="${BASH_SOURCE[0]}"
while [ -L "$AA_SELF" ]; do
  AA_LINK="$(readlink "$AA_SELF")"
  case "$AA_LINK" in
    /*) AA_SELF="$AA_LINK" ;;
    *)  AA_SELF="$(dirname "$AA_SELF")/$AA_LINK" ;;
  esac
done
AA_ROOT="$(cd -- "$(dirname -- "$AA_SELF")" && pwd)"
# shellcheck source=lib.sh
. "$AA_ROOT/lib.sh"

AA_TOOL="$(basename "$0")"
case "$AA_TOOL" in
  claude|codex) ;;
  *) aa_die "wrapper invoked as '$AA_TOOL'; expected 'claude' or 'codex'" ;;
esac

AA_REAL="$(aa_real_bin "$AA_TOOL")" || aa_die "cannot find the real '$AA_TOOL' on PATH (set AGENT_ACCT_REAL_$(printf '%s' "$AA_TOOL" | tr a-z A-Z))"

# --------------------------------------------------------------------------- #
# Pull -u / --user out of the argument list
# --------------------------------------------------------------------------- #
account=""
args=()
passthrough=0
while [ $# -gt 0 ]; do
  if [ "$passthrough" -eq 1 ]; then args+=("$1"); shift; continue; fi
  case "$1" in
    --) passthrough=1; args+=("$1"); shift ;;
    -u|--user)
      [ $# -ge 2 ] || aa_die "$1 needs an account id or alias"
      account="$2"; shift 2 ;;
    --user=*) account="${1#--user=}"; shift ;;
    -u=*)     account="${1#-u=}";     shift ;;
    *) args+=("$1"); shift ;;
  esac
done

# `codex login` — with or without an account flag — otherwise starts a browser
# flow bound to localhost:1455, which a container or SSH shell cannot complete.
# This is about the login transport, not about which account is used, so it
# applies to a bare `codex login` too.
is_login_flow=0
if [ "$AA_TOOL" = codex ] && [ "${args[0]-}" = login ]; then
  case " ${args[*]} " in
    *" status "*|*" help "*|*" --help "*|*" -h "*) ;;
    *" --with-api-key "*|*" --with-access-token "*) is_login_flow=1 ;;
    *" --device-auth "*) is_login_flow=1 ;;
    *)
      is_login_flow=1
      login_extra=()
      mapfile -t login_extra < <(aa_codex_login_args)
      if [ ${#login_extra[@]} -gt 0 ]; then
        args+=("${login_extra[@]}")
        aa_msg "codex login ${login_extra[*]} (브라우저 방식으로 돌리려면 AGENT_ACCT_CODEX_LOGIN_ARGS= )"
      fi ;;
  esac
elif [ "$AA_TOOL" = claude ] && [ "${args[0]-}" = auth ] && [ "${args[1]-}" = login ]; then
  is_login_flow=1
fi

# No account flag: behave exactly as before this wrapper existed — except that a
# login still gets the credential guard, since an abandoned one would otherwise
# leave the account logged out.
if [ -z "$account" ]; then
  if [ "$is_login_flow" -eq 1 ]; then
    aa_with_creds_guard "$AA_TOOL" "$(aa_shared_dir "$AA_TOOL")" \
      "$AA_REAL" ${args+"${args[@]}"}
    exit $?
  fi
  exec "$AA_REAL" ${args+"${args[@]}"}
fi

# --------------------------------------------------------------------------- #
# Resolve the account, registering it interactively if it is new
# --------------------------------------------------------------------------- #
if ! id="$(aa_reg resolve "$account" 2>/dev/null)"; then
  aa_err "'$account' 은(는) 등록되지 않은 계정입니다."
  if [ -n "$(aa_reg table 2>/dev/null)" ]; then
    printf '  등록된 계정:\n' >&2
    aa_reg table 2>/dev/null \
      | awk -F'\t' 'BEGIN{OFS="\t"} {print "   ", $1, ($2=="-" ? "" : $2), ($3=="-" ? "" : $3)}' \
      | aa_render_table noheader >&2
  else
    printf '  등록된 계정이 아직 없습니다.\n' >&2
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    aa_die "대화형 터미널이 아니라 등록할 수 없습니다. 먼저 'agent-acct add $account' 를 실행하세요."
  fi
  printf '\n' >&2
  read -r -p "새 계정으로 등록할까요? [Y/n] " reply
  case "${reply:-Y}" in
    [nN]*) aa_die "취소했습니다." ;;
  esac
  attempts=0
  while :; do
    read -r -p "  계정 ID [$account]: " new_id
    new_id="${new_id:-$account}"
    read -r -p "  약어 (공백/쉼표 구분, 없으면 Enter): " new_aliases
    read -r -p "  표시 이름 (선택): " new_label
    if id="$(aa_reg add "$new_id" --alias "${new_aliases:-}" --label "${new_label:-}")"; then
      break
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -ge 3 ] && aa_die "등록에 실패했습니다."
    aa_warn "다시 입력해 주세요."
  done
  aa_msg "계정 '$id' 을(를) 등록했습니다."
fi

# --------------------------------------------------------------------------- #
# Point the CLI at that account's store
# --------------------------------------------------------------------------- #
mode="$(aa_reg mode "$id" "$AA_TOOL")"
store="$(aa_store_dir "$AA_TOOL" "$id")"
[ "$mode" = native ] || aa_sync_overlay "$AA_TOOL" "$id"

# `claude -u X auth login` / `codex -u X login` are themselves the login path —
# don't try to bootstrap credentials before handing those through.
first_arg="${args[0]-}"
case "$first_arg" in
  login|logout|auth) skip_login_bootstrap=1 ;;
  *) skip_login_bootstrap=0 ;;
esac

if [ "$skip_login_bootstrap" -eq 0 ] && ! aa_has_creds "$AA_TOOL" "$store"; then
  aa_msg "계정 '$id' 에는 $AA_TOOL 로그인 정보가 없습니다."
  case "$AA_TOOL" in
    codex)
      # codex needs an explicit login pass before the TUI is usable.
      [ -t 0 ] || aa_die "대화형 터미널이 아니라 로그인할 수 없습니다. 'agent-acct login codex $id' 를 먼저 실행하세요."
      aa_msg "로그인을 진행합니다..."
      aa_login codex "$id" || aa_die "codex 로그인이 실패했습니다." ;;
    claude)
      # Claude Code opens its own /login flow on start, so just hand it over.
      aa_msg "Claude Code 화면에서 /login 으로 로그인하세요." ;;
  esac
fi

case "$AA_TOOL" in
  claude) export CLAUDE_CONFIG_DIR="$store" ;;
  codex)  export CODEX_HOME="$store" ;;
esac
export AGENT_ACCT_ACTIVE="$id"

if [ "$is_login_flow" -eq 1 ]; then
  aa_with_creds_guard "$AA_TOOL" "$store" "$AA_REAL" ${args+"${args[@]}"}
  exit $?
fi

exec "$AA_REAL" ${args+"${args[@]}"}
