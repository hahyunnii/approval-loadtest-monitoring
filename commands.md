# Commands — 실제 실행한 명령과 주요 출력

2026-10-27 (KST), 리전 `ap-northeast-2`. 실행 위치를 각 단계에 표시했습니다.
- **PC**: Windows PowerShell
- **부하 발생기**: AWS 콘솔 → EC2 → 연결 → Session Manager (브라우저 터미널)

계정 번호, 버킷 이름 접미사, 서명 URL 등은 `<...>`로 가렸습니다.

---

## 0. 준비 (PC)

```powershell
winget install -e --id Hashicorp.Terraform
winget install -e --id Amazon.AWSCLI
terraform version      # Terraform v1.16.6
aws --version          # aws-cli/2.38.6
docker version         # Docker Desktop 4.33.1, Server 부분 출력 확인
```

IAM 사용자 `terraform-lab`(AdministratorAccess)에 CLI용 액세스 키를 만들어 연결했습니다.

```powershell
aws configure          # 리전 ap-northeast-2, 출력 json
aws sts get-caller-identity
```
```json
{ "Arn": "arn:aws:iam::<account>:user/terraform-lab" }
```

> 실습이 끝난 뒤 액세스 키는 비활성화 → 삭제합니다. 키는 어디에도 붙여넣거나 커밋하지 않습니다.

## 1. 앱 빌드 (PC)

```powershell
cd app
docker run --rm -v "${PWD}:/src" -w /src maven:3.9.9-eclipse-temurin-21 mvn -q -B package -DskipTests
dir target\approval-app.jar
```
```
approval-app.jar   23,465,330 bytes
```

## 2. 인프라 생성 (PC)

```powershell
cd ..\infra
Copy-Item terraform.tfvars.example terraform.tfvars
Invoke-RestMethod https://checkip.amazonaws.com      # 내 공인 IP → tfvars의 my_ip
notepad terraform.tfvars                               # my_ip, alarm_email 입력
terraform init
terraform apply
```
```
Apply complete! Resources: 54 added, 0 changed, 0 destroyed.

Outputs:
alb_url              = "http://approval-alb-<suffix>.ap-northeast-2.elb.amazonaws.com/health"
cloudwatch_dashboard = "https://ap-northeast-2.console.aws.amazon.com/cloudwatch/...#dashboards/dashboard/approval-loadtest"
cloudwatch_alarms    = "...#alarmsV2:?search=approval-loadtest"
k6_web_dashboard     = "http://<loadgen-public-ip>:5665"
loadgen_connect      = "...#ConnectToInstance:instanceId=<loadgen-id>"
download_reports     = "aws s3 sync s3://approval-loadtest-<suffix>/reports ./reports"
```

`alb_url`을 브라우저로 열어 `ok` 응답을 확인했습니다.

**해석:** 처음에 `Invoke-RestMethod ifconfig.me`(HTTP)를 썼더니 통신사가 끼워 넣은 안내 페이지 HTML이 돌아왔습니다. HTTPS 주소(`checkip.amazonaws.com`)로 바꿔 해결했습니다.

## 3. 데이터 넣기와 실행 계획 (부하 발생기)

```bash
cd /opt/loadtest
ls                    # READY 파일 확인
./seed.sh
```
```
▶ 2/3 결재 문서 100만 건 넣기 (직원 1만 명, 최근 3년치)
  걸린 시간: 6초
| total_docs | employees |
|    1000000 |     10000 |
완료. 지금은 기본 키(PRIMARY) 인덱스만 있습니다.
```

```bash
./explain.sh
```
```
| id | select_type | table         | type | possible_keys | key  | rows   | filtered | Extra                       |
|  1 | SIMPLE      | approval_docs | ALL  | NULL          | NULL | 995826 |    10.00 | Using where; Using filesort |
▶ 실제 실행 시간 (한 번 실행)
  404ms
```

