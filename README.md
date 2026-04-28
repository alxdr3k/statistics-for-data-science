# Data Science Lv3 심화이론

PDF 강의자료의 22차시 구성을 바탕으로 다시 작성하는 **데이터 사이언스 심화 이론 학습 저장소**입니다. 기존 자료가 실습 중심이었다면, 현재 버전은 개념의 전제, 수식의 의미, 모델 선택 기준, 오해와 반례를 먼저 다룹니다.

현재 실제 학습자료 본문은 요청 범위에 맞춰 **2일차(2차시 데이터 정제)** 까지 작성했습니다. 나머지 차시는 커리큘럼 설계만 잡아 두었습니다.

## 여기서 시작

1. 전체 흐름을 먼저 봅니다: [CURRICULUM.md](CURRICULUM.md)
2. 학습 방식과 난이도 기준을 확인합니다: [PEDAGOGY.md](PEDAGOGY.md)
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

- 각 차시는 **정의 → 전제 → 수식 → 판단 기준 → 반례 → 확인 문제** 순서로 읽습니다.
- 코드 실습은 보조 자료입니다. 개념을 설명하지 못하면 실습 결과를 해석할 수 없다는 전제를 둡니다.
- 단순 암기보다 “이 방법을 쓰기 위한 조건은 무엇인가?”, “조건이 깨지면 어떤 오류가 생기는가?”를 우선합니다.
- PDF의 항목을 그대로 베끼지 않고, 강의용 이론 노트로 재구성했습니다.

## 권장 페이스

| 단위 | 목표 |
|---|---|
| 1차시 | 90~150분. 본문 정독, 수식 의미 확인, 확인 문제 풀이 |
| 1블록 | 4~6차시. 통계 기초, 추론, 머신러닝, 신경망처럼 큰 묶음으로 복습 |
| 전체 | 22차시. 통계 추론에서 심층 신경망까지 하나의 이론 흐름으로 연결 |

## 도구

실습은 필수가 아니지만, 수식 검산과 작은 예제 재현을 위해 다음 환경을 유지합니다.

- Python 3.12
- `numpy`, `pandas`, `scipy`, `statsmodels`
- `scikit-learn`
- `matplotlib`, `seaborn`
- JupyterLab 또는 VS Code Jupyter

## 이전 자료

이전 실습 중심 모듈은 삭제하지 않고 [archive/practical-first-v1/modules](archive/practical-first-v1/modules)에 보존했습니다. 현재 학습 진입점은 새 [modules](modules)입니다.
