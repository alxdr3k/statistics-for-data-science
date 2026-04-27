# 데이터셋 카탈로그

학습 시나리오는 두 도메인에 집중한다.

- **건강 / 의료 / 운동 / 영양** — 일상 의사결정과 직접 연결되어 동기부여가 강함.
- **콘텐츠 / 문화 (영화·음악·도서)** — 평점·시청 패턴 등 분포·집계 학습에 풍부한 데이터.

이 외 *교과서 토이 데이터셋* (Iris, Titanic) 은 의도적으로 1~2 회만 사용해 *그 한계* 를 보여 준다.

---

## 디렉토리 구조

```
datasets/
├── README.md       (이 파일)
├── health/         (건강 도메인 — 작은 표본·전처리 결과)
├── content/        (콘텐츠 도메인)
├── classic/        (교과서 토이셋)
└── raw/            (대용량 원본 다운로드 — git 추적 안 됨, .gitignore 처리)
```

`raw/` 는 `.gitignore` 로 제외되며, 각 챕터 노트북에서 다운로드 스크립트 또는 외부 라이브러리 호출로 채운다.

---

## 카탈로그

| ID | 도메인 | 출처 | 라이선스 | 사용 모듈 | 비고 |
|----|--------|------|----------|----------|------|
| `health/sleep_synth.csv` | 건강 | 학습용 합성 데이터 | MIT (이 저장소) | 1 | 본 저장소에서 생성한 합성 수면 데이터. 분포의 비대칭성을 보여 주기 위해 한 모집단에 양극 분포를 섞었다. |
| `content/movielens_small` | 콘텐츠 | [GroupLens — MovieLens](https://grouplens.org/datasets/movielens/) | non-commercial research only | 1, 2, 7 | 다운로드 스크립트로 받음. 노트북에서 100k 또는 1M 버전을 사용. |
| `health/nhanes_subset` | 건강 | [CDC NHANES](https://www.cdc.gov/nchs/nhanes/) | 미국 공공 도메인 | 3, 4, 5 | 신장·체중·수면·혈압 등 대표 변수만 발췌. 원본은 `raw/` 에. |
| `content/spotify_audio_features` | 콘텐츠 | [Spotify Web API · Audio Features](https://developer.spotify.com/documentation/web-api/) | API 약관 (조회만) | 6, 7 | 사용자 토큰으로 직접 조회한 결과를 학습자 본인이 캐싱. |
| `health/fitness_logs_synth.csv` | 건강 | 학습용 합성 데이터 | MIT (이 저장소) | 6, 7 | 운동 강도·심박수·소모 칼로리 합성. |
| `content/goodreads_books` | 콘텐츠 | [Goodreads via UCSD Book Graph](https://mengtingwan.github.io/data/goodreads.html) | research-use license | 8 | 책별 평점 분포·태그. 노트북에서 다운로드. |
| `classic/iris.csv` | 교과서 | scikit-learn 내장 | BSD-3-Clause | 1 (한정 사용) | 교과서적 한계의 예시로만. |
| `classic/titanic.csv` | 교과서 | seaborn 내장 (`load_dataset`) | BSD-3-Clause | 8 (한정 사용) | 범주형 분석 예시로만. |

---

## 데이터 사용 원칙

1. **출처와 라이선스를 표 안에 명시.** 표에 없는 데이터셋은 *어떤 노트북에서도* 사용 금지.
2. **원본 대신 발췌·합성.** 큰 원본은 `raw/` 에 두고 git 추적하지 않음. 학습 시나리오에 필요한 작은 표는 `<도메인>/` 에 둔다.
3. **노트북은 항상 다운로드 가능 상태.** 학습자가 처음 실행해도 `raw/` 가 자동으로 채워지도록 셀에 download 코드를 넣는다.
4. **개인 식별 정보 금지.** 합성 데이터에도 실제 개인을 추정 가능한 어떤 표시도 넣지 않는다.

---

## 새 데이터셋 추가하는 법

1. 본문 시나리오에 *왜 이 데이터가 필요한지* 적는다.
2. 위 카탈로그에 한 줄 추가 (ID·출처·라이선스·사용 모듈).
3. 작은 발췌·합성 데이터는 `<도메인>/` 에 commit. 큰 원본은 `raw/` 에 두고 다운로드 코드만 commit.
4. PR 본문에 라이선스·재배포 가능 여부를 명시.
