#!/bin/bash

DBUSER=$1
DBPASSWD=$2
ACTION=$3

check_pitr() {
  MYSQL_VERSION=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SELECT VERSION();")
  MYSQL_MAJOR_VERSION=$(echo "$MYSQL_VERSION" | cut -d. -f1)

  if [[ "$MYSQL_MAJOR_VERSION" -ge 8 ]]; then
    BINLOG_EXPIRE_SETTING="binlog_expire_logs_seconds"
    EXPIRY_SETTING="604800" # 7 дней в секундах
  else
    BINLOG_EXPIRE_SETTING="expire_logs_days"
    EXPIRY_SETTING="7"
  fi

  LOG_BIN=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE 'log_bin';" | grep "ON")
  EXPIRE_LOGS=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE '$BINLOG_EXPIRE_SETTING';" | awk '{ print $2 }')

  if [[ -n "$LOG_BIN" && "$EXPIRE_LOGS" == "$EXPIRY_SETTING" ]]; then
    echo '{"result":0}'
  else
    echo '{"result":702}'
  fi
}

setup_pitr() {

  MYSQL_VERSION=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SELECT VERSION();")
  MYSQL_MAJOR_VERSION=$(echo "$MYSQL_VERSION" | cut -d. -f1)

  if [[ "$MYSQL_MAJOR_VERSION" -ge 8 ]]; then
    CONFIG="
[mysqld]
log-bin=mysql-bin
binlog_expire_logs_seconds=604800
"
  else
    CONFIG="
[mysqld]
log-bin=mysql-bin
expire_logs_days=7
"
  fi

  CONFIG_FILE="/etc/conf.d/mysql/pitr.cnf"
  echo "$CONFIG" > "$CONFIG_FILE"

}

case $ACTION in
  checkPitr)
    check_pitr
    ;;
  setupPitr)
    setup_pitr
    ;;
esac