**해석:** `type=ALL`, `key=NULL`, `rows≈100만` → 결재함을 열 때마다 100만 건을 전부 읽고(`ALL`), 다시 날짜순으로 정렬(`filesort`)합니다. 아무도 없을 때도 한 번에 0.4초로, 목표(p99 0.5초)에 거의 닿아 있습니다.

## 4. 1차 테스트: 인덱스 없음 (부하 발생기)

```bash
./run-test.sh 1-no-index
```
```
✗ { name:inbox }...............: avg=10.34s  med=10s     p(90)=13.57s p(95)=13.73s max=14.55s
✗ http_req_failed................: 68.69% ✓ 3605  ✗ 1643
  http_reqs......................: 5248   9.071166/s
ERRO thresholds on metrics 'http_req_duration{name:inbox}, http_req_failed' have been crossed
 결과:   SLO 미달
 서버별 처리 건수: app-1 5,248건 100.0%
```

**해석**
- k6 그래프: 가상 사용자는 50 → 200명으로 늘었지만 처리량은 **약 18건/초에서 평평** → 최대 처리량
- CloudWatch: ⑦ RDS CPU **100%**, ⑤ 앱 CPU 약 5%, ⑧ RDS 연결 수 10(풀 최대치)에 고정 → **DB 병목**
- 실패한 요청의 중간값이 정확히 10초 → HikariCP `connection-timeout: 10000`. 연결 10개가 느린 쿼리에 묶여 뒤 요청이 10초 대기 후 500 에러
- 알람: P1-5xx, P2-p99-slo, P3-rds-cpu **빨강**, P1-unhealthy-host **초록** → 헬스체크(`/health`)는 DB를 거치지 않아 "서버 정상"으로 보임
- ⑨ 부하 발생기 CPU 약 2~3% → 측정 도구는 병목이 아님

## 5. 조치: 인덱스 생성 (부하 발생기)

```bash
./create-index.sh
```
```
  걸린 시간: 6초
| Key_name             | Seq_in_index | Column_name | Cardinality |
| idx_approver_created |            1 | approver_id |        9979 |
| idx_approver_created |            2 | created_at  |      995912 |
| type | key                  | ref   | rows | filtered | Extra               |
| ref  | idx_approver_created | const |  113 |   100.00 | Backward index scan |
▶ 실제 실행 시간: 10ms
```

**해석:** `(approver_id, created_at)` 복합 인덱스로 내 문서 113건만 읽고, 이미 날짜순이라 정렬도 없어졌습니다(`Backward index scan`). 단건 404ms → 10ms.

## 6. 2차 테스트: 인덱스 적용 (부하 발생기)

알람이 모두 OK로 돌아온 뒤 실행했습니다.

```bash
./run-test.sh 2-index
```
```
✓ { name:inbox }...............: avg=4.29ms  med=3.47ms  p(90)=4.68ms p(95)=5.99ms max=311.62ms
✓ http_req_failed................: 0.00%  ✓ 0  ✗ 262536
  http_reqs......................: 262536 460.423649/s
 결과:   SLO 달성 ✓
```

**해석:** 실패 0%, 처리량은 끝까지 오르기만 함(최고 약 950건/초). ⑤ 앱 CPU 약 25%, ⑦ RDS 약 22%, ⑨ k6 약 20% → **아무 칸도 한계에 닿지 않음 = 부하 부족**. 다음 병목을 찾으려고 부하를 4배로 올렸습니다.

## 7. 2b 테스트: 부하 4배 (부하 발생기)

```bash
MAX_VUS=800 ./run-test.sh 2b-index-800vu
```
```
running (09m30.1s), 000/800 VUs, 1014634 complete and 0 interrupted iterations
default ✓ [======================================] 000/800 VUs  9m30s
(이후 터미널 요약이 출력되지 않고 멈춤 → Ctrl+C)
```

HTML 리포트는 정상 생성되어 있어 직접 올렸습니다.

