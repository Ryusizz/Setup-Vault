# 범용 GPU devcontainer 템플릿

CRS-Robot 프로젝트(Isaac Sim 파생)에서 검증된 구성을 일반화한 베이스.
새 프로젝트를 시작할 때 이 폴더를 통째로 복사해서 파생시킨다.

```bash
cp -r ~/.dotfiles/devcontainer <repo>/.devcontainer
```

| 파일 | 역할 |
|---|---|
| `Dockerfile` | CUDA 베이스 + dev 유저 + zsh/dotfiles + gh/lazygit/node/uv + AI CLI 토글 |
| `docker-compose.yml` | `.env` 주도 구성, GPU 예약, `init: true`, 상태 마운트 |
| `devcontainer.json` | initializeCommand/postCreate/postStart 훅, remoteUser=dev |
| `init-host.sh` | bind mount 소스 사전 생성+chown (root-owned 자동 생성 방지) |
| `.env.example` | 머신/사용자별 값 템플릿 |
| `docker-compose.override.yml.example` | 개인 ~/.ssh 마운트 패턴 (트레이드오프 주석 포함) |
| `.gitignore` | `.env`·override·개인 훅 미추적 (복사한 프로젝트에서도 적용) |

## 셋업

```bash
cd <repo>/.devcontainer
cp .env.example .env
$EDITOR .env           # CONTAINER_NAME/COMPOSE_PROJECT_NAME, DEV_UID/GID, state 경로
bash init-host.sh      # 상태 디렉터리 생성 + chown (idempotent)

docker compose up -d --build
docker exec -it -u dev "$(grep ^CONTAINER_NAME .env | cut -d= -f2)" zsh
```

VS Code 는 "Reopen in Container". SSH 는 `ssh -p <SSH_PORT> dev@<host>`
(pubkey 전용 — override 로 ~/.ssh 를 마운트하면 postStart 가 authorized_keys 를 씨딩).

## 공유 서버에서 여러 사람이 쓸 때

`.env` 의 아래 값이 **사용자별로 달라야 한다**:

```env
COMPOSE_PROJECT_NAME=<proj>-<user>   # 같으면 남의 컨테이너를 recreate 할 수 있다
CONTAINER_NAME=<proj>-<user>
SSH_PORT=<사용자별 포트>
CLAUDE_STATE_DIR=/mnt/data/<proj>/state/<user>/claude
CODEX_STATE_DIR=/mnt/data/<proj>/state/<user>/codex
```

개인 설정은 추적 파일에 넣지 않는다 — 매 시작마다 실행할 것이 있으면 gitignored
`local-poststart.sh` 를 만든다 (없는 사람은 no-op).

## 파생 체크리스트 (Isaac Sim 6.0 파생에서 배운 것)

베이스 이미지를 벤더 이미지로 바꿀 때:

1. **기본 유저** — 비-root 기본 유저(Isaac: uid 1234)면 apt 레이어가 죽는다.
   `USER root` 를 먼저. 설치 트리가 0750 이면 dev 유저가 진입도 못 하니
   `chmod o+rx` 로 최상위만 연다.
2. **ENTRYPOINT** — 서비스 자동 실행 ENTRYPOINT(Isaac: runheadless.sh)는
   `ENTRYPOINT []` 로 비운다. 안 비우면 매 시작마다 root PID 1 로 앱이 뜨고,
   나중에 수동 실행한 인스턴스와 충돌한다.
3. **HEALTHCHECK** — "앱이 떠 있어야 통과"류 healthcheck 는 dev 컨테이너에서
   영원히 unhealthy. compose 에서 `healthcheck: disable: true`.
4. **Ubuntu 코드네임** — FROM 교체로 배포판이 바뀔 수 있다 (Isaac 6.0 = 24.04).
   apt 패키지 가용성(glab 은 noble+)과 ROS 배포판 짝이 여기 묶인다.
5. **캐시 마운트** — 프로젝트 도구가 대용량 캐시를 쓰면(셰이더 등) bind mount 로
   빼서 rebuild 를 넘겨 살리되, **compose 의 volumes 와 init-host.sh 양쪽에**
   추가한다. 도구가 실제로 쓰는 경로를 확인할 것 — Isaac 은 portable 모드가
   HOME 기반 캐시를 무시하고 설치 트리 하위(`kit/cache`)를 썼다.
6. **network_mode: host** — 미디어 스트림 등 포트 매핑이 안 통하는 워크로드에만.
   `ports:` 블록과 상호 배타이고, sshd 가 호스트 22번과 충돌하므로 postStart 의
   `service ssh start` 도 뺀다. 상태 경로는 빠른 로컬 디스크에 (네트워크 공유 금지).
