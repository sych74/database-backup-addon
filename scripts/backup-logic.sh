#!/bin/bash

BASE_URL=$2
BACKUP_TYPE=$3
NODE_ID=$4
BACKUP_LOG_FILE=$5
ENV_NAME=$6
BACKUP_COUNT=$7
DBUSER=$8
DBPASSWD=$9
USER_SESSION=${10}
USER_EMAIL=${11}

BACKUP_ADDON_REPO=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $1"/"$2}')
BACKUP_ADDON_BRANCH=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $3}')
BACKUP_ADDON_COMMIT_ID=$(git ls-remote https://github.com/${BACKUP_ADDON_REPO}.git | grep "/${BACKUP_ADDON_BRANCH}$" | awk '{print $1}')

MYSQL_BACKUP_DIR="/opt/backup/mysql"
MYSQL_BINLOG_DIR="/opt/backup/mysql_binlogs"

source /etc/jelastic/metainf.conf;

function backup_binlogs() {
    echo $(date) ${ENV_NAME} "Backing up MySQL binary logs..." | tee -a $BACKUP_LOG_FILE
    mkdir -p ${MYSQL_BINLOG_DIR}
    cp /var/lib/mysql/mysql-bin.* ${MYSQL_BINLOG_DIR}/
    echo "Binary logs backup completed." | tee -a $BACKUP_LOG_FILE
}

function pitr_backup() {
    echo $(date) ${ENV_NAME} "Starting Point-In-Time Recovery (PITR) backup..." | tee -a $BACKUP_LOG_FILE
    backup
    backup_binlogs
    echo $(date) ${ENV_NAME} "PITR backup completed." | tee -a $BACKUP_LOG_FILE
}

function backup(){
    echo $$ > /var/run/${ENV_NAME}_backup.pid
    echo $(date) ${ENV_NAME} "Creating the ${BACKUP_TYPE} backup (using the backup addon with commit id ${BACKUP_ADDON_COMMIT_ID}) on storage node ${NODE_ID}" | tee -a ${BACKUP_LOG_FILE}
    source /etc/jelastic/metainf.conf;
    echo $(date) ${ENV_NAME} "Creating the DB dump" | tee -a ${BACKUP_LOG_FILE}
    SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}'| sed 's/\/[0-9]*//g' | tail -n 1)
    [ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"
    if which mariadb 2>/dev/null; then
        CLIENT_APP="mariadb"
    else
        CLIENT_APP="mysql"
    fi
    if which mariadb-dump 2>/dev/null; then
        DUMP_APP="mariadb-dump"
    else
        DUMP_APP="mysqldump"
    fi
    ${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW COLUMNS FROM user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
    ${DUMP_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} --force --single-transaction --quote-names --opt --all-databases > db_backup.sql || { echo "DB backup process failed."; exit 1; }
    rm -f /var/run/${ENV_NAME}_backup.pid
}

case "$1" in
    backup)
        $1
        ;;
    check_backup_repo)
        $1
        ;;
    rotate_snapshots)
        $1
        ;;
    create_snapshot)
        $1
        ;;
    update_restic)
        $1
        ;;
    pitr_backup)
        pitr_backup
        ;;
    *)
        echo "Usage: $0 {backup|check_backup_repo|rotate_snapshots|create_snapshot|update_restic|enable_binlog|pitr_backup|restore_pitr <full_backup_file> <stop_time>}"
        exit 2
esac

exit $?