```bash
ls -la /opt/loadtest/reports/          # 2b-index-800vu.html 생성 확인 (summary.json은 없음)
free -m                                 # available 3343MB → 메모리 부족 아님
source /opt/loadtest/common.sh
aws s3 cp /opt/loadtest/reports/2b-index-800vu.html "s3://${BUCKET}/reports/"
```

k6 HTML 리포트 Summary:
```
http_req_duration  avg=11ms  med=3ms  p90=19ms  p95=49ms  p99=160ms  max=1s
http_req_failed    0/s
http_reqs          1m   1.78k/s
```

**해석:** 최고 약 3,600건/초. ⑤ 앱 CPU 약 **75%**(가장 높음), ⑦ RDS 약 65%, ⑨ k6 약 55%. 아직 100%는 없지만 p99가 가끔 200~800ms로 튀기 시작 → 한계에 다가가는 신호. 앱 서버가 가장 먼저 한계에 가까움.

## 8. 서버 3대로 수평 확장 (PC → 부하 발생기)

```powershell
notepad terraform.tfvars       # app_count = 3
terraform apply
```
```
Apply complete! Resources: 4 added, 3 changed, 0 destroyed.
app_instance_ids = ["i-...", "i-...", "i-..."]
```

```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```
```
| i-...c063c |  unhealthy  |      ← 새 서버: Java 설치·기동 중
| i-...6fea4 |  healthy    |
| i-...179da6|  unhealthy  |
(약 2분 뒤)
| healthy | healthy | healthy |
```

**해석:** 새 서버가 뜨는 동안 헬스체크에 실패해 **P1-unhealthy-host 알람이 울림(헛알람)**. 실무에서는 Auto Scaling의 health check grace period로 기동 중인 서버를 판정에서 제외합니다.

## 9. 3차 테스트: 서버 3대, 800명 (부하 발생기)

```bash
MAX_VUS=800 ./run-test.sh 3-scale-out
```
```
running (09m30.1s), 000/800 VUs, 1022608 complete and 0 interrupted iterations
(2b와 같은 지점에서 멈춤 → Ctrl+C → HTML 수동 업로드)
```

k6 HTML 리포트 Summary:
```
http_req_duration  avg=10ms  med=3ms  p90=17ms  p95=44ms  p99=130ms  max=1s
http_req_failed    0/s
http_reqs          1m   1.79k/s
```

**해석:** 같은 800명 부하에서 서버 1대(2b) 대비 p95 49 → 44ms, p99 160 → 130ms로 소폭 개선. app-1의 CPU는 약 75% → 약 30%. ⑦ RDS CPU는 약 65%로 그대로, ⑧ RDS 연결 수는 10 → 30(서버 3대 × 풀 10).

## 10. 장애 테스트 (부하 발생기)

알람이 모두 OK인 것을 확인한 뒤 실행했습니다.

```bash
./fail-test.sh 4-failover
```
```
 정상 서버 3대 중 approval-app-2 을(를) 멈춥니다
▶ 정상 상태로 60초 부하를 줍니다...
▶ approval-app-2 의 앱을 멈춥니다 (systemctl stop)
  ALB 판정: unhealthy  → 멈추고 13초 뒤에 알아챘습니다
  🔔 알람: approval-loadtest-P1-5xx
  🔔 알람: approval-loadtest-P1-unhealthy-host
▶ 앱을 다시 켭니다 (systemctl start)
  다시 정상 판정: 켜고 21초 뒤 (Java가 뜨는 시간 포함)

 ── 장애 테스트 결과 ──────────────────────
   전체 요청:            105,798건
   실패한 요청:          1,353건 (1.279%)
   ALB가 알아챈 시간:    서버를 멈추고 13.4초 뒤 (요청 보내기 중단)
   사람에게 알람:        서버를 멈추고 147.8초 뒤 (P1-5xx)
   사람에게 알람:        서버를 멈추고 153.4초 뒤 (P1-unhealthy-host)
   실패가 난 구간:       멈춘 뒤 0.0초 ~ 14.6초
   복구(다시 정상 판정): 서버를 켜고 21.4초 뒤

   5초 단위 실패 건수 (0초 = 서버를 멈춘 순간)
      0~5   초    495건
      5~10  초    485건
     10~15  초    373건 ← ALB가 알아챔

 서버별 처리 건수
   app-1        44,583건  42.1%
   app-2        15,280건  14.4%
   app-3        44,582건  42.1%
   none(실패)    1,353건   1.3%
```

