# Statistics for Data Science

데이터 과학에 필요한 통계학을 **"왜 필요한가, 어디서 쓰이는가"** 부터 납득하며 다지는 학습 저장소.

---

## 여기서 시작

처음 클론한 직후 다음 순서대로 따라가면 30~60 분 안에 첫 학습이 시작됩니다.

1. **환경 셋업**
   - macOS: [`SETUP/macos.md`](SETUP/macos.md)
   - Windows: [`SETUP/windows.md`](SETUP/windows.md)
   - (선택) VS Code 사용: [`SETUP/vscode.md`](SETUP/vscode.md)
2. **환경 검증**
   - JupyterLab 또는 VS Code 에서 [`modules/00-orientation/03-check-env.ipynb`](modules/00-orientation/03-check-env.ipynb) 의 모든 셀이 에러 없이 실행되는지 확인.
3. **학습 방법 익히기**
   - [`modules/00-orientation/01-how-to-learn.md`](modules/00-orientation/01-how-to-learn.md) — 이 저장소를 어떻게 읽고, 어떻게 회고할지.
   - [`modules/00-orientation/02-tools-tour.ipynb`](modules/00-orientation/02-tools-tour.ipynb) — Pandas·NumPy·시각화 30 분 투어.
4. **첫 챕터 시작**
   - [`modules/01-descriptive-stats/01-when-mean-lies.md`](modules/01-descriptive-stats/01-when-mean-lies.md) — *평균이 거짓말할 때*.
   - 짝이 되는 노트북: [`modules/01-descriptive-stats/01-when-mean-lies.ipynb`](modules/01-descriptive-stats/01-when-mean-lies.ipynb).
5. **회고**
   - 매 챕터 끝의 `reflection.md` 의 회고 질문 3 개를 *내 말로* 답해 본다.

---

## 학습 철학

각 챕터는 같은 7-블록 구조로 작성됩니다.

> 시나리오 → 위험(Why) → 도메인 사례(Where) → 직관 → 정의·수식 → 실습 → 함정 → 다음 질문

자세한 원칙은 [`PEDAGOGY.md`](PEDAGOGY.md). 전체 모듈 맵과 진도 체크리스트는 [`CURRICULUM.md`](CURRICULUM.md).

학습 페이스 가이드:

| 호흡 | 목표 |
|------|------|
| 챕터 1 회 | 60~90 분. 본문 + 노트북 + 회고. |
| 모듈 1 회 | 4~8 챕터, 1~3 주. |
| 한 트랙 | 4~6 모듈, 2~3 개월. |

회고가 짧게라도 적혀 있지 않으면 다음 챕터로 넘어가지 않는 것을 원칙으로 합니다.

---

## 저장소 구조

```
statistics-for-data-science/
├── README.md            ← 지금 보고 있는 파일
├── PEDAGOGY.md          학습 철학 / 7-블록 구조 / 작성 원칙
├── CURRICULUM.md        전체 모듈 맵 / 진도 체크리스트
├── SETUP/               OS 별 환경 셋업 가이드
├── modules/             학습 콘텐츠 (모듈 → 챕터)
│   ├── 00-orientation/
│   ├── 01-descriptive-stats/
│   └── ...
├── datasets/            데이터셋 카탈로그 (출처·라이선스 포함)
├── notebooks_template.ipynb   새 챕터 노트북 시작 템플릿
├── pyproject.toml       의존성 매니페스트
├── uv.lock              재현 가능한 lockfile
└── .python-version      3.12
```

---

## 도구

- **Python 3.12** — `uv` 가 자동으로 받아 옵니다.
- **uv** — Python 버전·가상환경·의존성을 한 번에 관리하는 도구.
- **JupyterLab** 또는 **VS Code + Jupyter 확장** — 노트북 실행 환경.
- 라이브러리: `numpy`, `pandas`, `scipy`, `statsmodels`, `matplotlib`, `seaborn`, `scikit-learn`.

추가 라이브러리 (예: `pymc`)는 해당 모듈에 도달하는 시점에 의존성에 추가됩니다.

---

## 콘텐츠 작성 (저장소 기여자용)

새 챕터 작성 워크플로우는 [`PEDAGOGY.md`](PEDAGOGY.md) 의 *체크리스트* 와 [`CURRICULUM.md`](CURRICULUM.md) 의 *콘텐츠 추가 워크플로우* 를 참고하세요. 핵심:

- `feat/<topic>` 브랜치에서 작업 → `main` 으로 squash merge (PR 필수).
- `notebooks_template.ipynb` 를 복사해서 노트북 시작.
- 7-블록 구조와 회고 질문 3 개를 빠뜨리지 않을 것.

---

## 라이선스

본 저장소의 코드·문서는 [MIT 라이선스](LICENSE).
사용 데이터셋은 각각의 출처 라이선스를 따르며 [`datasets/README.md`](datasets/README.md) 에 정리되어 있습니다.
