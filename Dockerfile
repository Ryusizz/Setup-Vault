FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

LABEL maintainer="Ryusizz"
LABEL description="Modern AI Testbed with Zsh & Dotfiles"

ENV TZ=Asia/Seoul \
    DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# 1. 패키지 설치
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata \
    net-tools vim openssh-server tmux git curl wget \
    autojump byobu zsh fonts-powerline ca-certificates \
    ripgrep bat htop nvtop ncdu \
    python3-pip python3-dev build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8 \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# 2. UV 설치 (Conda 대체)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

# 3. Zsh 및 Dotfiles 설정
WORKDIR /root

# 4. Oh-My-Zsh 및 플러그인 설치
RUN sh -c "$(curl -fsSL https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended && \
    chsh -s $(which zsh) && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# 5. Dotfiles Clone 및 Symlink 연결
RUN git clone --depth=1 https://github.com/Ryusizz/Setup-Vault.git ~/.dotfiles && \
    ln -sf ~/.dotfiles/.vimrc ~/.vimrc && \
    ln -sf ~/.dotfiles/.zshrc ~/.zshrc && \
    ln -sf ~/.dotfiles/agnoster.zsh-theme ~/.oh-my-zsh/themes/agnoster.zsh-theme && \
    mkdir -p ~/.vim/colors && \
    wget -q https://raw.githubusercontent.com/nanotech/jellybeans.vim/master/colors/jellybeans.vim -P ~/.vim/colors

WORKDIR /workspaces

# 컨테이너 시작/유지/SSH 실행은 devcontainer.json에서 제어
