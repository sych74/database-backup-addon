#!/bin/bash

DBUSER=$1
DBPASSWD=$2
RESTORE_TYPE=$3  # 'full' or 'pitr'
FULL_BACKUP_FILE=$4
STOP_TIME=$5  # For PITR, specify the datetime until which to apply the binary logs (format: YYYY-MM-DD HH:MM:SS)

SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}' | sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"

if which mariadb 2>/dev/null; then
    CLIENT_APP="mariadb"
else
    CLIENT_APP="mysql"
fi

function restore_full() {
    echo $(date) ${ENV_NAME} "Restoring the full backup from ${FULL_BACKUP_FILE}" | tee -a $BACKUP_LOG_FILE;
    ${CLIENT_APP} --silent -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} --force < ${FULL_BACKUP_FILE}
    if [ $? -eq 0 ]; then
        echo $(date) ${ENV_NAME} "Full backup restoration completed successfully." | tee -a $BACKUP_LOG_FILE;
    else
        echo $(date) ${ENV_NAME} "Error occurred while restoring the full backup." | tee -a $BACKUP_LOG_FILE;
        exit 1
    fi
}

function restore_pitr() {
    echo $(date) ${ENV_NAME} "Restoring full backup for PITR..." | tee -a $BACKUP_LOG_FILE;
    restore_full
    if [ -z "${STOP_TIME}" ]; then
        echo "Error: Please specify the stop time for PITR."
        exit 1
    fi

    echo "Applying binary logs until ${STOP_TIME} for PITR..."

    mysqlbinlog --stop-datetime="${STOP_TIME}" /opt/backup/mysql_binlogs/mysql-bin.* | ${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD}
    if [ $? -eq 0 ]; then
        echo "Binary logs applied successfully up to ${STOP_TIME}."
    else
        echo "Error occurred while applying binary logs."
        exit 1
    fi
}

if [ "${RESTORE_TYPE}" == "full" ]; then
    restore_full
elif [ "${RESTORE_TYPE}" == "pitr" ]; then
    restore_pitr
else
    echo "Invalid restore type. Use 'full' for full restore or 'pitr' for point-in-time recovery."
    exit 1
fi
