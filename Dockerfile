FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

LABEL maintainer="Ryuja <ryuasizz@gmail.com>"
LABEL description="Modern AI Testbed with Zsh & Dotfiles"

ENV TZ=Asia/Seoul \
    DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# 1. 패키지 설치
# (ssh 실행을 위한 mkdir /var/run/sshd 포함)
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata \
    net-tools vim openssh-server tmux git curl wget \
    autojump byobu zsh fonts-powerline ca-certificates \
    ripgrep bat htop nvtop ncdu \
    python3-pip python3-dev build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8 \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && mkdir /var/run/sshd \
    && sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# 2. Zsh 및 Dotfiles 설정
WORKDIR /root

# Oh-My-Zsh 및 플러그인 설치
RUN sh -c "$(curl -fsSL https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended && \
    chsh -s $(which zsh) && \
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# [수정됨] Dotfiles Clone 및 Symlink 연결
# Setup-Vault 안에 agnoster.zsh-theme 파일도 있다고 가정하고 링크 연결
RUN git clone https://github.com/Ryusizz/Setup-Vault.git ~/.dotfiles && \
    ln -sf ~/.dotfiles/.vimrc ~/.vimrc && \
    ln -sf ~/.dotfiles/.zshrc ~/.zshrc && \
    # 테마도 git repo 파일로 링크 (Setup-Vault 루트에 파일이 있다고 가정)
    ln -sf ~/.dotfiles/agnoster.zsh-theme ~/.oh-my-zsh/themes/agnoster.zsh-theme && \
    mkdir -p ~/.vim/colors && \
    wget https://raw.githubusercontent.com/nanotech/jellybeans.vim/master/colors/jellybeans.vim -P ~/.vim/colors

WORKDIR /workspaces

# ENTRYPOINT 삭제됨 (DevContainer가 제어하도록 둠)
# SSH 실행 등은 devcontainer.json에서 처리
