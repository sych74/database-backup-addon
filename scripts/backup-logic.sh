#!/bin/bash

BASE_URL=$1
BACKUP_TYPE=$2
NODE_ID=$3
BACKUP_LOG_FILE=$4
ENV_NAME=$5
BACKUP_COUNT=$6
DBUSER=$7
DBPASSWD=$8
USER_SESSION=$9
USER_EMAIL=${10}
PITR=${11}

# Define PID file location after ENV_NAME is available
readonly LOCK_FILE="/var/run/${ENV_NAME}_backup.pid"

# Add cleanup trap before any potential exit points
trap 'rm -f "${LOCK_FILE}"' EXIT

# Check if another backup process is running
if [ -f "${LOCK_FILE}" ]; then
    pid=$(cat "${LOCK_FILE}")
    if kill -0 "${pid}" 2>/dev/null; then
        echo "Another backup process (PID: ${pid}) is already running" | tee -a "${BACKUP_LOG_FILE}"
        exit 1
    else
        echo "Removing stale lock file" | tee -a "${BACKUP_LOG_FILE}"
        rm -f "${LOCK_FILE}"
    fi
fi

# Create PID file
echo $$ > "${LOCK_FILE}"

# Extract repository and branch information
BACKUP_ADDON_REPO=$(echo ${BASE_URL} | sed 's|https:\/\/raw.githubusercontent.com\/||' | awk -F / '{print $1"/"$2}')
BACKUP_ADDON_BRANCH=$(echo ${BASE_URL} | sed 's|https:\/\/raw.githubusercontent.com\/||' | awk -F / '{print $3}')
BACKUP_ADDON_COMMIT_ID=$(git ls-remote https://github.com/${BACKUP_ADDON_REPO}.git | grep "/${BACKUP_ADDON_BRANCH}$" | awk '{print $1}')

# Define backup directories
DUMP_BACKUP_DIR=/root/backup/dump
BINLOGS_BACKUP_DIR=/root/backup/binlogs
SQL_DUMP_NAME=db_backup.sql

# Prepare backup directories
rm -rf $DUMP_BACKUP_DIR && mkdir -p $DUMP_BACKUP_DIR
rm -rf $BINLOGS_BACKUP_DIR && mkdir -p $BINLOGS_BACKUP_DIR

# Default PITR to false if not set
if [ -z "$PITR" ]; then
    PITR="false"
fi

# Determine MongoDB type
if [ "$COMPUTE_TYPE" == "mongodb" ]; then
    if grep -q '^replication' /etc/mongod.conf; then
        MONGO_TYPE="-replica-set"
    else
        MONGO_TYPE="-standalone"
    fi
fi

# Source external configuration
source /etc/jelastic/metainf.conf

# Determine Redis type
if [ "$COMPUTE_TYPE" == "redis" ]; then
    REDIS_CONF_PATH=$(realpath /etc/redis.conf)
    if grep -q '^cluster-enabled yes' ${REDIS_CONF_PATH}; then
        REDIS_TYPE="-cluster"
    else
        REDIS_TYPE="-standalone"
    fi
fi

# Determine server IP address
SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}' | sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"

# Determine MySQL/MariaDB client applications
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

# Function to force install/update Restic
function forceInstallUpdateRestic() {
    wget --tries=10 -O /tmp/installUpdateRestic ${BASE_URL}/scripts/installUpdateRestic && \
    mv -f /tmp/installUpdateRestic /usr/sbin/installUpdateRestic && \
    chmod +x /usr/sbin/installUpdateRestic && /usr/sbin/installUpdateRestic
}

