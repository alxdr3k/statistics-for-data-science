# VS Code 학습 환경 (선택)

> JupyterLab 만으로 학습이 어렵지 않다면 이 단계는 건너뛰어도 됩니다.
> 다만 코드 자동완성·디버거·Markdown 미리보기를 한 곳에서 쓰고 싶다면 VS Code 가 편리합니다.

## 1. VS Code 설치

[Visual Studio Code](https://code.visualstudio.com/) 에서 본인 OS 용 설치 파일을 받아 설치합니다.

## 2. 저장소 폴더 열기

VS Code 메뉴에서 `File → Open Folder...` → `statistics-for-data-science` 폴더를 선택합니다.

## 3. 권장 확장(extension) 설치

폴더를 처음 여는 순간 우측 하단에 *권장 확장 설치* 안내가 뜹니다 (`.vscode/extensions.json` 참조). **Install All** 을 누르면 다음이 한 번에 설치됩니다.

| 확장 | 용도 |
|------|------|
| Python | Python 인터프리터 연동, 디버거 |
| Jupyter | `.ipynb` 편집 / 실행 |
| Ruff | 린트·포매팅 (저장 시 자동) |
| Jupyter Renderers | 그래프·표 렌더링 강화 |
| Markdown All in One | 챕터(.md) 미리보기·목차 |

## 4. 인터프리터 선택 (자동)

`.vscode/settings.json` 이 `${workspaceFolder}/.venv/bin/python` (Mac) 또는 `${workspaceFolder}\.venv\Scripts\python.exe` (Windows, VS Code 가 자동 매핑) 를 가리키도록 이미 설정되어 있습니다. 처음 `.ipynb` 를 열 때 우측 상단의 커널 선택에서 `.venv` 가 자동으로 잡히는지 확인하세요.

수동으로 잡아야 한다면:
- 명령 팔레트(`Cmd/Ctrl + Shift + P`) → `Python: Select Interpreter` → `Use ./.venv/bin/python` (또는 Windows 동등 경로) 선택.

## 5. 첫 노트북 열기

좌측 탐색기에서 `modules/00-orientation/03-check-env.ipynb` 를 더블클릭. 우측 상단 커널이 `.venv (Python 3.12.x)` 인지 확인 후 `Run All` (▶▶ 아이콘).

## 6. Markdown 챕터 보는 법

`.md` 파일을 연 상태에서 `Cmd/Ctrl + Shift + V` → 분할 화면 미리보기. 본문에 LaTeX 수식이 있으면 자동 렌더링됩니다.

## 7. 자주 막히는 지점

- **Jupyter 셀에서 `ModuleNotFoundError: numpy`**: 커널이 시스템 Python 을 가리킬 가능성이 높습니다. 우측 상단 커널을 `.venv` 로 다시 선택하세요.
- **Ruff 가 저장 시 동작하지 않음**: VS Code 우측 하단 언어 모드가 *Python* 인지 확인. Ruff 확장이 활성화되어 있는지 확장 탭에서 점검.
- **Markdown 수식이 깨짐**: GitHub 와 VS Code 의 LaTeX 렌더링 규칙이 살짝 달라, `$$ ... $$` 양 옆에 빈 줄이 있어야 둘 다 잘 보입니다.
