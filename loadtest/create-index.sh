#!/bin/bash
# 조치 1: 결재함 조회용 인덱스 만들기
#   WHERE approver_id = ? ORDER BY created_at DESC  →  (approver_id, created_at) 복합 인덱스
set -euo pipefail
source /opt/loadtest/common.sh

echo "▶ 인덱스 만들기 (100만 건이라 30초~1분 걸릴 수 있습니다)"
start=$(date +%s)
sql -e "CREATE INDEX idx_approver_created ON approval_docs (approver_id, created_at);"
echo "  걸린 시간: $(( $(date +%s) - start ))초"
sql -e "SHOW INDEX FROM approval_docs;"
echo
/opt/loadtest/explain.sh