# Function to send email notification
function sendEmailNotification() {
    if [ -e "/usr/lib/jelastic/modules/api.module" ]; then
        [ -e "/var/run/jem.pid" ] && return 0
        CURRENT_PLATFORM_MAJOR_VERSION=$(jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/statistic/system/rest/getversion 2>/dev/null | jq .version | grep -o [0-9.]* | awk -F . '{print $1}')
        if [ "${CURRENT_PLATFORM_MAJOR_VERSION}" -ge "7" ]; then
            echo $(date) ${ENV_NAME} "Sending e-mail notification about removing the stale lock" | tee -a $BACKUP_LOG_FILE
            SUBJECT="Stale lock is removed on /opt/backup/${ENV_NAME} backup repo"
            BODY="Please pay attention to /opt/backup/${ENV_NAME} backup repo because the stale lock left from previous operation is removed during the integrity check and backup rotation. Manual check of backup repo integrity and consistency is highly desired."
            jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/message/email/rest/send --data-urlencode "session=$USER_SESSION" --data-urlencode "to=$USER_EMAIL" --data-urlencode "subject=$SUBJECT" --data-urlencode "body=$BODY"
            if [[ $? != 0 ]]; then
                echo $(date) ${ENV_NAME} "Sending of e-mail notification failed" | tee -a $BACKUP_LOG_FILE
            else
                echo $(date) ${ENV_NAME} "E-mail notification is sent successfully" | tee -a $BACKUP_LOG_FILE
            fi
        elif [ -z "${CURRENT_PLATFORM_MAJOR_VERSION}" ]; then
            echo $(date) ${ENV_NAME} "Error when checking the platform version" | tee -a $BACKUP_LOG_FILE
        else
            echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE
        fi
    else
        echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE
    fi
}

# Function to update Restic
function update_restic() {
    if which restic; then
        restic self-update || forceInstallUpdateRestic
    else
        forceInstallUpdateRestic
    fi
}

# Function to check backup repository
function check_backup_repo() {
    [ -d /opt/backup/${ENV_NAME} ] || mkdir -p /opt/backup/${ENV_NAME}
    export FILES_COUNT=$(ls -n /opt/backup/${ENV_NAME} | awk '{print $2}')
    if [ "${FILES_COUNT}" != "0" ]; then
        echo $(date) ${ENV_NAME} "Checking the backup repository integrity and consistency" | tee -a $BACKUP_LOG_FILE
        if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]]; then
            echo $(date) ${ENV_NAME} "Backup repository has a stale lock, removing" | tee -a $BACKUP_LOG_FILE
            GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
            sendEmailNotification
        fi
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME} check --read-data-subset=5% || { echo "Backup repository integrity check failed."; exit 1; }
    else
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic init -r /opt/backup/${ENV_NAME}
    fi
}

# Function to rotate snapshots
function rotate_snapshots() {
    echo $(date) ${ENV_NAME} "Rotating snapshots by keeping the last ${BACKUP_COUNT}" | tee -a ${BACKUP_LOG_FILE}
    if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]]; then
        echo $(date) ${ENV_NAME} "Backup repository has a stale lock, removing" | tee -a $BACKUP_LOG_FILE
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
        sendEmailNotification
    fi
    { GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic forget -q -r /opt/backup/${ENV_NAME} --keep-last ${BACKUP_COUNT} --prune | tee -a $BACKUP_LOG_FILE; } || { echo "Backup rotation failed."; exit 1; }
}

