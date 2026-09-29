# 범용 GPU devcontainer 베이스 — CRS-Robot 프로젝트에서 검증된 구성의 일반화판.
#
# 새 프로젝트에서 쓰는 법: 이 폴더를 <repo>/.devcontainer/ 로 복사한 뒤 프로젝트에
# 맞게 파생시킨다. 파생 시 체크리스트는 README.md 참고.
#
# 베이스 이미지를 바꿀 때 반드시 확인할 것 (Isaac Sim 6.0 파생에서 배운 것):
#   1. 기본 유저 — 벤더 이미지는 비-root 기본 유저일 수 있다 (Isaac: uid 1234).
#      그러면 apt 레이어가 Permission denied 로 죽는다. USER root 를 먼저 선언할 것.
#   2. ENTRYPOINT — 벤더 이미지가 서비스 자동 실행 ENTRYPOINT 를 갖고 있으면
#      (Isaac: runheadless.sh) 컨테이너가 뜰 때마다 그게 PID 1 로 실행된다.
#      dev 컨테이너에선 ENTRYPOINT [] 로 비워야 compose 의 sleep infinity 가 산다.
#   3. HEALTHCHECK — 벤더 이미지의 healthcheck 가 "앱이 떠 있어야 통과"류면
#      dev 컨테이너에선 영원히 unhealthy 다. compose 에서 healthcheck: disable: true.
#   4. Ubuntu 코드네임 — FROM 이 바뀌면 배포판도 바뀔 수 있다 (Isaac 6.0 은 24.04).
#      apt 패키지 가용성(예: glab)과 ROS 배포판 짝이 코드네임에 묶인다.
ARG BASE_IMAGE=nvidia/cuda:12.4.1-devel-ubuntu22.04
FROM ${BASE_IMAGE}

LABEL maintainer="Ryusizz"
LABEL description="GPU devcontainer base — dev user + zsh/dotfiles + AI CLI"

ENV TZ=Asia/Seoul \
    DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# 베이스 이미지의 기본 유저가 비-root 여도 아래 시스템 레이어가 동작하도록 명시.
USER root

# ---------------------------------------------------------------------------
# 1. 시스템 패키지 + 로케일/타임존 + SSH (pubkey 전용으로 강화)
#    비고: glab 은 Ubuntu 24.04(noble)+ 에서만 apt 로 잡힌다. 22.04 베이스면
#    GitLab release 바이너리로 설치하거나 파생 Dockerfile 에서 추가할 것.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo locales tzdata ca-certificates \
        net-tools openssh-server \
        vim tmux git curl wget jq \
        autojump byobu zsh fonts-powerline \
        ripgrep bat htop nvtop ncdu \
        fzf direnv bubblewrap \
        python3-pip python3-dev build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8 \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# ---------------------------------------------------------------------------
# 2. GitHub CLI (gh) — 공식 apt repo
# ---------------------------------------------------------------------------
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3. lazygit — GitHub release latest (apt 미제공)
# ---------------------------------------------------------------------------
RUN LAZYGIT_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
            | grep -Po '"tag_name": "v\K[^"]*') \
    && curl -fsSL -o /tmp/lazygit.tar.gz \
            "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
    && tar -xf /tmp/lazygit.tar.gz -C /tmp lazygit \
    && install /tmp/lazygit /usr/local/bin/ \
    && rm /tmp/lazygit /tmp/lazygit.tar.gz

# ---------------------------------------------------------------------------
# 4. Node.js LTS (NodeSource) — MCP 서버 / Claude Code 플러그인 훅 보조
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ---------------------------------------------------------------------------
# 5. uv — Python 패키지/환경 매니저
# ---------------------------------------------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

# ---------------------------------------------------------------------------
# 6. root용 zsh / Oh-My-Zsh / dotfiles (fallback. 평소 사용은 dev 유저)
# ---------------------------------------------------------------------------
WORKDIR /root
RUN sh -c "$(curl -fsSL https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended \
    && chsh -s $(which zsh) \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
            ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting \
    && git clone --depth=1 https://github.com/Ryusizz/Setup-Vault.git ~/.dotfiles \
    && ln -sf ~/.dotfiles/.vimrc ~/.vimrc \
    && ln -sf ~/.dotfiles/.zshrc ~/.zshrc \
    && ln -sf ~/.dotfiles/agnoster.zsh-theme ~/.oh-my-zsh/themes/agnoster.zsh-theme \
    && mkdir -p ~/.vim/colors \
    && wget -q https://raw.githubusercontent.com/nanotech/jellybeans.vim/master/colors/jellybeans.vim \
            -P ~/.vim/colors

