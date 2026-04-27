# macOS 환경 셋업

> macOS에서 이 저장소의 학습 환경을 구성하는 단계별 가이드입니다.
> 어떤 줄도 막히면 우선 그대로 멈추고 메시지를 캡처해 두세요.

## 1. 사전 준비물

- macOS 12 Monterey 이상 권장.
- 터미널 앱은 기본 **Terminal.app** 또는 **iTerm2** 어느 쪽이든 무방합니다.
- 인터넷 연결.

## 2. Homebrew 설치 (이미 있다면 건너뛰기)

Homebrew 는 macOS 패키지 매니저입니다. 아래 명령을 터미널에 붙여 넣고 안내에 따릅니다.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

설치 끝에 표시되는 *Next steps* (보통 `eval "$(/opt/homebrew/bin/brew shellenv)"` 같은 줄을 `~/.zprofile` 에 추가)을 반드시 실행하세요.

확인:

```bash
brew --version
```

## 3. Git 설치 (없을 때만)

macOS 는 Xcode Command Line Tools 에 git 이 포함되어 있어 보통 이미 설치되어 있습니다.

```bash
git --version
```

명령이 동작하지 않으면:

```bash
xcode-select --install
```

## 4. uv 설치 (Python 도구)

`uv` 는 Python 버전 + 가상환경 + 의존성을 한 번에 관리합니다.

```bash
brew install uv
```

또는 (Homebrew 를 쓰지 않을 때):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

확인:

```bash
uv --version
```

## 5. 저장소 가져오기

원하는 작업 디렉토리에서:

```bash
git clone <이 저장소의 URL>
cd statistics-for-data-science
```

## 6. 환경 구성

`uv sync` 한 줄이면 됩니다. Python 3.12 가 없으면 자동으로 받아 옵니다.

```bash
uv sync
```

처음 실행하면 의존성 다운로드로 1~3 분 정도 걸릴 수 있습니다. 완료되면 `.venv/` 디렉토리가 생깁니다.

## 7. 환경 검증

JupyterLab 을 띄우고 검증 노트북을 실행합니다.

```bash
uv run jupyter lab
```

브라우저에 JupyterLab 이 열립니다. 좌측 파일 탐색기에서 `modules/00-orientation/03-check-env.ipynb` 를 열고 셀 전체를 실행하세요. 모든 셀이 에러 없이 끝나면 환경 구성이 끝난 것입니다.

JupyterLab 을 끄려면 터미널에서 `Ctrl + C` 두 번.

## 8. (선택) VS Code 사용

VS Code 사용을 선호한다면 `SETUP/vscode.md` 를 이어서 보세요.

## 9. 자주 막히는 지점

- **`uv: command not found`**: `~/.zshrc` 또는 `~/.zprofile` 의 PATH 반영을 위해 새 터미널 창을 엽니다.
- **`Permission denied`** 메시지: `sudo` 를 붙이지 마세요. Homebrew/uv 모두 사용자 권한으로 동작해야 합니다. 권한 문제는 보통 파일 위치(예: 시스템 디렉토리에 clone 시도)에서 발생합니다.
- **JupyterLab 이 열리지 않음**: 터미널에 표시된 `http://localhost:8888/...` 주소를 브라우저에 직접 붙여 넣습니다.
