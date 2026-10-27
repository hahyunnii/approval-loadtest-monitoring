#!/bin/bash
# 결재 문서 테이블을 만들고 100만 건을 넣는다.
# (PDF: "프로덕션 환경과 비슷한 데이터 셋팅" — 데이터가 적으면 DB가 실제보다 빠르게 측정된다)
set -euo pipefail
source /opt/loadtest/common.sh

echo "▶ 1/3 테이블 만들기 (인덱스 없이, 기본 키만)"
sql <<'SQL'
CREATE TABLE IF NOT EXISTS approval_docs (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  drafter_id  INT          NOT NULL,
  approver_id INT          NOT NULL,
  title       VARCHAR(200) NOT NULL,
  status      VARCHAR(20)  NOT NULL,
  created_at  DATETIME     NOT NULL
);
SQL

count=$(sql -N -e "SELECT COUNT(*) FROM approval_docs")
if [ "$count" -ge 1000000 ]; then
  echo "이미 ${count}건이 있습니다. 넣지 않고 넘어갑니다."
  exit 0
fi

echo "▶ 2/3 결재 문서 100만 건 넣기 (직원 1만 명, 최근 3년치) — 1~3분 걸립니다"
start=$(date +%s)
sql <<'SQL'
SET SESSION cte_max_recursion_depth = 1000000;
INSERT INTO approval_docs (drafter_id, approver_id, title, status, created_at)
WITH RECURSIVE seq (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 1000000
)
SELECT
  FLOOR(1 + RAND() * 10000),
  FLOOR(1 + RAND() * 10000),
  CONCAT('결재 문서 ', LPAD(n, 7, '0')),
  ELT(1 + FLOOR(RAND() * 3), '대기', '승인', '반려'),
  NOW() - INTERVAL FLOOR(RAND() * 94608000) SECOND
FROM seq;
SQL
echo "  걸린 시간: $(( $(date +%s) - start ))초"

echo "▶ 3/3 확인"
sql -e "SELECT COUNT(*) AS total_docs, COUNT(DISTINCT approver_id) AS employees FROM approval_docs;"
sql -e "SHOW INDEX FROM approval_docs;"
echo "완료. 지금은 기본 키(PRIMARY) 인덱스만 있습니다."
