# 핵심 개념 사전

처음 보는 영어·통계·머신러닝 용어를 차시별 설명으로 다시 찾아가기 위한 누적 사전입니다. 링크는 해당 개념이 본문에서 설명되는 위치로 이어집니다.

| 용어 | 먼저 이렇게 이해하기 | 설명 위치 |
|---|---|---|
| 변수 | 관측 대상의 특징을 적어 둔 열 | [01. 데이터의 이해](modules/01-data-understanding/README.md#4-단위-변수-관측치) |
| 정량적 데이터 | 숫자 크기와 차이를 계산할 수 있는 데이터 | [01. 데이터의 이해](modules/01-data-understanding/README.md#3-정량적-데이터와-정성적-데이터) |
| 척도 | 값을 어떤 규칙과 수준으로 측정했는지 나타내는 기준 | [01. 데이터의 이해](modules/01-data-understanding/README.md#5-변수의-역할과-척도) |
| 시각화 | 숫자를 그래프나 그림으로 바꿔 보는 일 | [01. 데이터의 이해](modules/01-data-understanding/README.md#8-시각화는-변수-타입과-질문의-함수다) |
| 결측치 | 비어 있는 값 | [02. 데이터 정제](modules/02-data-cleaning/README.md#2-결측-메커니즘) |
| 선형 보간 | 앞뒤 값 사이를 직선으로 이어 빈 값을 채우는 방법 | [02. 데이터 정제](modules/02-data-cleaning/README.md#3-결측-처리-방법) |
| 이상치 | 전체 흐름에서 유난히 튀는 값 | [02. 데이터 정제](modules/02-data-cleaning/README.md#4-이상치의-의미) |
| LOF | 주변보다 밀도가 낮은 점을 이상치로 보는 방법 | [02. 데이터 정제](modules/02-data-cleaning/README.md#7-모델-기반-이상치-탐지) |
| Isolation Forest | 점을 빨리 혼자 떨어뜨리는 무작위 나무들을 이용한 이상치 탐지 | [02. 데이터 정제](modules/02-data-cleaning/README.md#7-모델-기반-이상치-탐지) |
| 정규화 | 값의 범위를 보통 0과 1 사이로 맞추는 변환 | [03. 데이터 변환](modules/03-data-transformation/README.md#2-정규화와-표준화) |
| 표준화 | 평균을 0, 표준편차를 1 기준으로 맞추는 변환 | [03. 데이터 변환](modules/03-data-transformation/README.md#2-정규화와-표준화) |
| 인코딩 | 범주나 문자를 모델이 읽을 수 있는 숫자 코드로 바꾸는 일 | [03. 데이터 변환](modules/03-data-transformation/README.md#3-인코딩) |
| 로그 변환 | 큰 값을 더 강하게 압축하는 변환 | [03. 데이터 변환](modules/03-data-transformation/README.md#5-로그-변환) |
| 구간화 | 연속적인 값을 여러 구간 상자에 나누는 변환 | [03. 데이터 변환](modules/03-data-transformation/README.md#7-구간화) |
| 모집단 | 알고 싶은 전체 대상 | [04. 통계와 확률](modules/04-statistics-probability/README.md#2-모집단과-표본) |
| 표본 | 전체 대신 관찰한 일부 대상 | [04. 통계와 확률](modules/04-statistics-probability/README.md#2-모집단과-표본) |
| 평균 | 모든 값을 더해 개수로 나눈 대표값 | [04. 통계와 확률](modules/04-statistics-probability/README.md#4-중심-경향) |
| 왜도 | 분포가 어느 한쪽으로 치우친 정도 | [04. 통계와 확률](modules/04-statistics-probability/README.md#6-분포의-모양) |
| 조건부 확률 | 어떤 일이 일어났다고 알고 난 뒤 다시 계산한 확률 | [04. 통계와 확률](modules/04-statistics-probability/README.md#9-조건부-확률) |
| 베이즈 정리 | 조건을 거꾸로 바꿔 계산하는 규칙 | [04. 통계와 확률](modules/04-statistics-probability/README.md#11-베이즈-정리) |
| 확률변수 | 우연한 결과를 숫자로 바꾼 변수 | [05. 확률 분포](modules/05-probability-distributions/README.md#1-확률변수와-분포) |
| 분포 | 값들이 어떤 모양으로 흩어져 있는지 나타내는 구조 | [05. 확률 분포](modules/05-probability-distributions/README.md#1-확률변수와-분포) |
| 확률분포 | 가능한 값과 그 값이 나올 가능성을 연결한 것 | [05. 확률 분포](modules/05-probability-distributions/README.md#1-확률변수와-분포) |
| 이산 분포 | 셀 수 있는 값마다 확률이 붙는 분포 | [05. 확률 분포](modules/05-probability-distributions/README.md#2-이산-분포와-연속-분포) |
| 연속 분포 | 구간 아래 면적으로 확률을 읽는 분포 | [05. 확률 분포](modules/05-probability-distributions/README.md#2-이산-분포와-연속-분포) |
| 중심극한정리 | 일정 조건에서 표본평균이 표본 수가 커질수록 정규분포에 가까워진다는 원리 | [05. 확률 분포](modules/05-probability-distributions/README.md#4-기대값-분산-중심극한정리) |
| p-value | 귀무가설 아래에서 지금 결과가 얼마나 드문지 | [06. 가설 검정](modules/06-hypothesis-testing/README.md#2-p-value와-유의수준) |
| 유의수준 | 얼마나 드문 결과부터 귀무가설을 버릴지 정한 기준 | [06. 가설 검정](modules/06-hypothesis-testing/README.md#2-p-value와-유의수준) |
| 검정통계량 | 표본 결과를 하나의 판단 숫자로 바꾼 값 | [06. 가설 검정](modules/06-hypothesis-testing/README.md#3-검정통계량과-기각역) |
| 기각역 | 귀무가설을 기각하는 통계량의 영역 | [06. 가설 검정](modules/06-hypothesis-testing/README.md#3-검정통계량과-기각역) |
| 양측검정 | 차이가 어느 방향이든 있는지 보는 검정 | [06. 가설 검정](modules/06-hypothesis-testing/README.md#4-단측검정과-양측검정) |
| 점 추정 | 모수를 하나의 숫자로 추정하는 방식 | [07. 점 추정과 구간 추정](modules/07-estimation/README.md#1-점-추정과-구간-추정) |
| 구간 추정 | 모수가 있을 만한 범위를 제시하는 방식 | [07. 점 추정과 구간 추정](modules/07-estimation/README.md#1-점-추정과-구간-추정) |
| 최대우도법 | 관측 데이터가 가장 그럴듯해지는 모수를 고르는 방법 | [07. 점 추정과 구간 추정](modules/07-estimation/README.md#3-적률법과-최대우도법) |
| 신뢰구간 | 표본의 흔들림을 반영해 모수가 있을 법한 범위를 제시하는 방법 | [07. 점 추정과 구간 추정](modules/07-estimation/README.md#4-대표-신뢰구간) |
| EM 알고리즘 | 숨은 값 추정과 모수 갱신을 번갈아 반복하는 알고리즘 | [08. 고급 추정법](modules/08-advanced-estimation/README.md#1-em-알고리즘) |
| 몬테카를로 | 무작위 샘플을 많이 뽑아 값을 추정하는 방법 | [08. 고급 추정법](modules/08-advanced-estimation/README.md#2-몬테카를로-방법) |
| MCMC | 마르코프 체인으로 원하는 분포의 샘플을 얻는 방법 | [08. 고급 추정법](modules/08-advanced-estimation/README.md#3-마르코프-체인과-mcmc) |
| Metropolis-Hastings | 후보를 제안하고 확률적으로 수락하며 원하는 분포를 탐색하는 MCMC 방법 | [08. 고급 추정법](modules/08-advanced-estimation/README.md#4-metropolis-hastings) |
| 선형회귀 | 입력과 출력의 평균적 관계를 직선식으로 설명하는 모델 | [09. 선형회귀 분석](modules/09-linear-regression/README.md#1-단순회귀와-다중회귀) |
| 잔차 | 실제값과 예측값의 차이 | [09. 선형회귀 분석](modules/09-linear-regression/README.md#2-주요-가정) |
| R2 | 종속변수 변동 중 모델이 설명한 비율 | [09. 선형회귀 분석](modules/09-linear-regression/README.md#3-모델-평가) |
| 다중공선성 | 독립변수끼리 너무 강하게 관련된 상태 | [09. 선형회귀 분석](modules/09-linear-regression/README.md#2-주요-가정) |
| 상관 분석 | 두 변수가 함께 움직이는 방향과 강도를 재는 분석 | [10. 연관성 분석](modules/10-association-analysis/README.md#2-상관-분석) |
| 분산분석 | 여러 집단 평균 차이를 변동 분해로 검정하는 방법 | [10. 연관성 분석](modules/10-association-analysis/README.md#3-분산분석) |
| 카이제곱 검정 | 관측빈도와 기대빈도의 차이를 보는 검정 | [10. 연관성 분석](modules/10-association-analysis/README.md#4-카이제곱-검정) |
| 교호작용 | 한 요인의 효과가 다른 요인의 수준에 따라 달라지는 현상 | [10. 연관성 분석](modules/10-association-analysis/README.md#3-분산분석) |
| 지도학습 | 정답 라벨이 있는 데이터로 예측 규칙을 배우는 학습 | [11. 머신 러닝](modules/11-machine-learning/README.md#1-학습-유형) |
| 비지도학습 | 정답 없이 데이터 구조를 찾는 학습 | [11. 머신 러닝](modules/11-machine-learning/README.md#1-학습-유형) |
| 성능 지표 | 모델 결과를 평가하는 숫자 | [11. 머신 러닝](modules/11-machine-learning/README.md#2-성능-지표) |
| 교차검증 | 데이터를 여러 번 나누어 검증하는 방식 | [11. 머신 러닝](modules/11-machine-learning/README.md#3-검증-방식) |
| 편향-분산 | 모델이 너무 단순한 오류와 너무 흔들리는 오류의 균형 | [11. 머신 러닝](modules/11-machine-learning/README.md#4-편향-분산) |
| 가중치 기반 모델 | 입력마다 중요도인 가중치를 곱해 출력을 만드는 모델 | [12. 모수적 모델](modules/12-parametric-models/README.md#1-가중치-기반-모델) |
| 경사하강법 | 손실이 줄어드는 방향으로 가중치를 조금씩 바꾸는 방법 | [12. 모수적 모델](modules/12-parametric-models/README.md#2-경사하강법과-학습률) |
| L1 규제 | 가중치 절댓값 합에 벌점을 주는 규제 | [12. 모수적 모델](modules/12-parametric-models/README.md#3-l1과-l2-규제) |
| L2 규제 | 가중치 제곱합에 벌점을 주는 규제 | [12. 모수적 모델](modules/12-parametric-models/README.md#3-l1과-l2-규제) |
| 나이브 베이즈 | 입력 변수 독립을 가정해 베이즈 정리로 분류하는 모델 | [12. 모수적 모델](modules/12-parametric-models/README.md#4-나이브-베이즈) |
| 의사결정나무 | 질문을 따라 가지를 내려가며 예측하는 트리 모델 | [13. 비모수적 모델](modules/13-nonparametric-models/README.md#1-의사결정나무-구조) |
| 분기 기준 | 데이터를 나눌 때 섞임이나 오차를 줄이는 질문을 고르는 기준 | [13. 비모수적 모델](modules/13-nonparametric-models/README.md#2-분기-기준) |
| 가지치기 | 너무 복잡한 트리를 줄이는 과정 | [13. 비모수적 모델](modules/13-nonparametric-models/README.md#3-가지치기와-과적합) |
| KNN | 가까운 k개 이웃의 정보를 이용하는 모델 | [13. 비모수적 모델](modules/13-nonparametric-models/README.md#4-knn) |
| 차원의 저주 | 차원이 늘수록 거리의 구분력이 약해지는 현상 | [13. 비모수적 모델](modules/13-nonparametric-models/README.md#4-knn) |
| 최대 마진 | 결정경계와 가장 가까운 점 사이 여백을 최대화하는 기준 | [14. SVM](modules/14-svm/README.md#1-최대-마진) |
| 서포트 벡터 | 마진을 결정하는 경계 가까운 데이터 | [14. SVM](modules/14-svm/README.md#2-서포트-벡터) |
| 슬랙 | SVM에서 일부 분류 위반을 허용하는 여유 변수 | [14. SVM](modules/14-svm/README.md#3-슬랙과-c) |
| 커널 | 두 데이터의 유사도를 계산하는 함수 | [14. SVM](modules/14-svm/README.md#4-커널) |
| 커널 트릭 | 고차원 변환 효과를 직접 좌표로 만들지 않고 계산하는 방법 | [14. SVM](modules/14-svm/README.md#4-커널) |
| 배깅 | 부트스트랩 표본으로 여러 모델을 독립적으로 학습해 합치는 방식 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#1-배깅) |
| 랜덤 포레스트 | 무작위성을 넣은 의사결정나무 여러 개의 앙상블 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#2-랜덤-포레스트) |
| 부스팅 | 이전 모델의 오류를 다음 모델이 보완하는 순차 앙상블 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#3-부스팅) |
| boosting | 이전 모델의 오류를 다음 모델이 보완하는 순차 앙상블의 영어 이름 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#3-부스팅) |
| AdaBoost | 틀린 데이터에 더 큰 가중치를 주며 보완하는 부스팅 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#3-부스팅) |
| Gradient Boosting | 이전 모델이 남긴 손실의 방향을 다음 모델이 보완하는 부스팅 | [15. 앙상블 모델](modules/15-ensemble-models/README.md#3-부스팅) |
| 거리 척도 | 두 데이터가 얼마나 다른지 재는 규칙 | [16. 군집화](modules/16-clustering/README.md#1-거리-척도) |
| k-means | k개 중심에 가장 가까운 점들을 묶는 군집화 | [16. 군집화](modules/16-clustering/README.md#2-k-means와-k-medoids) |
| GMM | 각 군집을 가우시안 분포로 보는 확률적 군집화 | [16. 군집화](modules/16-clustering/README.md#3-gmm) |
| DBSCAN | 밀도가 높은 지역을 군집으로 찾는 방법 | [16. 군집화](modules/16-clustering/README.md#4-계층적-군집화와-dbscan) |
| 팔꿈치 방법 | 군집 수를 늘릴 때 개선폭이 꺾이는 지점을 참고하는 방법 | [16. 군집화](modules/16-clustering/README.md#2-k-means와-k-medoids) |
| PCA | 분산을 가장 많이 보존하는 새 축을 찾는 방법 | [17. 차원 축소](modules/17-dimensionality-reduction/README.md#1-pca) |
| SVD | 행렬을 중요한 구조로 분해하는 방법 | [17. 차원 축소](modules/17-dimensionality-reduction/README.md#2-svd) |
| t-SNE | 가까운 이웃 구조를 시각화하는 비선형 차원 축소 | [17. 차원 축소](modules/17-dimensionality-reduction/README.md#3-mds와-t-sne) |
| LDA | 클래스 구분이 잘 되는 축을 찾는 지도 차원 축소 | [17. 차원 축소](modules/17-dimensionality-reduction/README.md#4-lda와-pls) |
| PLS | 입력과 출력의 공분산을 잘 설명하는 성분을 찾는 방법 | [17. 차원 축소](modules/17-dimensionality-reduction/README.md#4-lda와-pls) |
| 하이퍼파라미터 | 모델이 학습하기 전에 사람이 정하는 설정 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#1-하이퍼파라미터-탐색) |
| 그리드 서치 | 후보 조합을 격자처럼 모두 탐색하는 방법 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#1-하이퍼파라미터-탐색) |
| 속성 선택 | 모델에 사용할 변수를 고르는 과정 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#2-속성-선택) |
| 클래스 불균형 | 어떤 클래스의 표본 수가 다른 클래스보다 매우 적은 상태 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#3-클래스-불균형-지표) |
| SMOTE | 소수 클래스의 합성 표본을 만드는 오버샘플링 방법 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#4-샘플링과-가중치) |
| ADASYN | 분류가 어려운 소수 클래스 주변에 합성 표본을 더 만드는 방법 | [18. 일반화 기법](modules/18-generalization-techniques/README.md#4-샘플링과-가중치) |
| 퍼셉트론 | 입력에 가중치를 곱해 판단하는 기본 신경망 단위 | [19. 퍼셉트론](modules/19-perceptron/README.md#1-단층-퍼셉트론) |
| 다층 퍼셉트론 | 입력층과 출력층 사이에 은닉층을 둔 신경망 | [19. 퍼셉트론](modules/19-perceptron/README.md#2-다층-퍼셉트론) |
| 활성화 함수 | 출력 신호를 비선형으로 바꾸는 함수 | [19. 퍼셉트론](modules/19-perceptron/README.md#3-활성화-함수) |
| 역전파 | 손실의 기울기를 뒤에서 앞으로 전달하는 과정 | [19. 퍼셉트론](modules/19-perceptron/README.md#4-역전파와-기울기-소실) |
| 기울기 소실 | 앞쪽 층으로 갈수록 학습 신호가 약해지는 현상 | [19. 퍼셉트론](modules/19-perceptron/README.md#4-역전파와-기울기-소실) |
| Dense | 이전 층의 모든 입력이 현재 층의 모든 뉴런과 연결되는 층 | [20. 신경망의 구성](modules/20-neural-network-architecture/README.md#1-dense와-embedding) |
| Embedding | 범주를 연속 벡터로 바꾸는 층 | [20. 신경망의 구성](modules/20-neural-network-architecture/README.md#1-dense와-embedding) |
| CNN | 필터로 지역 패턴을 찾는 합성곱 신경망 | [20. 신경망의 구성](modules/20-neural-network-architecture/README.md#2-cnn) |
| RNN | 이전 상태를 다음 계산에 사용하는 순환 신경망 | [20. 신경망의 구성](modules/20-neural-network-architecture/README.md#3-rnn-lstm-gru) |
| Dropout | 학습 중 일부 뉴런을 무작위로 제외하는 기법 | [20. 신경망의 구성](modules/20-neural-network-architecture/README.md#4-보조-레이어) |
| 배치 방식 | 전체 데이터, 한 표본, 작은 묶음 중 무엇으로 업데이트할지 정하는 방식 | [21. 경사 하강법 심화](modules/21-gradient-descent-advanced/README.md#1-배치-방식) |
| Momentum | 이전 이동 방향을 일부 유지하는 관성 기법 | [21. 경사 하강법 심화](modules/21-gradient-descent-advanced/README.md#2-momentum과-nag) |
| NAG | 미리 이동해 볼 위치에서 기울기를 보는 모멘텀 개선법 | [21. 경사 하강법 심화](modules/21-gradient-descent-advanced/README.md#2-momentum과-nag) |
| Adagrad | 파라미터별 누적 기울기에 따라 학습률을 조정하는 방법 | [21. 경사 하강법 심화](modules/21-gradient-descent-advanced/README.md#3-adagrad-rmsprop-adadelta) |
| Adam | 모멘텀과 적응형 학습률을 결합한 최적화 방법 | [21. 경사 하강법 심화](modules/21-gradient-descent-advanced/README.md#4-adam) |
| CNN 구조 | 합성곱 층을 깊게 쌓아 이미지 특징을 단계적으로 배우는 구조 | [22. 심층 신경망](modules/22-deep-neural-networks/README.md#1-대표-cnn-구조) |
| Batch Normalization | 층 입력 분포를 안정화하는 기법 | [22. 심층 신경망](modules/22-deep-neural-networks/README.md#2-batch-normalization) |
| Word2Vec | 단어의 주변 문맥을 이용해 단어를 벡터로 학습하는 방법 | [22. 심층 신경망](modules/22-deep-neural-networks/README.md#3-word2vec과-표현-학습) |
| 전이학습 | 큰 데이터에서 배운 표현을 새 문제에 가져와 활용하는 방법 | [22. 심층 신경망](modules/22-deep-neural-networks/README.md#4-사전학습과-전이학습) |
| ResNet | 잔차 연결로 매우 깊은 네트워크 학습을 돕는 구조 | [22. 심층 신경망](modules/22-deep-neural-networks/README.md#1-대표-cnn-구조) |