# Function to get binlog file
function get_binlog_file() {
    local binlog_file=$(${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW MASTER STATUS" | awk 'NR==2 {print $1}')
    echo $(date) ${ENV_NAME} "Getting the binlog_file: ${binlog_file}" >> ${BACKUP_LOG_FILE}
    echo $binlog_file
}

# Function to get binlog position
function get_binlog_position() {
    local binlog_pos=$(${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW MASTER STATUS" | awk 'NR==2 {print $2}')
    echo $(date) ${ENV_NAME} "Getting the binlog_position: ${binlog_pos}" >> ${BACKUP_LOG_FILE}
    echo $binlog_pos
}

# Function to create snapshot
function create_snapshot() {
    source /etc/jelastic/metainf.conf
    DUMP_NAME=$(date "+%F_%H%M%S_%Z"-${BACKUP_TYPE}\($COMPUTE_TYPE-$COMPUTE_TYPE_FULL_VERSION$REDIS_TYPE$MONGO_TYPE\))
    echo $(date) ${ENV_NAME} "Saving the DB dump to ${DUMP_NAME} snapshot" | tee -a ${BACKUP_LOG_FILE}
    if [ "$COMPUTE_TYPE" == "redis" ]; then
        RDB_TO_BACKUP=$(ls -d /tmp/* | grep redis-dump.*)
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ${RDB_TO_BACKUP} | tee -a ${BACKUP_LOG_FILE}
    elif [ "$COMPUTE_TYPE" == "mongodb" ]; then
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ${DUMP_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
    elif [ "$COMPUTE_TYPE" == "postgresql" ] && [ "$PITR" == "true" ]; then
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} \
            --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" \
            --tag "PITR" \
            --tag "$(cat ${DUMP_BACKUP_DIR}/wal_location)" \
            ${DUMP_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
    else
        if [ "$PITR" == "true" ]; then
            GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" --tag "PITR" --tag "$(get_binlog_file)" --tag "$(get_binlog_position)" ${DUMP_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
        else
            GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ${DUMP_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
        fi
    fi
}

# Function to get latest PITR snapshot ID
function get_latest_pitr_snapshot_id() {
    local latest_pitr_snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --tag "PITR" --latest 1 --json | jq -r '.[0].short_id')
    echo $(date) ${ENV_NAME} "Getting the latest PITR snapshot: ${latest_pitr_snapshot_id}" >> ${BACKUP_LOG_FILE}
    echo ${latest_pitr_snapshot_id}
}

# Function to get dump name by snapshot ID
function get_dump_name_by_snapshot_id() {
    local snapshot_id="$1"
    local dump_name=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r --arg id "$snapshot_id" '.[] | select(.short_id == $id) | .tags[0]')
    echo $(date) ${ENV_NAME} "Getting the dump name: ${dump_name}" >> ${BACKUP_LOG_FILE}
    echo ${dump_name}
}

# Function to get binlog file by snapshot ID
function get_binlog_file_by_snapshot_id() {
    local snapshot_id="$1"
    local binlog_file=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r --arg id "$snapshot_id" '.[] | select(.short_id == $id) | .tags[2]')
    echo $(date) ${ENV_NAME} "Getting the start binlog file name: ${binlog_file}" >> ${BACKUP_LOG_FILE}
    echo ${binlog_file}
}

# Function to get PostgreSQL WAL location
function get_pg_wal_location() {
    local wal_location=$(PGPASSWORD="${DBPASSWD}" psql -U ${DBUSER} -d postgres -t -c "SELECT pg_current_wal_lsn();" | tr -d ' ')
    echo $(date) ${ENV_NAME} "Getting the WAL location: ${wal_location}" >> ${BACKUP_LOG_FILE}
    echo $wal_location
}

# Function to backup PostgreSQL WAL files
function backup_postgres_wal() {
    local wal_dir="/var/lib/postgresql/wal_archive"
    echo $(date) ${ENV_NAME} "Backing up PostgreSQL WAL files..." | tee -a $BACKUP_LOG_FILE
    rm -rf ${BINLOGS_BACKUP_DIR} && mkdir -p ${BINLOGS_BACKUP_DIR}
    
    # Copy WAL files from archive directory
    if [ -d "$wal_dir" ]; then
        cp -r $wal_dir/* ${BINLOGS_BACKUP_DIR}/ || { echo "WAL files backup failed."; exit 1; }
    else
        echo "Warning: WAL archive directory does not exist" | tee -a $BACKUP_LOG_FILE
    fi
    echo "PostgreSQL WAL files backup completed." | tee -a $BACKUP_LOG_FILE
}

# Function to create WAL snapshot
function create_wal_snapshot() {
    local snapshot_name="$1"
    echo $(date) ${ENV_NAME} "Saving the WAL files to ${snapshot_name} snapshot" | tee -a ${BACKUP_LOG_FILE}
    GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${snapshot_name}" --tag "PGWAL" ${BINLOGS_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
}

# Function to backup Redis
function backup_redis() {
    source /etc/jelastic/metainf.conf
    RDB_TO_REMOVE=$(ls -d /tmp/* | grep redis-dump.*)
    rm -f ${RDB_TO_REMOVE}
    export REDISCLI_AUTH=$(cat ${REDIS_CONF_PATH} | grep '^requirepass' | awk '{print $2}')
    if [ "$REDIS_TYPE" == "-standalone" ]; then
        redis-cli --rdb /tmp/redis-dump-standalone.rdb
    else
        export MASTERS_LIST=$(redis-cli cluster nodes | grep master | grep -v fail | awk '{print $2}' | awk -F : '{print $1}')
        for i in $MASTERS_LIST; do
            redis-cli -h $i --rdb /tmp/redis-dump-cluster-$i.rdb || { echo "DB backup process failed."; exit 1; }
        done
    fi
}

# Function to backup PostgreSQL
function backup_postgres() {
    PGPASSWORD="${DBPASSWD}" psql -U ${DBUSER} -d postgres -c "SELECT current_user" || { 
        echo "DB credentials specified in add-on settings are incorrect!" | tee -a $BACKUP_LOG_FILE
        exit 1
    }

    if [ "$PITR" == "true" ]; then
        # Get current WAL location before backup
        local wal_location=$(get_pg_wal_location)
        
        # Perform backup with WAL position
        PGPASSWORD="${DBPASSWD}" pg_dumpall -U webadmin --clean --if-exist > ${DUMP_BACKUP_DIR}/db_backup.sql || { 
            echo "DB backup process failed." | tee -a $BACKUP_LOG_FILE
            exit 1
        }
        echo $wal_location > ${DUMP_BACKUP_DIR}/wal_location

        # Get latest PITR snapshot and backup WAL files if exists
        local latest_pitr_snapshot_id=$(get_latest_pitr_snapshot_id)
        if [ "x$latest_pitr_snapshot_id" != "xnull" ]; then
            local dump_name=$(get_dump_name_by_snapshot_id "$latest_pitr_snapshot_id")
            backup_postgres_wal
            create_wal_snapshot "${dump_name}"
        fi
    else
        # Regular backup without PITR
        PGPASSWORD="${DBPASSWD}" pg_dumpall -U webadmin --clean --if-exist > ${DUMP_BACKUP_DIR}/db_backup.sql || { 
            echo "DB backup process failed." | tee -a $BACKUP_LOG_FILE
            exit 1
        }
    fi
}

# Function to backup MongoDB
function backup_mongodb() {
    if grep -q ^[[:space:]]*replSetName /etc/mongod.conf; then
        RS_NAME=$(grep ^[[:space:]]*replSetName /etc/mongod.conf | awk '{print $2}')
        RS_SUFFIX="/?replicaSet=${RS_NAME}&readPreference=nearest"
    else
        RS_SUFFIX=""
    fi
    TLS_MODE=$(yq eval '.net.tls.mode' /etc/mongod.conf)
    if [ "$TLS_MODE" == "requireTLS" ]; then
        SSL_TLS_OPTIONS="--ssl --sslPEMKeyFile=/var/lib/jelastic/keys/SSL-TLS/client/client.pem --sslCAFile=/var/lib/jelastic/keys/SSL-TLS/client/root.pem --tlsInsecure"
    else
        SSL_TLS_OPTIONS=""
    fi
    mongodump ${SSL_TLS_OPTIONS} --uri="mongodb://${DBUSER}:${DBPASSWD}@localhost${RS_SUFFIX}" --out="${DUMP_BACKUP_DIR}"
}

# Function to backup MySQL dump
function backup_mysql_dump() {
    ${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW COLUMNS FROM user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
    if [ "$PITR" == "true" ]; then
        ${DUMP_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} --master-data=2 --flush-logs --force --single-transaction --quote-names --opt --all-databases > ${DUMP_BACKUP_DIR}/${SQL_DUMP_NAME} || { echo "DB backup process failed."; exit 1; }
    else
        ${DUMP_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} --force --single-transaction --quote-names --opt --all-databases > ${DUMP_BACKUP_DIR}/${SQL_DUMP_NAME} || { echo "DB backup process failed."; exit 1; }
    fi
}

# Function to backup MySQL binary logs
function backup_mysql_binlogs() {
    local start_binlog_file="$1"
    echo $(date) ${ENV_NAME} "Backing up MySQL binary logs from $start_binlog_file..." | tee -a $BACKUP_LOG_FILE
    rm -rf ${BINLOGS_BACKUP_DIR} && mkdir -p ${BINLOGS_BACKUP_DIR}
    find /var/lib/mysql -type f -name "mysql-bin.*" -newer /var/lib/mysql/${start_binlog_file} -o -name "${start_binlog_file}" -exec cp {} ${BINLOGS_BACKUP_DIR} \;
    echo "MySQL binary logs backup completed." | tee -a $BACKUP_LOG_FILE
}

# Function to perform PITR backup for MySQL
function backup_mysql_pitr() {
    echo $(date) ${ENV_NAME} "Starting Point-In-Time Recovery (PITR) backup..." | tee -a $BACKUP_LOG_FILE
    backup_mysql_dump
    backup_mysql_binlogs
    echo $(date) ${ENV_NAME} "PITR backup completed." | tee -a $BACKUP_LOG_FILE
}

# Function to create binlog snapshot
function create_binlog_snapshot() {
    local snapshot_name="$1"
    echo $(date) ${ENV_NAME} "Saving the BINLOGS to ${snapshot_name} snapshot" | tee -a ${BACKUP_LOG_FILE}
    GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${snapshot_name}" --tag "BINLOGS" ${BINLOGS_BACKUP_DIR} | tee -a ${BACKUP_LOG_FILE}
}

# Function to backup MySQL
function backup_mysql() {
    local exit_code=0
    backup_mysql_dump || exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "Error: MySQL dump failed" | tee -a "$BACKUP_LOG_FILE"
        return $exit_code
    }

    if [ "$PITR" == "true" ]; then
        local latest_pitr_snapshot_id
        latest_pitr_snapshot_id=$(get_latest_pitr_snapshot_id)
        
        if [ "x$latest_pitr_snapshot_id" != "xnull" ]; then
            local dump_name start_binlog_file
            dump_name=$(get_dump_name_by_snapshot_id "$latest_pitr_snapshot_id")
            start_binlog_file=$(get_binlog_file_by_snapshot_id "$latest_pitr_snapshot_id")
            
            backup_mysql_binlogs "$start_binlog_file"
            create_binlog_snapshot "${dump_name}"
        fi
    fi
}

# Main section improvement
main() {
    echo "$(date) ${ENV_NAME} Starting backup process..." | tee -a "${BACKUP_LOG_FILE}"
    
    check_backup_repo
    rotate_snapshots
    source /etc/jelastic/metainf.conf
    
    echo "$(date) ${ENV_NAME} Creating DB dump..." | tee -a "${BACKUP_LOG_FILE}"
    
    case "$COMPUTE_TYPE" in
        redis)    backup_redis ;;
        mongodb)  backup_mongodb ;;
        postgres) backup_postgres ;;
        *)        backup_mysql ;;
    esac
    
    create_snapshot
    rotate_snapshots
    check_backup_repo
}

# Execute main function
main "$@"
