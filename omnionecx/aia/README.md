# omnionecx — AIA생명 (aia)

- 사이트 코드: `aia`
- OACX 버전: `2.0.0.1`
- verifier 버전: `1.3.36_fix`

`omnionecx/1.0.0.12/`(default 버전 고정 이미지 트랙)와 동일한 구조를
따라갈 예정입니다. 구조만 미리 잡아둔 상태:

```
db/       -- Dockerfile + build-and-push.sh + initdb/ (이 사이트 전용 DDL/DML)
verifier/ -- Dockerfile + build-and-push.sh (verifier 1.3.36_fix 산출물 빌트인)
oacx/     -- Dockerfile + build-and-push.sh (OACX 2.0.0.1 산출물 빌트인)
deploy/   -- deploy.sh/.ps1, docker-compose.yml, exec.sh/.ps1
```

실제 산출물(JAR/WAR)과 이 사이트 전용 DDL/DML이 준비되면
`omnionecx/1.0.0.12/`의 파일들을 참고해 채워 넣습니다.
