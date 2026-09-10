# agent-accounts

`claude` / `codex` 를 **여러 로그인 계정으로 번갈아 쓰되, 작업(세션·히스토리·설정)은
전부 공유**하기 위한 래퍼입니다. 한 계정이 rate limit 에 걸리면 다른 계정으로
넘어가서 **같은 대화를 그대로 이어서** 재개할 수 있습니다.

```
claude                       # 지금 로그인된 계정 (동작 변화 없음)
claude -u d2                 # d2 계정으로 실행
claude --user alice --resume # alice 계정으로, 세션 목록은 d2 것까지 전부 보임
codex -u d2 exec "fix tests"
agent-acct list              # 계정 / 로그인 상태
```

## 어떻게 되는가

두 CLI 모두 "설정 홈" 디렉터리 하나를 환경변수로 바꿀 수 있습니다.

| CLI | 환경변수 | 인증 파일 | 세션 저장소 |
|---|---|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` | `.credentials.json`, `.claude.json` | `projects/*.jsonl` |
| Codex | `CODEX_HOME` | `auth.json` | `sessions/`, `thread_history_1.sqlite`, `history.jsonl` |

문제는 인증과 세션이 **같은 디렉터리 안에** 있다는 점입니다. 그래서 이 도구는
계정별 **오버레이 디렉터리**를 만들고, 그 안의 항목을 전부 공유 저장소로 향하는
심볼릭 링크로 채웁니다. 인증 파일만 실제 파일로 남습니다.

```
~/.claude/                        <- 공유 저장소 (실제 파일)
  projects/  history.jsonl  settings.json  plugins/  skills/ ...
  .accounts/
    registry.json                 <- 계정 / 약어 레지스트리
    alice/                        <- CLAUDE_CONFIG_DIR=여기
      .credentials.json           (실제 파일, alice 전용)
      .claude.json                (실제 파일, alice 전용)
      projects      -> ~/.claude/projects       (공유)
      history.jsonl -> ~/.claude/history.jsonl  (공유)
      settings.json -> ~/.claude/settings.json  (공유)
      ...

~/.codex/  .accounts/alice/{auth.json(실제), sessions->, *.sqlite->, config.toml->}
```

SQLite 파일도 링크로 공유됩니다. SQLite 는 DB 경로의 심볼릭 링크를 해석한 뒤
`-wal`/`-shm` 을 **실제 파일 옆**에 만들기 때문에, 링크를 통해 쓴 내용이 공유
DB 에 그대로 들어갑니다(검증 완료). 그래서 `-wal`/`-shm` 은 링크하지 않습니다.

### 계정별로 분리되는 것 (의도적)

| CLI | 항목 | 이유 |
|---|---|---|
| claude | `.credentials.json` | OAuth 토큰 |
| claude | `.claude.json`, `backups/` | 계정 정보 + 계정 단위 캐시. 새 계정에는 인증 관련 키만 제거하고 복사해서 온보딩/신뢰 프롬프트를 건너뜁니다 |
| claude | `daemon*`, `jobs/` | 백그라운드 에이전트 데몬. 공유하면 잡이 "먼저 데몬을 띄운 계정"의 할당량으로 돌아버립니다 |
| codex | `auth.json` | OAuth 토큰 |
| codex | `models_cache.json` | 요금제별로 모델 목록이 다름 |

그 외 **모든 것**(대화 트랜스크립트, 프롬프트 히스토리, 설정, 스킬, 플러그인,
MCP 설정, 프로젝트 신뢰 상태)은 공유됩니다.

### 자동 적응

`aa_sync_overlay` 가 실행 때마다 돌면서
1. 공유 저장소에 새로 생긴 항목 → 오버레이에 링크 추가
2. 오버레이에 CLI 가 새로 만든 실제 파일 → 공유 저장소로 옮기고 링크로 교체
3. 끊어진 링크 → 제거

CLI 가 업데이트되며 새 파일(`state_6.sqlite` 같은)을 만들어도 따로 손볼 필요가
없습니다.

## 설치

```bash
bash ~/.dotfiles/agent-accounts/install.sh
exec zsh                                  # 또는 새 터미널
agent-acct adopt work                     # 지금 로그인된 계정에 이름 붙이기 (재로그인 불필요)
agent-acct alias work w                   # 약어 추가
```

### 다른 머신 / 재빌드된 컨테이너

이 저장소를 clone 하고 `install.sh` 만 실행하면 됩니다. Dockerfile 이 이미
`~/.dotfiles` 로 clone 하는 환경이라면 `.zshrc` 블록까지 따라오므로 clone 만으로
끝납니다. 그렇지 않은 곳이면 아무 데나 두고 실행해도 됩니다:

```bash
git clone --depth=1 https://github.com/Ryusizz/Setup-Vault.git ~/.dotfiles
bash ~/.dotfiles/agent-accounts/install.sh
```

**로그인은 따라오지 않습니다.** 토큰(`~/.claude/.accounts/*/`,
`~/.codex/.accounts/*/`)과 계정 레지스트리(`~/.claude/.accounts/registry.json`)는
이 저장소 밖에 있고, 그래야 합니다 — **Setup-Vault 는 공개 저장소입니다.**
새 머신에서는 계정마다 다시 로그인하세요. 계정/약어 목록만 옮기고 싶다면
`registry.json` 을 복사하면 됩니다(비밀 정보 없음, 이메일은 들어 있음).

같은 호스트에서 컨테이너를 재빌드하는 경우는 `~/.claude` 와 `~/.codex` 가
bind-mount 라 **로그인이 그대로 남습니다.**

`install.sh` 는 `~/.dotfiles/agent-accounts/bin` 을 PATH 맨 앞에 넣는 블록을
`~/.zshrc` / `~/.bashrc` 에 씁니다. `~/.zshrc` 는 이 저장소의 파일을 가리키는
심볼릭 링크이므로, 커밋해두면 컨테이너를 재빌드해도 자동으로 따라옵니다.

제거: `bash ~/.dotfiles/agent-accounts/install.sh --uninstall`
(계정 저장소는 지우지 않습니다.)

## 새 계정 추가

등록되지 않은 이름을 주면 그 자리에서 물어봅니다.

```
$ claude -u alice
[agent-acct] 'alice' 은(는) 등록되지 않은 계정입니다.
  등록된 계정:
  work             w,wk        업무용

새 계정으로 등록할까요? [Y/n] y
  계정 ID [alice]:
  약어 (공백/쉼표 구분, 없으면 Enter): a al
  표시 이름 (선택): Alice
[agent-acct] 계정 'alice' 을(를) 등록했습니다.
[agent-acct] 계정 'alice' 에는 claude 로그인 정보가 없습니다.
[agent-acct] Claude Code 화면에서 /login 으로 로그인하세요.
```

Codex 는 `codex login` 이 먼저 실행된 뒤 원래 명령으로 이어집니다.

### codex 로그인은 기본이 device-auth

`codex login` 의 기본 동작은 `localhost:1455` 에 콜백 서버를 띄우는 브라우저
방식인데, 컨테이너나 SSH 셸에서는 그 포트에 브라우저가 닿지 못해 끝나지 않습니다.
codex 쪽에 이걸 바꿀 설정 키나 환경변수가 없어서(확인함 — `--device-auth` 는
플래그 전용) 래퍼가 대신 붙입니다.

```bash
codex login                 # -> device code 방식 (링크 + 일회용 코드)
codex -u alice login        # 마찬가지
agent-acct login codex alice
```

로그인 방식만 바꾸는 것이라 계정을 지정하지 않은 `codex login` 에도 적용됩니다.
브라우저 방식으로 되돌리려면:

```bash
AGENT_ACCT_CODEX_LOGIN_ARGS= codex login
```

이 변수에 원하는 플래그를 넣어 기본값을 바꿀 수도 있습니다. `login status`,
`login --help`, `--with-api-key`, `--with-access-token` 은 손대지 않습니다.

계정 ID 로는 **이메일 주소를 그대로** 쓸 수 있습니다. 허용 문자는 영문/숫자로
시작하는 `A-Z a-z 0-9 . _ - + @` (최대 128자)이고, 공백과 `/` 는 안 됩니다.
잘못 입력하면 그 자리에서 다시 물어봅니다(3회).

```bash
agent-acct add "alice@gmail.com" --alias alice,a --label "개인용"
```

비대화형(스크립트/CI)에서는 미리 등록해야 합니다:

```bash
agent-acct add alice --alias a,al --label "Alice"
agent-acct login claude alice
agent-acct login codex  alice
```

이미 있는 계정에 같은 명령을 다시 쓰면 약어/표시 이름만 갱신됩니다.

## 명령

```
agent-acct list                    계정 목록 + 로그인 상태
agent-acct add [<id>]              새 계정 등록 (대화형 / 플래그)
agent-acct adopt <id> [tool...]    현재 로그인을 <id> 로 편입 (재로그인 불필요)
agent-acct alias|unalias <id> ...  약어 관리
agent-acct login|logout <tool> <id>
agent-acct status [<id>]
agent-acct sync [<id>]             오버레이 링크 재동기화
agent-acct which <alias>           약어 -> 계정 ID
agent-acct path <tool> <id>        해당 계정의 CLI home
agent-acct rm <id>                 등록 해제 (오버레이 삭제 확인)
agent-acct doctor                  설치/PATH/저장소 점검
```

## Codex 세션의 남은 writer 종료

원격 PC나 VS Code 연결이 끊긴 뒤 서버의 Codex 프로세스가 살아 있으면 `resume` 이
`already has an active writer` 로 실패할 수 있습니다. 인자 없이 실행하면 writer
lock을 실제로 잡고 있는 Codex 프로세스를 자동으로 찾습니다. 하나면 바로 종료
대상으로 삼고, 여러 개면 PID·시작 시각·TTY·작업 디렉터리를 보여주고 번호로
고르게 합니다.

```bash
codex-unlock
codex-unlock --dry-run

# 필요할 때만 특정 thread로 제한
codex-unlock 01a0855a-f821-7503-83e1-905ce7ae2782
codex-unlock --yes --force 01a0855a-f821-7503-83e1-905ce7ae2782
```

기본 동작은 소유 PID를 보여주고 `SIGTERM` 전에 확인합니다. 5초 뒤에도 살아 있으면
`SIGKILL` 여부를 다시 묻습니다. `--yes` 는 첫 확인을 생략하고, `--force` 는 두 번째
확인도 생략합니다. 단순히 빈 lock 파일을 지우지는 않습니다. writer가 살아 있는
상태에서 파일만 지우면 두 프로세스가 같은 세션을 동시에 쓸 수 있기 때문입니다.

## 알아둘 점

- **옵션 없이 실행하면 지금까지와 100% 동일**합니다. 환경변수를 건드리지 않으므로
  VS Code 확장이나 다른 스크립트가 CLI 를 직접 불러도 안전합니다.
- `adopt` 로 편입한 계정은 `mode=native` — 저장소가 `~/.claude`, `~/.codex` 자체입니다.
  CLI 당 native 계정은 하나뿐이고, 나머지는 오버레이를 씁니다.
- `--resume` 는 계정과 무관하게 전체 세션을 보여줍니다. 반면 `-c/--continue` 가
  참고하는 "이 디렉터리의 마지막 세션"은 `.claude.json` 에 있어 계정별입니다.
  계정을 바꿔 이어받을 때는 `--resume` 를 쓰세요.
- 두 계정을 **동시에** 띄우는 것도 됩니다(SQLite 잠금이 처리). 다만 Codex 의
  app-server 데몬과 Claude 의 백그라운드 데몬은 계정별로 분리돼 있어,
  한 계정에서 띄운 백그라운드 잡은 다른 계정의 목록에 나타나지 않습니다.
- **중단된 로그인은 되돌립니다.** `codex login` 은 시작하자마자 기존 `auth.json` 을
  지우기 때문에, Ctrl-C 나 끊긴 SSH 로 로그인이 끝나지 않으면 멀쩡하던 계정이
  로그아웃 상태가 됩니다. 래퍼는 로그인 전에 인증 파일을 복사해 두고, 새 인증이
  생기지 않았으면 되돌립니다. SIGKILL 로 죽어 백업만 남은 경우에는 다음 실행 때
  복구합니다. 계정 지정 없이 친 `codex login` 에도 적용됩니다.
- tmux 안에서도 그대로 씁니다. 대화형 zsh 에서 tmux 를 띄우면 PATH 가 그대로
  상속됩니다. `tmux new-session -d 'bash -c ...'` 처럼 rc 를 읽지 않는 셸에서
  계정을 지정하려면 `~/.dotfiles/agent-accounts/bin/claude -u <id> ...` 처럼
  전체 경로를 쓰세요.
- 저장소 위치는 `~/.claude`, `~/.codex` 안입니다. 이 devcontainer 에서
  재빌드를 견디는 경로가 그 둘(과 `~/.claude.json`)뿐이기 때문입니다.
  다른 환경에서는 `AGENT_ACCT_CLAUDE_HOME`, `AGENT_ACCT_CODEX_HOME`,
  `AGENT_ACCT_REGISTRY` 로 바꿀 수 있습니다.

## 파일

```
agent-accounts/
  install.sh     PATH 블록 설치/제거
  wrapper.sh     bin/claude, bin/codex 가 가리키는 실제 래퍼
  agent-acct     계정 관리 CLI
  codex-unlock   thread writer lock 소유 Codex 프로세스 종료
  registry.py    계정/약어 레지스트리 (JSON)
  lib.sh         오버레이 동기화, 저장소 경로, 로그인 상태 조회
  bin/           PATH 에 올라가는 심볼릭 링크
```
