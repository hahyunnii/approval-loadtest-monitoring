#!/bin/bash
# 다른 스크립트들이 공통으로 쓰는 설정
set -a
source /opt/loadtest/env
set +a
export MYSQL_PWD="$DB_PASSWORD" # 비밀번호를 명령줄에 노출하지 않도록

sql() {
  mysql -h "$DB_HOST" -u "$DB_USER" --default-character-set=utf8mb4 "$DB_NAME" "$@"
}
