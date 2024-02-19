"Syntax Highligthing
if has ("syntax")
    syntax on
endif
set hlsearch     "검색할 때 매칭되는 문자열을 하이라이트

set autoindent
set cindent      "C언어 자동 들여쓰기
set nu

set tabstop=4     "또는 set ts=4 (tab 너비)
set sts=4         "tab 키를 눌렀을 때의 너비
"set expandtab     "tab안에 space 채우기
set shiftwidth=4  "자동 들여쓰기(auto indent)할 때의 너비
set showmatch     "짝이 되는 괄호를 하이라이트

set smartcase     "no automatic ignore case switch
set smarttab      "ts, sts, sw 값을 참조하여, 탭과 백스페이스의 동작을 보조
set smartindent   "줄바꿈 시, 이전 문장의 indent에서 새로 시작
set wmnu           " tab 자동완성시 가능한 목록을 보여줌

"가장 최근에 수정한 곳에 커서 위치
au BufReadPost *
\ if line("'\"") > 0 && line("'\"") <= line("$") |
\ exe "norm g`\"" |
\ endif

set title        "제목표
set laststatus=2 "상태바 상시 출력
set statusline=\ %<%l:%v\ [%P]%=%a\ %h%m%r\ %F\
set ruler        "현재 커서 위치의 줄번호와 행번호를 출력
set mouse=a      "마우스로 이동 가

set fileencodings=utf8,euc-kr
set fencs=ucs-bom,utf8,euc-kr  "파일읽기 시도순서

" 컬러스킴 사용
colorscheme jellybeans 
