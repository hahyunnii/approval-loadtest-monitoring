#!/bin/bash
# 결재함 조회 쿼리를 DB가 "어떻게" 실행하는지(실행 계획) 보여준다.
#   type=ALL, rows≈100만  → 매번 100만 건을 다 읽는다 (인덱스 없음)
#   type=ref, rows≈100    → 인덱스로 내 문서만 바로 찾는다
set -euo pipefail
source /opt/loadtest/common.sh

QUERY="SELECT id, drafter_id, title, status, created_at FROM approval_docs WHERE approver_id = 1234 ORDER BY created_at DESC LIMIT 20"

echo "▶ 실행 계획 (EXPLAIN)"
sql -t -e "EXPLAIN ${QUERY};"

echo "▶ 실제 실행 시간 (한 번 실행)"
start=$(date +%s%N)
sql -e "${QUERY};" > /dev/null
echo "  $(( ($(date +%s%N) - start) / 1000000 ))ms"
