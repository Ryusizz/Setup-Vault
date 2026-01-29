# vim:ft=zsh ts=2 sw=2 sts=2
#
# agnoster's Theme - Modernized Custom Version
# Based on latest upstream + User optimizations (Box emoji, Performance, Relative Path)

### Segment drawing
CURRENT_BG='NONE'

case ${SOLARIZED_THEME:-dark} in
    light)
      CURRENT_FG=${CURRENT_FG:-'white'}
      CURRENT_DEFAULT_FG=${CURRENT_DEFAULT_FG:-'white'}
      ;;
    *)
      CURRENT_FG=${CURRENT_FG:-'black'}
      CURRENT_DEFAULT_FG=${CURRENT_DEFAULT_FG:-'default'}
      ;;
esac

### Theme Configuration Initialization
# 사용자 지정 256 컬러를 여기서 변수로 정의합니다. (수정이 필요하면 여기만 고치면 됩니다)

# Current working directory (User: 081)
: ${AGNOSTER_DIR_FG:=000}
: ${AGNOSTER_DIR_BG:=081}

# Context (Box Emoji Background, User: 073)
: ${AGNOSTER_CONTEXT_FG:=000}
: ${AGNOSTER_CONTEXT_BG:=073}

# Git related (User: Dirty=228)
: ${AGNOSTER_GIT_CLEAN_FG:=${CURRENT_FG}}
: ${AGNOSTER_GIT_CLEAN_BG:=green}
: ${AGNOSTER_GIT_DIRTY_FG:=black}
: ${AGNOSTER_GIT_DIRTY_BG:=228}

# Terraform
: ${AGNOSTER_TERRAFORM_FG:=228}
: ${AGNOSTER_TERRAFORM_BG:=099}

# AWS Profile colors
: ${AGNOSTER_AWS_PROD_FG:=yellow}
: ${AGNOSTER_AWS_PROD_BG:=red}
: ${AGNOSTER_AWS_FG:=black}
: ${AGNOSTER_AWS_BG:=green}

# Status symbols
: ${AGNOSTER_STATUS_RETVAL_FG:=red}
: ${AGNOSTER_STATUS_ROOT_FG:=yellow}
: ${AGNOSTER_STATUS_JOB_FG:=cyan}
: ${AGNOSTER_STATUS_FG:=${CURRENT_DEFAULT_FG}}
: ${AGNOSTER_STATUS_BG:=black}


# Special Powerline characters
() {
  local LC_ALL="" LC_CTYPE="en_US.UTF-8"
  SEGMENT_SEPARATOR=$'\ue0b0'
}

prompt_segment() {
  local bg fg
  [[ -n $1 ]] && bg="%K{$1}" || bg="%k"
  [[ -n $2 ]] && fg="%F{$2}" || fg="%f"
  if [[ $CURRENT_BG != 'NONE' && $1 != $CURRENT_BG ]]; then
    echo -n " %{$bg%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR%{$fg%} "
  else
    echo -n "%{$bg%}%{$fg%} "
  fi
  CURRENT_BG=$1
  [[ -n $3 ]] && echo -n $3
}

prompt_end() {
  if [[ -n $CURRENT_BG ]]; then
    echo -n " %{%k%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR"
  else
    echo -n "%{%k%}"
  fi
  echo -n "%{%f%}"
  CURRENT_BG=''
}

### Prompt components

# Context: 📦 (Docker environment indicator)
prompt_context() {
  # 하드코딩 대신 위에서 정의한 변수 사용
  prompt_segment "$AGNOSTER_CONTEXT_BG" "$AGNOSTER_CONTEXT_FG" "📦"
}

# Terraform
prompt_terraform() {
  local terraform_info=$(tf_prompt_info 2>/dev/null)
  [[ -z "$terraform_info" ]] && return
  prompt_segment "$AGNOSTER_TERRAFORM_BG" "$AGNOSTER_TERRAFORM_FG" "TF: $terraform_info"
}

# Dir: repo_root를 받아 처리 (최적화 적용)
prompt_dir() {
  local repo_root display_root
  repo_root="${1:-}" # 전달받은 repo_root 사용

  if [[ -z "$repo_root" ]]; then
    repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
  fi

  if [[ -n "$repo_root" ]]; then
    # Git Root만 표시
    display_root="$repo_root"
    display_root="${display_root/#$HOME/~}"
    prompt_segment "$AGNOSTER_DIR_BG" "$AGNOSTER_DIR_FG" "$display_root"
  else
    # 일반 경로
    prompt_segment "$AGNOSTER_DIR_BG" "$AGNOSTER_DIR_FG" '%~'
  fi
}