# ---------------------------------------------------------------------------
# 7. 비-root dev 유저 생성 (호스트 UID/GID 매칭 — .env 의 DEV_UID/DEV_GID)
#    bind mount 한 경로를 컨테이너 안에서 그대로 쓰려면 호스트 소유자와 일치해야
#    한다. 확인: 호스트에서 id -u && id -g
# ---------------------------------------------------------------------------
ARG DEV_USER=dev
ARG DEV_UID=1000
ARG DEV_GID=1000
RUN groupadd -g ${DEV_GID} ${DEV_USER} \
    && useradd -m -u ${DEV_UID} -g ${DEV_GID} -s /bin/zsh -G sudo ${DEV_USER} \
    && echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DEV_USER} \
    && chmod 0440 /etc/sudoers.d/${DEV_USER}

# ---------------------------------------------------------------------------
# 8. dev 유저용 zsh / dotfiles / TPM + git-over-ssh 설정
#    ~/.ssh/config 는 호스트 ~/.ssh 를 /home/dev/.ssh-host 로 마운트하는
#    docker-compose.override.yml(개인용, 미추적)과 짝이다 — 마운트가 없으면
#    이 config 는 그냥 놀고 있는다.
# ---------------------------------------------------------------------------
USER ${DEV_USER}
WORKDIR /home/${DEV_USER}
RUN sh -c "$(curl -fsSL https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
            ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && git clone --depth=1 https://github.com/Ryusizz/Setup-Vault.git ~/.dotfiles \
    && ln -sf ~/.dotfiles/.vimrc ~/.vimrc \
    && ln -sf ~/.dotfiles/.zshrc ~/.zshrc \
    && ln -sf ~/.dotfiles/agnoster.zsh-theme ~/.oh-my-zsh/themes/agnoster.zsh-theme \
    && mkdir -p ~/.vim/colors \
    && wget -q https://raw.githubusercontent.com/nanotech/jellybeans.vim/master/colors/jellybeans.vim \
            -P ~/.vim/colors \
    && git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm \
    && mkdir -p ~/.ssh \
    && chmod 700 ~/.ssh \
    && printf 'Host github.com\n    User git\n    IdentityFile /home/dev/.ssh-host/id_ed25519\n    IdentitiesOnly yes\n    StrictHostKeyChecking accept-new\n' > ~/.ssh/config \
    && chmod 600 ~/.ssh/config

# ---------------------------------------------------------------------------
# 9. AI CLI 도구 — build arg 토글 (.env 의 INSTALL_*)
# ---------------------------------------------------------------------------
ARG INSTALL_CLAUDE_CODE=true
ARG INSTALL_CODEX=false
ENV PATH="/home/${DEV_USER}/.local/bin:$PATH"

RUN if [ "$INSTALL_CLAUDE_CODE" = "true" ]; then \
        echo ">>> Installing Claude Code CLI (native installer)..." \
        && curl -fsSL https://claude.ai/install.sh | bash; \
    else \
        echo ">>> Skipping Claude Code CLI (INSTALL_CLAUDE_CODE=$INSTALL_CLAUDE_CODE)"; \
    fi

RUN if [ "$INSTALL_CODEX" = "true" ]; then \
        echo ">>> Installing OpenAI Codex CLI (npm global)..." \
        && sudo npm install -g @openai/codex; \
    else \
        echo ">>> Skipping OpenAI Codex CLI (INSTALL_CODEX=$INSTALL_CODEX)"; \
    fi

# ---------------------------------------------------------------------------
# 10. 마무리
#     USER root: docker exec 직접 진입 시 편의용 (devcontainer attach 는
#     devcontainer.json 의 remoteUser=dev 가 결정한다).
# ---------------------------------------------------------------------------
USER root
WORKDIR /workspaces

# 벤더 베이스 이미지에서 파생할 때 필요하면 여기서 ENTRYPOINT [] 로 비운다
# (파일 상단 체크리스트 2번). nvidia/cuda 베이스는 해당 없음.

# 컨테이너 시작/유지는 docker-compose.yml / devcontainer.json 에서 제어.
