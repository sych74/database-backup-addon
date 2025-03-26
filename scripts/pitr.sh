#!/bin/bash

ACTION=$1
DBUSER=$2
DBPASSWD=$3

# Configuration file paths
PITR_CONF_MYSQL='/etc/mysql/conf.d/pitr.cnf'
PITR_CONF_PG='/etc/postgresql/12/main/postgresql.conf'
ARCHIVE_DIR_PG='/var/lib/postgresql/wal_archive'
BACKUP_DIR_PG='/var/lib/postgresql/backups'

# Source external configuration
source /etc/jelastic/metainf.conf

# Format compute type version
COMPUTE_TYPE_FULL_VERSION_FORMATTED=$(echo "$COMPUTE_TYPE_FULL_VERSION" | sed -E 's/^([0-9]+)\.([0-9]+)\..*$/\1.\2/' | sed 's/\.//')

# Determine binlog expire settings based on compute type
if [[ ("$COMPUTE_TYPE" == "mysql" || "$COMPUTE_TYPE" == "percona") && "$COMPUTE_TYPE_FULL_VERSION_FORMATTED" -ge "81" ]]; then
  BINLOG_EXPIRE_SETTING="binlog_expire_logs_seconds"
  EXPIRY_SETTING="604800"
elif [[ "$COMPUTE_TYPE" == "mariadb" ]]; then
  BINLOG_EXPIRE_SETTING="expire_logs_days"
  EXPIRY_SETTING="7"
else
  BINLOG_EXPIRE_SETTING=""
  EXPIRY_SETTING=""
fi

# PostgreSQL WAL archive settings
WAL_ARCHIVE_SETTING="archive_mode"
WAL_ARCHIVE_COMMAND="archive_command"
WAL_TIMEOUT_SETTING="archive_timeout"
WAL_TIMEOUT_VALUE="60"
WAL_ARCHIVE_ON="on"

# Function to check PITR configuration for MySQL
check_pitr_mysql() {
  LOG_BIN=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE 'log_bin';" | grep "ON")
  EXPIRE_LOGS=$(mysql -u"$DBUSER" -p"$DBPASSWD" -se "SHOW VARIABLES LIKE '$BINLOG_EXPIRE_SETTING';" | awk '{ print $2 }')
  if [[ -n "$LOG_BIN" && "$EXPIRE_LOGS" == "$EXPIRY_SETTING" ]]; then
    echo '{"result":0}';
    return 0;
  else
    echo '{"result":702}';
  fi
}

# Function to set up PITR configuration for MySQL
setup_pitr_mysql() {
  check_pitr_mysql | grep -q '"result":0'
  if [[ $? -eq 0 ]]; then
    exit 0;
  fi

  CONFIG="
[mysqld]
log-bin=mysql-bin
$BINLOG_EXPIRE_SETTING=$EXPIRY_SETTING
"
  echo "$CONFIG" > "$PITR_CONF_MYSQL"
  jem service restart;
}

# Function to check PITR configuration for PostgreSQL
check_pitr_pg() {
  ARCHIVE_MODE=$(sudo -u postgres psql -U "$DBUSER" -c "SHOW $WAL_ARCHIVE_SETTING;" | grep "on")
  ARCHIVE_COMMAND=$(sudo -u postgres psql -U "$DBUSER" -c "SHOW $WAL_ARCHIVE_COMMAND;" | grep "$ARCHIVE_DIR_PG")

  if [[ -n "$ARCHIVE_MODE" && -n "$ARCHIVE_COMMAND" ]]; then
    echo '{"result":0}';
    return 0;
  else
    echo '{"result":702}';
  fi
}

# Function to set up PITR configuration for PostgreSQL
setup_pitr_pg() {
  check_pitr_pg | grep -q '"result":0'
  if [[ $? -eq 0 ]]; then
    exit 0;
  fi

  CONFIG="
# PITR Configuration
archive_mode = on
archive_command = 'test ! -f $ARCHIVE_DIR_PG/%f && cp %p $ARCHIVE_DIR_PG/%f'
archive_timeout = $WAL_TIMEOUT_VALUE
"

  echo "$CONFIG" >> "$PITR_CONF_PG"

  if [ ! -d "$ARCHIVE_DIR_PG" ]; then
    sudo mkdir -p "$ARCHIVE_DIR_PG"
    sudo chown -R postgres:postgres "$ARCHIVE_DIR_PG"
  fi

  jem service restart;
  echo '{"result":0}';
}

# Main script logic
case $ACTION in
  checkPitr)
    if [[ "$COMPUTE_TYPE" == "mysql" || "$COMPUTE_TYPE" == "percona" || "$COMPUTE_TYPE" == "mariadb" ]]; then
      check_pitr_mysql
    elif [[ "$COMPUTE_TYPE" == "postgresql" ]]; then
      check_pitr_pg
    else
      echo '{"result":99}';
    fi
    ;;
  setupPitr)
    if [[ "$COMPUTE_TYPE" == "mysql" || "$COMPUTE_TYPE" == "percona" || "$COMPUTE_TYPE" == "mariadb" ]]; then
      setup_pitr_mysql
    elif [[ "$COMPUTE_TYPE" == "postgresql" ]]; then
      setup_pitr_pg
    else
      echo '{"result":99}';
    fi
    ;;
  *)
    echo "Usage: $0 {checkPitr|setupPitr} DBUSER DBPASSWD"
    ;;
esac
