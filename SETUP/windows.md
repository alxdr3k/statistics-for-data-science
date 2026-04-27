# Windows 환경 셋업

> Windows 10/11 에서 이 저장소의 학습 환경을 구성하는 단계별 가이드입니다.
> 명령은 PowerShell (관리자 권한 필요 없음) 기준으로 작성됩니다.

## 1. 사전 준비물

- Windows 10 (1809 이상) 또는 Windows 11.
- PowerShell 5.1 이상 (Windows 11 은 기본 탑재).
- 인터넷 연결.

## 2. Git 설치

[Git for Windows 공식 다운로드](https://git-scm.com/download/win) 에서 설치 파일을 받아 설치합니다. 옵션은 모두 기본값을 그대로 두면 됩니다.

확인 (PowerShell 새 창에서):

```powershell
git --version
```

## 3. uv 설치

`uv` 는 Python 버전 + 가상환경 + 의존성을 한 번에 관리합니다. 관리자 권한 없이 사용자 영역에 설치됩니다.

PowerShell:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

설치 후 PowerShell 을 한 번 닫고 새로 엽니다 (PATH 반영을 위해).

확인:

```powershell
uv --version
```

> Tip: 회사 PC 에서 위 명령이 실행 정책으로 막히면 IT 정책 확인이 필요합니다.
> 대안으로 `winget install --id=astral-sh.uv -e` 를 시도할 수 있습니다.

## 4. 저장소 가져오기

원하는 작업 폴더에서:

```powershell
git clone <이 저장소의 URL>
cd statistics-for-data-science
```

## 5. 환경 구성

```powershell
uv sync
```

처음 실행하면 의존성 다운로드로 1~3 분 정도 걸립니다. 완료되면 `.venv\` 폴더가 생깁니다.

## 6. 환경 검증

JupyterLab 을 띄우고 검증 노트북을 실행합니다.

```powershell
uv run jupyter lab
```

브라우저에 JupyterLab 이 열립니다. 좌측에서 `modules/00-orientation/03-check-env.ipynb` 를 열고 모든 셀을 실행하세요. 에러 없이 통과하면 환경 구성이 끝난 것입니다.

JupyterLab 종료는 PowerShell 창에서 `Ctrl + C` 두 번.

## 7. (선택) VS Code 사용

VS Code 사용을 선호한다면 `SETUP/vscode.md` 를 이어서 보세요.

## 8. 자주 막히는 지점

- **`uv` 가 인식되지 않음**: PowerShell 창을 닫고 새로 엽니다. `$env:Path` 에 `%USERPROFILE%\.local\bin` 이 들어 있는지 확인.
- **`uv sync` 실행 시 SSL/CERT 에러**: 회사 네트워크에서 자체 인증서를 사용한다면 IT 팀에 인증서 경로를 받아 `SSL_CERT_FILE` 환경변수 설정이 필요할 수 있습니다.
- **`uv` 가 Python 다운로드 중 정지**: 사내 방화벽이 `python-build-standalone` 도메인을 막을 수 있습니다. 사내에 이미 Python 3.12 가 설치되어 있다면 `uv python pin 3.12` 후 시스템 Python 을 사용하도록 강제할 수 있습니다.
- **JupyterLab 이 자동으로 안 열림**: 터미널 출력의 `http://localhost:8888/...` URL 을 브라우저에 직접 붙여 넣습니다.
- **줄 끝(LF/CRLF) 경고**: `git config --global core.autocrlf input` 을 한 번 적용하면 노트북 diff 가 깨끗해집니다.
