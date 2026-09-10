#!/usr/bin/env bash
# Install the agent-accounts wrappers for this user.
#
#   bash ~/.dotfiles/agent-accounts/install.sh            # install
#   bash ~/.dotfiles/agent-accounts/install.sh --uninstall
#
# Idempotent — safe to call from a devcontainer postCreate/postStart hook.
set -euo pipefail

AA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$AA_ROOT/bin"
BEGIN='# >>> agent-accounts >>>'
END='# <<< agent-accounts <<<'

msg()  { printf '\033[36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[install]\033[0m %s\n' "$*"; }

# Emit the PATH line relative to $HOME when possible, so the same rc file works
# for any user whose dotfiles live at ~/.dotfiles (the image clones it for both
# root and dev).
portable_bin_dir() {
  case "$BIN_DIR" in
    "$HOME"/*) printf '$HOME%s\n' "${BIN_DIR#"$HOME"}" ;;
    *)         printf '%s\n' "$BIN_DIR" ;;
  esac
}

block() {
  cat <<BLOCK
$BEGIN
# claude / codex multi-account wrappers — see \$HOME/.dotfiles/agent-accounts/README.md
# Must come after any conda/nvm init so the wrappers win on PATH.
[ -d "$(portable_bin_dir)" ] && export PATH="$(portable_bin_dir):\$PATH" || true
$END
BLOCK
}

strip_block() {  # strip_block <rcfile>
  local rc="$1"
  [ -f "$rc" ] || return 0
  python3 - "$rc" "$BEGIN" "$END" <<'PY'
import sys, pathlib
rc, begin, end = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = rc.read_text(encoding="utf-8").splitlines(keepends=True)
out, skipping = [], False
for line in lines:
    if line.strip() == begin:
        skipping = True
        continue
    if skipping:
        if line.strip() == end:
            skipping = False
        continue
    out.append(line)
rc.write_text("".join(out), encoding="utf-8")
PY
}

install_rc() {  # install_rc <rcfile>
  local rc="$1"
  [ -e "$rc" ] || touch "$rc"
  strip_block "$rc"
  # keep a trailing newline before appending
  [ -s "$rc" ] && [ "$(tail -c1 "$rc" | wc -l)" -eq 0 ] && printf '\n' >> "$rc"
  block >> "$rc"
  msg "PATH 블록을 $rc 에 기록했습니다."
}

RCFILES=("$HOME/.zshrc" "$HOME/.bashrc")

if [ "${1:-}" = "--uninstall" ]; then
  for rc in "${RCFILES[@]}"; do strip_block "$rc"; msg "$rc 에서 제거했습니다."; done
  msg "완료. 계정 저장소(~/.claude/.accounts, ~/.codex/.accounts)는 건드리지 않았습니다."
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 가 필요합니다." >&2; exit 1; }

chmod +x "$AA_ROOT/agent-acct" "$AA_ROOT/codex-unlock" "$AA_ROOT/wrapper.sh" "$AA_ROOT/registry.py"
ln -sfn ../wrapper.sh  "$BIN_DIR/claude"
ln -sfn ../wrapper.sh  "$BIN_DIR/codex"
ln -sfn ../agent-acct  "$BIN_DIR/agent-acct"
ln -sfn ../codex-unlock "$BIN_DIR/codex-unlock"

for rc in "${RCFILES[@]}"; do install_rc "$rc"; done

# Verify the wrappers can still find the real CLIs once they shadow them.
# shellcheck source=lib.sh
. "$AA_ROOT/lib.sh"
for tool in claude codex; do
  if real="$(PATH="$BIN_DIR:$PATH" aa_real_bin "$tool")"; then
    msg "$tool -> $real"
  else
    warn "$tool 실행 파일을 PATH에서 찾지 못했습니다. 설치되어 있는지 확인하세요."
  fi
done

mkdir -p "$AA_CLAUDE_SHARED/.accounts" "$AA_CODEX_SHARED/.accounts"
chmod 700 "$AA_CLAUDE_SHARED/.accounts" "$AA_CODEX_SHARED/.accounts"

cat <<NEXT

설치 완료. 새 셸을 열거나 다음을 실행하세요:

    export PATH="$BIN_DIR:\$PATH"

다음 단계:

    agent-acct adopt <이름>       # 지금 로그인된 계정에 이름 붙이기 (재로그인 불필요)
    claude -u <다른이름>          # 없는 이름이면 등록 + 로그인 안내가 뜹니다
    agent-acct list               # 계정/로그인 상태 확인
NEXT
