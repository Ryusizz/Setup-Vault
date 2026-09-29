#!/usr/bin/env bash
# 컨테이너 생성 전 HOST 에서 실행 (devcontainer.json initializeCommand).
# 단독 실행도 안전:  bash init-host.sh
#
# bind mount 소스를 올바른 타입·소유자로 사전 생성한다. 안 하면 Docker 가
# root 소유 디렉터리로 자동 생성해서, 컨테이너 안의 dev 유저가 쓰지 못하거나
# (Claude 의 경우) 파일이어야 할 claude.json 이 디렉터리로 만들어진다.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
    echo "[init-host] .env not found (copy .env.example to .env)" >&2
    exit 1
fi

set -a
. ./.env
set +a

: "${DEV_UID:?DEV_UID not set in .env}"
: "${DEV_GID:?DEV_GID not set in .env}"
: "${CLAUDE_STATE_DIR:?CLAUDE_STATE_DIR not set in .env}"
: "${CODEX_STATE_DIR:?CODEX_STATE_DIR not set in .env}"

# claude.json 호스트 경로는 CLAUDE_STATE_DIR 의 형제 파일로 파생
# (docker-compose.yml 의 마운트와 일치. .env 에 별도 변수 없음).
CLAUDE_JSON_PATH="${CLAUDE_STATE_DIR}.json"

# 명령 실행; 권한 실패 시 sudo 로 폴백.
run_or_sudo() {
    if "$@" 2>/dev/null; then return 0; fi
    sudo "$@"
}

# --- Claude / Codex state ---
run_or_sudo mkdir -p "$CLAUDE_STATE_DIR" "$CODEX_STATE_DIR"
run_or_sudo mkdir -p "$(dirname "$CLAUDE_JSON_PATH")"

if [ -d "$CLAUDE_JSON_PATH" ]; then
    echo "[init-host] FATAL: $CLAUDE_JSON_PATH exists as a directory." >&2
    echo "  Likely Docker auto-created it. If empty, fix with: rmdir \"$CLAUDE_JSON_PATH\"" >&2
    exit 1
fi
[ -e "$CLAUDE_JSON_PATH" ] || run_or_sudo touch "$CLAUDE_JSON_PATH"

# --- 프로젝트 전용 상태 디렉터리 (파생 시 여기에 추가) ---
# docker-compose.yml volumes 에 마운트를 추가했으면 반드시 여기서도 같은
# 서브트리를 mkdir -p 하고 아래 chown 목록에 넣는다. 예 (Isaac Sim):
#   run_or_sudo mkdir -p "$ISAAC_STATE_DIR"/{cache/main,logs,config,data,kit/cache}

# 도구가 mode-000 디렉터리를 남기는 경우가 있어 (Isaac/Kit 에서 관측)
# chown -R 이 막히고 sudo 폴백이 불필요하게 발동한다. 우리가 소유한 것 먼저
# best-effort 로 rwX 복구; root 소유는 아래 sudo 폴백이 처리한다.
chmod -R u+rwX \
    "$CLAUDE_STATE_DIR" "$CLAUDE_JSON_PATH" "$CODEX_STATE_DIR" 2>/dev/null || true

run_or_sudo chown -R "${DEV_UID}:${DEV_GID}" \
    "$CLAUDE_STATE_DIR" "$CLAUDE_JSON_PATH" "$CODEX_STATE_DIR"

echo "[init-host] state paths ready (owner ${DEV_UID}:${DEV_GID})"
