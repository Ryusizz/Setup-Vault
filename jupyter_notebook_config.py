# Configuration file for notebook.

c = get_config()  #noqa

# 1. IP 설정(819 line): 외부에서 접속 가능하도록 '0.0.0.0'으로 설정
c.ServerApp.ip = '0.0.0.0'

# 2. 작업 디렉토리(915 line): 위에서 생성한 디렉토리 경로 입력
c.ServerApp.notebook_dir = '/root'

# 3. 시작시 브라우저 실행 안함(923 line)
c.ServerApp.open_browser = False

# 4. 비밀번호 설정(927 line): 위에서 생성한 암호문 그대로 입력.
# current : 10
c.ServerApp.password = 'argon2:$argon2id$v=19$m=10240,t=10,p=8$dqV9E0rAwfQtRUEhoiiJmQ$FHiy5+tUa3GyhF5VnOI1AQ4PYRHLrG3yWDo4oha8Vv8'

# 5. 주피터 노트북 접속 시 비밀번호 사용(931 line)
c.ServerApp.password_required = True

# 6. 포트 설정(935 line)
c.NotebookApp.port = 8888
