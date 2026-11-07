#!/bin/bash
# 005：建立唯讀帳號，給 Redash 查詢用（只有 SELECT 權限）
# 用 .sh 而不是 .sql，因為要從環境變數讀取密碼，.sql 檔做不到
mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_RO_USER}'@'%' IDENTIFIED BY '${MYSQL_RO_PASSWORD}';
ALTER USER '${MYSQL_RO_USER}'@'%' IDENTIFIED BY '${MYSQL_RO_PASSWORD}';
GRANT SELECT ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_RO_USER}'@'%';
SQL
