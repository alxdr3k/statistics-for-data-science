# Data Science Lv3 — 기초부터 읽는 학습자료

PDF 강의자료의 22차시 구성을 따라가되, **데이터 사이언스를 처음 공부하는 학습자**도 읽을 수 있도록 다시 쓰는 저장소입니다.

이 자료의 기준은 “많이 아는 사람에게 압축해서 설명하기”가 아닙니다. 처음 보는 용어를 하나씩 풀고, 쉬운 예시로 이해한 뒤, PDF의 개념 이름과 연결하는 방식으로 작성합니다.

현재 실제 학습자료 본문은 **2일차(2차시 데이터 정제)** 까지 작성했습니다. 나머지 차시는 커리큘럼 설계만 잡아 두었습니다.

## 여기서 시작

1. 전체 흐름을 먼저 봅니다: [CURRICULUM.md](CURRICULUM.md)
2. 학습 방식과 작성 기준을 확인합니다: [PEDAGOGY.md](PEDAGOGY.md)
3. 작성된 학습자료로 들어갑니다: [modules/README.md](modules/README.md)
4. 현재 작성된 자료는 [1차시 데이터의 이해](modules/01-data-understanding/README.md)와 [2차시 데이터 정제](modules/02-data-cleaning/README.md)입니다.

## 현재 구성

```text
statistics-for-data-science/
├── README.md
├── CURRICULUM.md
├── PEDAGOGY.md
├── modules/
│   ├── 00-orientation/
│   ├── 01-data-understanding/
│   ├── 02-data-cleaning/
│   └── README.md
├── archive/practical-first-v1/
│   └── modules/        # 이전 실습형 자료 보존본
├── SETUP/
├── datasets/
└── pyproject.toml
```

## 학습 원칙

- 새 용어는 **일상적인 말 → 쉬운 예시 → 정확한 용어** 순서로 설명합니다.
- 차트와 도식은 관련 설명 바로 옆에 둡니다.
- 실습은 보조입니다. 먼저 “이 말이 무슨 뜻인지” 이해하는 것이 우선입니다.
- 어려운 내용은 `심화`로 표시하고, 첫 학습 때는 건너뛰어도 되게 만듭니다.
- 확인 문제에는 해설을 붙여 혼자 공부할 수 있게 합니다.

## 권장 페이스

| 단위 | 목표 |
|---|---|
| 1차시 | 60~120분. 본문 정독, 그림 확인, 예시 풀이, 확인 문제 |
| 1블록 | 4~6차시. 낯선 용어를 자기 말로 바꾸는 데 집중 |
| 전체 | 22차시. 데이터 이해에서 머신러닝과 신경망까지 천천히 연결 |

## 도구

실습은 필수가 아니지만, 나중에 작은 예제를 확인할 수 있도록 다음 환경을 유지합니다.

- Python 3.12
- `numpy`, `pandas`, `scipy`, `statsmodels`
- `scikit-learn`
- `matplotlib`, `seaborn`
- JupyterLab 또는 VS Code Jupyter

## 이전 자료

이전 실습 중심 모듈은 삭제하지 않고 [archive/practical-first-v1/modules](archive/practical-first-v1/modules)에 보존했습니다. 현재 학습 진입점은 새 [modules](modules)입니다.
