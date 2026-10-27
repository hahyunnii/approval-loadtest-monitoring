#!/bin/bash
# 인덱스를 지워서 "조치 전" 상태로 되돌린다 (다시 실험하고 싶을 때)
set -euo pipefail
source /opt/loadtest/common.sh

sql -e "DROP INDEX idx_approver_created ON approval_docs;"
sql -e "SHOW INDEX FROM approval_docs;"
echo "인덱스를 지웠습니다."
