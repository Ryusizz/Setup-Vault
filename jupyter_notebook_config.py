# Configuration file for notebook.

c = get_config()  # noqa

# 1. IP 설정(819 line): 외부에서 접속 가능하도록 '0.0.0.0'으로 설정
c.ServerApp.ip = "0.0.0.0"

# 2. 작업 디렉토리(915 line): 위에서 생성한 디렉토리 경로 입력
c.ServerApp.notebook_dir = "/root"

# 3. 시작시 브라우저 실행 안함(923 line)
c.ServerApp.open_browser = False

# 4. 비밀번호 설정(927 line)
# 암호 해시는 저장소에 커밋하지 않는다(공개 저장소). 로컬에서 생성해 환경변수로 주입:
#   python -c "from jupyter_server.auth import passwd; print(passwd())"
#   export JUPYTER_PASSWORD_HASH='argon2:...'
import os

_pw = os.environ.get("JUPYTER_PASSWORD_HASH", "")
if _pw:
    c.ServerApp.password = _pw

# 5. 주피터 노트북 접속 시 비밀번호 사용(931 line) — 해시가 있을 때만 강제
c.ServerApp.password_required = bool(_pw)

# 6. 포트 설정(935 line)
c.NotebookApp.port = 8888
