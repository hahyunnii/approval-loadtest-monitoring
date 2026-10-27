#!/bin/bash
# 장애 테스트: 부하를 주는 중에 앱 서버 1대를 멈추고,
#   ① ALB가 몇 초 만에 알아채는지  ② 사람에게 알람(CloudWatch P1)이 몇 초 뒤에 가는지
#   ③ 그동안 사용자 요청이 몇 건 실패하는지  ④ 다시 켰을 때 복구 시간
# 을 잰다. (앱 서버가 2대 이상일 때만 의미가 있다)
#
#   사용법:  ./fail-test.sh <이름>
#   예)      ./fail-test.sh 4-failover
#            DOWN_SECONDS=240 VUS=80 ./fail-test.sh 4b-failover    (멈춰 둘 시간, 부하를 바꿀 때)
set -uo pipefail
source /opt/loadtest/common.sh

LABEL="${1:?사용법: ./fail-test.sh <이름>   예) ./fail-test.sh 4-failover}"
VUS="${VUS:-60}"                    # 일정하게 줄 부하 (가상 사용자 수)
WARMUP="${WARMUP:-60}"              # 서버를 멈추기 전 정상 상태로 부하를 주는 시간(초)
DOWN_SECONDS="${DOWN_SECONDS:-180}" # 서버를 멈춰 두는 시간(초). 1분 단위 지표로 판단하는 알람이 울릴 시간을 준다
DURATION="${DURATION:-6m}"          # 전체 부하 시간
ALARM_PREFIX="approval-loadtest-P1" # 긴급 알람 이름
REPORT_DIR=/opt/loadtest/reports
REPORT="${REPORT_DIR}/${LABEL}.html"
SUMMARY="${REPORT_DIR}/${LABEL}-summary.json"
CSV="${REPORT_DIR}/${LABEL}-raw.csv.gz"
EVENTS="${REPORT_DIR}/${LABEL}-events.json"
ALARMS_LOG="${REPORT_DIR}/${LABEL}-alarms.log"
RESULT="${REPORT_DIR}/${LABEL}-result.json"

now_ms() { date +%s%3N; }

# 대상 서버 목록과 상태 (ALB 헬스체크 기준)
health() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
}
state_of() { health | awk -v id="$1" '$1 == id { print $2 }'; }

# 앱 서버에 명령 보내기 (Session Manager). 앱 서버에서 명령을 "시작한" 시각(ms)을 출력한다
run_on() {
  local id="$1" cmd="$2" cid out
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "commands=[\"date +%s%3N\",\"${cmd}\"]" \
        --query Command.CommandId --output text) || return 1
  for _ in $(seq 1 30); do
    sleep 1
    out=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
          --query '[Status,StandardOutputContent]' --output text 2>/dev/null) || continue
    case "$out" in
      Success*) echo "$out" | grep -oE '[0-9]{13}' | head -1; return 0 ;;
      Failed*|Cancelled*|TimedOut*) echo "명령 실패: $out" >&2; return 1 ;;
    esac
  done
  echo "명령 결과를 30초 안에 못 받았습니다" >&2; return 1
}

# 긴급 알람이 ALARM 상태로 바뀌는 시각을 5초마다 기록한다 (뒤에서 계속 돈다)
alarms_in_alarm() {
  aws cloudwatch describe-alarms --alarm-name-prefix "$ALARM_PREFIX" --state-value ALARM \
    --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}
watch_alarms() {
  local deadline=$(( $(date +%s) + DOWN_SECONDS + 60 ))
  : > "$ALARMS_LOG"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    for name in $(alarms_in_alarm); do
      grep -q "^${name} " "$ALARMS_LOG" || { echo "${name} $(now_ms)" >> "$ALARMS_LOG"; echo "  🔔 알람: ${name}"; }
    done
    [ "$(wc -l < "$ALARMS_LOG")" -ge 2 ] && break
    sleep 5
  done
}

# ── 0. 준비 확인 ──────────────────────────────
mapfile -t TARGETS < <(health | sort)
healthy=$(printf '%s\n' "${TARGETS[@]}" | awk '$2 == "healthy"' | wc -l)
if [ "$healthy" -lt 2 ]; then
  echo "정상 서버가 ${healthy}대입니다. 장애 테스트는 2대 이상에서 하세요."
  echo "  → 내 PC의 terraform.tfvars에서 app_count = 3 → terraform apply → 몇 분 뒤 다시 실행"
  health
  exit 1
fi
TARGET=$(printf '%s\n' "${TARGETS[@]}" | head -1 | awk '{print $1}')
already=$(alarms_in_alarm)
if [ -n "$already" ]; then
  echo "⚠️ 이미 울리고 있는 긴급 알람이 있습니다: ${already}"
  echo "   이전 테스트의 알람이 OK로 돌아올 때까지 2~3분 기다린 뒤 다시 실행하세요 (알람 시각을 정확히 재기 위해)."
  exit 1