**해석**
- 헬스체크 설정(10초 간격, 2회 연속 실패)의 이론 탐지 시간 10~20초 안에 들어옴 (13.4초)
- 탐지 전까지는 요청의 약 1/3(죽은 서버 몫)이 실패, 탐지 후 실패 0
- 처리량은 약 294건/초로 유지 → 남은 2대가 부하를 나눠 받음
- 알람은 1분 단위 지표로 판단해 약 2분 30초 뒤에 울림
- 14초 장애만으로 6분 구간의 실패율이 1.28% → 목표(1% 미만) 초과

## 11. 결과 받기와 정리 (PC)

```powershell
aws s3 sync s3://approval-loadtest-<suffix>/reports ./reports
```
```
download: ... 1-no-index.html, 2-index.html, 2b-index-800vu.html, 3-scale-out.html, 4-failover.html
download: ... *-summary.json, 4-failover-result.json, 4-failover-events.json, 4-failover-alarms.log, 4-failover-raw.csv.gz
```

```powershell
terraform destroy
```
```
No changes. No objects need to be destroyed.     ← infra 폴더가 아닌 곳에서 실행한 실수
Destroy complete! Resources: 0 destroyed.
```
```powershell
cd infra
terraform destroy
```
```
Destroy complete! Resources: 58 destroyed.
```

**해석:** Terraform은 실행한 폴더의 `terraform.tfstate`를 기준으로 동작합니다. 다른 폴더에서는 "지울 것 없음"으로 끝나므로, **0이 아닌 개수가 삭제됐는지 반드시 확인**해야 합니다.

## 겪은 문제와 해결

| 문제 | 원인 | 해결 |
|---|---|---|
| `aws`, `terraform` 명령을 찾을 수 없음 | 미설치 | `winget`으로 설치 후 PowerShell 재시작 |
| `aws sts get-caller-identity`: NoCredentials | 계정 연결 전 | IAM 사용자 액세스 키로 `aws configure` |
| 내 IP 확인 결과가 HTML | HTTP 요청에 통신사 안내 페이지가 끼어듦 | `https://checkip.amazonaws.com` 사용 |
| k6 실시간 대시보드가 새로고침 후 사라짐 | 테스트 실행 중에만 열림 | 자동 저장된 HTML 리포트를 S3 서명 URL로 열람 |
| 800명 테스트 종료 후 k6가 요약 출력에서 멈춤 | 원인 미확인 (메모리 부족·OOM 아님, HTML 리포트는 정상 생성) | Ctrl+C 후 HTML 수동 업로드, 서버별 비율은 CloudWatch로 확인 |
| 서버 증설 직후 P1-unhealthy-host 알람 | 기동 중인 서버를 비정상으로 판정 | 실무 개선안: health check grace period |
| CloudWatch ⑤⑥에 app-1 한 줄만 보임 | 서버를 늘린 apply에서 대시보드도 3대분으로 바뀌었지만, 열려 있던 화면이 이전 정의를 보여준 것으로 추정 (확인 못 함) | 다음에는 apply 후 대시보드를 새로 열기. 이번에는 app-1 한 대의 CPU 변화(75% → 30%)로 비교 |
| `terraform destroy`가 0개 삭제 | `infra`가 아닌 폴더에서 실행 | `infra` 폴더에서 재실행 → 58개 삭제 |