# Git: Branch + Relative Path (최적화 적용)
prompt_git() {
  (( $+commands[git] )) || return
  if [[ "$(command git config --get oh-my-zsh.hide-status 2>/dev/null)" = 1 ]]; then
    return
  fi

  local PL_BRANCH_CHAR
  () {
    local LC_ALL="" LC_CTYPE="en_US.UTF-8"
    PL_BRANCH_CHAR=$'\ue0a0'         # 
  }
  local ref dirty mode repo_path repo_root

  if [[ "$(command git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]]; then
    # 전달받은 repo_root 재사용
    repo_root="${1:-}"
    if [[ -z "$repo_root" ]]; then
      repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || return
    fi

    repo_path=$(command git rev-parse --git-dir 2>/dev/null)
    dirty=$(parse_git_dirty)
    ref=$(command git symbolic-ref HEAD 2> /dev/null) || \
    ref="◈ $(command git describe --exact-match --tags HEAD 2> /dev/null)" || \
    ref="➦ $(command git rev-parse --short HEAD 2> /dev/null)"

    if [[ -n $dirty ]]; then
      prompt_segment "$AGNOSTER_GIT_DIRTY_BG" "$AGNOSTER_GIT_DIRTY_FG"
    else
      prompt_segment "$AGNOSTER_GIT_CLEAN_BG" "$AGNOSTER_GIT_CLEAN_FG"
    fi

    local ahead behind
    ahead=$(command git log --oneline @{upstream}.. 2>/dev/null)
    behind=$(command git log --oneline ..@{upstream} 2>/dev/null)
    if [[ -n "$ahead" ]] && [[ -n "$behind" ]]; then
      PL_BRANCH_CHAR=$'\u21c5'
    elif [[ -n "$ahead" ]]; then
      PL_BRANCH_CHAR=$'\u21b1'
    elif [[ -n "$behind" ]]; then
      PL_BRANCH_CHAR=$'\u21b0'
    fi

    if [[ -e "${repo_path}/BISECT_LOG" ]]; then
      mode=" <B>"
    elif [[ -e "${repo_path}/MERGE_HEAD" ]]; then
      mode=" >M<"
    elif [[ -e "${repo_path}/rebase" || -e "${repo_path}/rebase-apply" || \
      -e "${repo_path}/rebase-merge" || -e "${repo_path}/../.dotest" ]]; then
      mode=" >R>"
    fi

    setopt promptsubst
    autoload -Uz vcs_info

    zstyle ':vcs_info:*' enable git
    zstyle ':vcs_info:*' get-revision true
    zstyle ':vcs_info:*' check-for-changes true
    zstyle ':vcs_info:*' stagedstr '✚'
    zstyle ':vcs_info:*' unstagedstr '±'
    zstyle ':vcs_info:*' formats ' %u%c'
    zstyle ':vcs_info:*' actionformats ' %u%c'
    vcs_info
    echo -n "${${ref:gs/%/%%}/refs\/heads\//$PL_BRANCH_CHAR }${vcs_info_msg_0_%% }${mode}"

    # 상대 경로 함수 호출
    prompt_git_relative
  fi
}

# Helper: Git Native 방식으로 상대 경로 표시 (Symlink Safe)
prompt_git_relative() {
  local path_in_repo
  path_in_repo=$(command git rev-parse --show-prefix 2>/dev/null)
  path_in_repo="${path_in_repo%/}"

  if [[ -n "$path_in_repo" ]]; then
    # Dir 색상 변수 재사용
    prompt_segment "$AGNOSTER_DIR_BG" "$AGNOSTER_DIR_FG" "$path_in_repo"
  fi
}

# bzr, hg (Disabled for performance)
prompt_bzr() { :; }
prompt_hg() { :; }

prompt_condaenv() {
  if [[ -n $CONDA_DEFAULT_ENV ]]; then
    prompt_segment 030 015 "$CONDA_DEFAULT_ENV"
  fi
}

prompt_virtualenv() {
  if [[ -n "$VIRTUAL_ENV" && -n "$VIRTUAL_ENV_DISABLE_PROMPT" ]]; then
    prompt_segment blue black "(${VIRTUAL_ENV:t:gs/%/%%})"
  fi
}

prompt_newline() {
  if [[ -n $CURRENT_BG ]]; then
    echo -n "%{%k%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR
%{%k%F{blue}%}$SEGMENT_SEPARATOR"
  else
    echo -n "%{%k%}"
  fi
  echo -n "%{%f%}"
  CURRENT_BG=''
}

prompt_status() {
  local -a symbols
  [[ $RETVAL -ne 0 ]] && symbols+="%{%F{$AGNOSTER_STATUS_RETVAL_FG}%}✘"
  [[ $(jobs -l | wc -l) -gt 0 ]] && symbols+="%{%F{$AGNOSTER_STATUS_JOB_FG}%}⚙"
  [[ -n "$symbols" ]] && prompt_segment "$AGNOSTER_STATUS_BG" "$AGNOSTER_STATUS_FG" "$symbols"
}

prompt_aws() {
  [[ -z "$AWS_PROFILE" || "$SHOW_AWS_PROMPT" = false ]] && return
  case "$AWS_PROFILE" in
    *-prod|*production*) prompt_segment "$AGNOSTER_AWS_PROD_BG" "$AGNOSTER_AWS_PROD_FG"  "AWS: ${AWS_PROFILE:gs/%/%%}" ;;
    *) prompt_segment "$AGNOSTER_AWS_BG" "$AGNOSTER_AWS_FG" "AWS: ${AWS_PROFILE:gs/%/%%}" ;;
  esac
}

## Main prompt
build_prompt() {
  RETVAL=$?
  prompt_status
  prompt_condaenv
  prompt_virtualenv
  prompt_aws
  prompt_terraform
  prompt_context

  # 최적화: Git Root 1회 계산 및 공유
  local repo_root
  repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || repo_root=""

  prompt_dir "$repo_root"
  prompt_git "$repo_root"

  prompt_newline
  prompt_end
}

PROMPT='%{%f%b%k%}$(build_prompt) '
