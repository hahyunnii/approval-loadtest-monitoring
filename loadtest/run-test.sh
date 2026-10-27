#!/bin/bash
# 부하 테스트 실행 + 결과 리포트를 S3에 저장
#
#   사용법:  ./run-test.sh <이름>
#   예)      ./run-test.sh 1-no-index
#            MAX_VUS=400 ./run-test.sh 2-index-400vu    (가상 사용자 수를 바꿀 때)
set -uo pipefail
source /opt/loadtest/common.sh

LABEL="${1:?사용법: ./run-test.sh <이름>   예) ./run-test.sh 1-no-index}"
MAX_VUS="${MAX_VUS:-200}"
REPORT_DIR=/opt/loadtest/reports
REPORT="${REPORT_DIR}/${LABEL}.html"
SUMMARY="${REPORT_DIR}/${LABEL}-summary.json"

echo "════════════════════════════════════════"
echo " 테스트: ${LABEL}   (최대 가상 사용자 ${MAX_VUS}명, 약 9분 30초)"
echo " 시작:   $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S') (한국 시간)"
echo " 대상:   ${BASE_URL}"
echo " 실시간 그래프: 터미널 출력이 아니라 브라우저에서 k6 웹 대시보드를 여세요"
echo "════════════════════════════════════════"

K6_NO_USAGE_REPORT=true \
K6_WEB_DASHBOARD=true \
K6_WEB_DASHBOARD_HOST=0.0.0.0 \
K6_WEB_DASHBOARD_PORT=5665 \
K6_WEB_DASHBOARD_EXPORT="${REPORT}" \
BASE_URL="${BASE_URL}" MAX_VUS="${MAX_VUS}" THINK="${THINK:-0.2}" \
  /usr/local/bin/k6 run --summary-export "${SUMMARY}" /opt/loadtest/script.js
status=$?

echo
echo " 종료:   $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S') (한국 시간)"
if [ $status -eq 99 ]; then
  echo " 결과:   SLO 미달 (p99 0.5초 이상이거나 실패 1% 이상) — 위 표의 ✗ 표시 확인"
elif [ $status -eq 0 ]; then
  echo " 결과:   SLO 달성 ✓"
fi
echo
python3 /opt/loadtest/report.py split "${SUMMARY}"

aws s3 cp "${REPORT}"  "s3://${BUCKET}/reports/" --only-show-errors
aws s3 cp "${SUMMARY}" "s3://${BUCKET}/reports/" --only-show-errors
URL=$(aws s3 presign "s3://${BUCKET}/reports/${LABEL}.html" --expires-in 21600)
echo
echo " 리포트(그래프 포함 HTML, 약 6시간 동안 열림):"
echo " ${URL}"
echo
echo " 다음 테스트 전에 2~3분 쉬어주세요 (CloudWatch 그래프에서 테스트끼리 구분되도록)"
