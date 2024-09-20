#!/bin/bash

ACTION=$1
DBUSER=$2
DBPASSWD=$3

PITR_CONF='/etc/mysql/conf.d/pitr.cnf'

source /etc/jelastic/metainf.conf
COMPUTE_TYPE_FULL_VERSION_FORMATTED=$(echo "$COMPUTE_TYPE_FULL_VERSION" | sed 's/\.//')
if [[ ("$COMPUTE_TYPE" == "mysql" || "$COMPUTE_TYPE" == "percona") && "$COMPUTE_TYPE_FULL_VERSION_FORMATTED" -ge "81" ]]; then
  BINLOG_EXPIRE_SETTING="binlog_expire_logs_seconds"
  EXPIRY_SETTING="604800"
elif [[ "$COMPUTE_TYPE" == "mariadb" ]]; then
  BINLOG_EXPIRE_SETTING="expire_logs_days"
  EXPIRY_SETTING="7"
else
  echo '{"result":99}';
fi
  
check_pitr() {
  LOG_BIN=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE 'log_bin';" | grep "ON")
  EXPIRE_LOGS=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE '$BINLOG_EXPIRE_SETTING';" | awk '{ print $2 }')
  if [[ -n "$LOG_BIN" && "$EXPIRE_LOGS" == "$EXPIRY_SETTING" ]]; then
    echo '{"result":0}';
    return 0;
  else
    echo '{"result":702}';
  fi
}

setup_pitr() {
  check_pitr | grep -q '"result":0'
  if [[ $? -eq 0 ]]; then
    exit 0;
  fi

  CONFIG="
[mysqld]
log-bin=mysql-bin
$BINLOG_EXPIRE_SETTING=$EXPIRY_SETTING
"
  echo "$CONFIG" > "$PITR_CONF"
}

case $ACTION in
  checkPitr)
    check_pitr
    ;;
  setupPitr)
    setup_pitr
    ;;
esac
