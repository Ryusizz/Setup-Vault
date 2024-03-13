FROM nvidia/cuda:12.3.1-devel-ubuntu20.04
MAINTAINER Ryuja <ryuasizz@gmail.com>

ENV TZ=Asia/Seoul

RUN \
	ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
	apt-get update && \
	apt-get install -y sudo && \
	sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys A4B469963BF863CC && \
	apt update && \
	apt -y install net-tools vim openssh-server tmux git curl autojump byobu && \
	echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
	echo "X11UseLocalhost no" >> /etc/ssh/sshd_config && \
	systemctl enable ssh && \
	wget https://raw.githubusercontent.com/Ryusizz/Setup-Vault/main/.vimrc -O ~/.vimrc && \
	mkdir -p ~/.vim/colors && wget https://raw.githubusercontent.com/nanotech/jellybeans.vim/master/colors/jellybeans.vim -P ~/.vim/colors && \
	wget https://raw.githubusercontent.com/Ryusizz/Setup-Vault/main/f-keys.tmux -O /usr/share/byobu/keybindings/f-keys.tmux


RUN \
	apt install -y locales && locale-gen en_US.UTF-8 && \
	sudo apt install -y zsh && chsh -s `which zsh` && \
	curl -L https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh | sh && \
	sudo apt install -y fonts-powerline && \
	git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
	git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting && \
	wget https://raw.githubusercontent.com/Ryusizz/Setup-Vault/main/.zshrc -O ~/.zshrc && \
	wget https://raw.githubusercontent.com/Ryusizz/Setup-Vault/main/agnoster.zsh-theme -O ~/.oh-my-zsh/themes/agnoster.zsh-theme
	
WORKDIR /workspace/repo

#EXPOSE 22
#EXPOSE 6006
#EXPOSE 8888
#EXPOSE 8889

ENTRYPOINT service ssh restart && zsh