fi
TARGET_NAME=$(aws ec2 describe-instances --instance-ids "$TARGET" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' --output text 2>/dev/null || echo "$TARGET")

echo "════════════════════════════════════════"
echo " 장애 테스트: ${LABEL}"
echo " 정상 서버 ${healthy}대 중 ${TARGET_NAME:-$TARGET} 을(를) 멈춥니다"
echo " 순서: 정상 부하 ${WARMUP}초 → 서버 멈춤 → ${DOWN_SECONDS}초 뒤 다시 켬 → 복구 확인 (전체 ${DURATION})"
echo " 재는 것: ALB가 알아챈 시간, 긴급 알람이 울린 시간, 실패한 요청 수, 복구 시간"
echo " 시작: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S') (한국 시간)"
echo " 실시간 그래프: 브라우저에서 k6 웹 대시보드를 여세요"
echo "════════════════════════════════════════"

# ── 1. 부하 시작 (뒤에서 계속 돌게 둔다) ─────
K6_NO_USAGE_REPORT=true \
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_HOST=0.0.0.0 K6_WEB_DASHBOARD_PORT=5665 \
K6_WEB_DASHBOARD_EXPORT="${REPORT}" K6_CSV_TIME_FORMAT=unix_milli \
BASE_URL="${BASE_URL}" VUS="${VUS}" DURATION="${DURATION}" \
  /usr/local/bin/k6 run -q --summary-export "${SUMMARY}" --out "csv=${CSV}" \
  /opt/loadtest/failover.js > "${REPORT_DIR}/${LABEL}-k6.log" 2>&1 &
K6_PID=$!

echo "▶ 정상 상태로 ${WARMUP}초 부하를 줍니다..."
sleep "$WARMUP"

# ── 2. 서버 멈추기 ──────────────────────────
echo "▶ ${TARGET_NAME:-$TARGET} 의 앱을 멈춥니다 (systemctl stop)"
STOPPED_MS=$(run_on "$TARGET" "systemctl stop approval-app") || { kill $K6_PID; exit 1; }
echo "  멈춘 시각: $(TZ=Asia/Seoul date -d @$((STOPPED_MS / 1000)) '+%H:%M:%S')"
watch_alarms &
ALARM_PID=$!

# ── 3. ALB가 알아챌 때까지 1초마다 확인 ──────
DETECTED_MS=""
for _ in $(seq 1 120); do
  st=$(state_of "$TARGET")
  if [ -n "$st" ] && [ "$st" != "healthy" ]; then
    DETECTED_MS=$(now_ms)
    echo "  ALB 판정: ${st}  → 멈추고 $(( (DETECTED_MS - STOPPED_MS) / 1000 ))초 뒤에 알아챘습니다"
    break
  fi
  sleep 1
done
[ -z "$DETECTED_MS" ] && echo "  120초 동안 ALB가 알아채지 못했습니다 (헬스체크 설정 확인 필요)"

# ── 4. 멈춘 상태 유지 후 다시 켜기 ───────────
elapsed=$(( ($(now_ms) - STOPPED_MS) / 1000 ))
if [ "$elapsed" -lt "$DOWN_SECONDS" ]; then
  echo "▶ 서버가 꺼진 상태로 $(( DOWN_SECONDS - elapsed ))초 더 둡니다 (남은 서버들이 버티는지 보기)"
  sleep $(( DOWN_SECONDS - elapsed ))
fi
echo "▶ 앱을 다시 켭니다 (systemctl start)"
STARTED_MS=$(run_on "$TARGET" "systemctl start approval-app") || STARTED_MS=""

RECOVERED_MS=""
if [ -n "$STARTED_MS" ]; then
  for _ in $(seq 1 180); do
    if [ "$(state_of "$TARGET")" = "healthy" ]; then
      RECOVERED_MS=$(now_ms)
      echo "  다시 정상 판정: 켜고 $(( (RECOVERED_MS - STARTED_MS) / 1000 ))초 뒤 (Java가 뜨는 시간 포함)"
      break
    fi
    sleep 1
  done
fi

wait $ALARM_PID 2>/dev/null
ALARMS_JSON=$(awk 'BEGIN{printf "{"} {printf "%s\"%s\": %s", (NR>1?", ":""), $1, $2} END{printf "}"}' "$ALARMS_LOG")

cat > "$EVENTS" <<EOF
{"target": "${TARGET}", "target_name": "${TARGET_NAME:-$TARGET}",
 "stopped_ms": ${STOPPED_MS}, "detected_ms": ${DETECTED_MS:-null},
 "started_ms": ${STARTED_MS:-null}, "recovered_ms": ${RECOVERED_MS:-null},
 "alarms": ${ALARMS_JSON}}
EOF

echo "▶ 부하 테스트가 끝날 때까지 기다립니다..."
wait $K6_PID

# ── 5. 결과 정리 ────────────────────────────
echo
python3 /opt/loadtest/report.py failover "$CSV" "$EVENTS" "$RESULT"
echo
python3 /opt/loadtest/report.py split "$SUMMARY"

for f in "$REPORT" "$SUMMARY" "$EVENTS" "$RESULT" "$CSV" "$ALARMS_LOG"; do
  aws s3 cp "$f" "s3://${BUCKET}/reports/" --only-show-errors
done
URL=$(aws s3 presign "s3://${BUCKET}/reports/${LABEL}.html" --expires-in 21600)
echo
echo " 리포트(그래프 포함 HTML, 약 6시간 동안 열림):"
echo " ${URL}"
echo
echo " 📷 캡처: 위 결과 표, k6 리포트의 실패 그래프, CloudWatch ⓪ 알람 상태 · ③ 5xx · ④ 정상/비정상 서버 수"
echo "    (알람 목록 화면에서 알람을 누르면 '기록' 탭에 ALARM으로 바뀐 시각이 남아 있습니다)"
