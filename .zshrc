```Shell
export ZSH="$HOME/.oh-my-zsh"
# export LANG=en_US.utf8 #일단 없애보자

ZSH_THEME="agnoster"

plugins=(
        git
        zsh-autosuggestions
        zsh-syntax-highlighting
        autojump
        )

source $ZSH/oh-my-zsh.sh

__conda_setup="$('/root/anaconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
	eval "$__conda_setup"
else
	if [ -f "/root/anaconda3/etc/profile.d/conda.sh" ]; then
		. "/root/anaconda3/etc/profile.d/conda.sh"
	else
		export PATH="/root/anaconda3/bin:$PATH"
	fi
fi
unset __conda_setup
# <<< conda initialize <<<

[ -r /root/.byobu/prompt ] && . /root/.byobu/prompt   #byobu-prompt#
