#!/bin/bash

DBUSER=$1
DBPASSWD=$2
RESTORE_LOG_FILE=$3

DUMP_BACKUP_DIR=/root/backup/dump
BINLOGS_BACKUP_DIR=/root/backup/binlogs
SQL_DUMP_NAME=db_backup.sql

#rm -rf $DUMP_BACKUP_DIR $BINLOGS_BACKUP_DIR

if [ -f /root/.backupedenv ]; then
    ENV_NAME=$(cat /root/.backupedenv)
else
    echo "The /root/.backupedenv file with ENV_NAME doesn't exist."
    exit 1
fi

if [ -f /root/.backuptime ]; then
    PITR="true"
    PITR_TIME=$(cat /root/.backuptime)
else
    PITR="false"
fi

if [ "$PITR" == "false" ]; then
    if [ -f /root/.backupid ]; then
        BACKUP_NAME=$(cat /root/.backupid)
    else
        echo "The /root/.backupid file with BACKUP_NAME doesn't exist."
        exit 1
    fi
fi

# Finds snapshot ID before specified timestamp
# @param {string} target_datetime - Target restoration time
# @return {string} Snapshot ID or exits with error
# Searches through PITR snapshots chronologically
function get_snapshot_id_before_time() {
    local target_datetime="$1"

    while read snapshot_time snapshot_id snapshot_tag; do
        snapshot_tag_date=$(echo "$snapshot_tag" | grep -oP '\d{4}-\d{2}-\d{2}_\d{6}')
        snapshot_datetime=$(echo "$snapshot_tag_date" | sed 's/_/ /' | sed 's/\(....\)-\(..\)-\(..\) \(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')

        snapshot_datetime_epoch=$(date -d "$snapshot_datetime" +%s)
        target_epoch=$(date -d "$target_datetime" +%s)

        if [ "$snapshot_datetime_epoch" -le "$target_epoch" ]; then
            result_snapshot_id="$snapshot_id"
            break
        fi
    done < <(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --tag "PITR" --json | jq -r '.[] | "\(.time) \(.short_id) \(.tags[0])"' | sort -r)

    if [[ -z "$result_snapshot_id" ]]; then
        echo "$(date) ${ENV_NAME} Error: Failed to get DB dump snapshot ID before time $target_datetime" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo "$(date) ${ENV_NAME} Getting DB dump snapshot ID before time $target_datetime: $result_snapshot_id" >> ${RESTORE_LOG_FILE}
    echo "$result_snapshot_id";
}

# Retrieves snapshot ID for given backup name
# @param {string} backup_name - Name of the backup to find
# @return {string} Snapshot ID or exits with error
# Filters out BINLOGS tagged snapshots
function get_dump_snapshot_id_by_name(){
    local backup_name="$1"
    local snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | \
        jq -r '.[] | select(.tags[0] | contains("'"$backup_name"'")) | 
                select((.tags | index("BINLOGS") | not)) | 
                .short_id' | head -n1)
                
    if [[ $? -ne 0 || -z "$snapshot_id" ]]; then
        echo "$(date) ${ENV_NAME} Error: Failed to get DB dump snapshot ID" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    
    echo "$(date) ${ENV_NAME} Getting DB dump snapshot ID: $snapshot_id" >> ${RESTORE_LOG_FILE}
    echo "$snapshot_id"
}

# Retrieves binlog snapshot ID for backup name
# @param {string} backup_name - Name of the backup
# @return {string} Binlog snapshot ID or exits with error
# Specifically searches for BINLOGS tagged snapshots
function get_binlog_snapshot_id_by_name(){
    local backup_name="$1"
    local snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --tag "BINLOGS" --json | jq -r --arg backup_name "$backup_name" '.[] | select(.tags[0] | contains($backup_name)) | .short_id')

    if [[ $? -ne 0 || -z "$snapshot_id" ]]; then
        echo "$(date) ${ENV_NAME} Error: Failed to get DB binlogs snapshot ID" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi

    echo "$(date) ${ENV_NAME} Getting DB binlogs snapshot ID: $snapshot_id" >> ${RESTORE_LOG_FILE}
    echo "$snapshot_id"
}

function get_snapshot_name_by_id(){
    local snapshot_id="$1"
    local snapshot_name=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r --arg id "$snapshot_id" '.[] | select(.short_id == $id) | .tags[0]')
    if [[ $? -ne 0 || -z "${snapshot_name}" ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to get snapshot name for $snapshot_id" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Getting the snapshot name: ${snapshot_name}" >> ${RESTORE_LOG_FILE}
    echo ${snapshot_name}
}

function restore_snapshot_by_id(){
    local snapshot_id="$1"
    RESTIC_PASSWORD=${ENV_NAME} GOGC=20 restic -r /opt/backup/${ENV_NAME} restore ${snapshot_id} --target /
    if [[ $? -ne 0 ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to restore snapshot ID $snapshot_id" | tee -a ${RESTORE_LOG_FILE};
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Snapshot ID: $snapshot_id restored successfully" >> ${RESTORE_LOG_FILE}
}

function restore_mysql_dump(){
    if which mariadb 2>/dev/null; then
        CLIENT_APP="mariadb"
    else
        CLIENT_APP="mysql"
    fi
    ${CLIENT_APP} -u "${DBUSER}" -p"${DBPASSWD}" < "${DUMP_BACKUP_DIR}/${SQL_DUMP_NAME}"
    if [[ $? -ne 0 ]]; then
        echo "$(date) ${ENV_NAME} Error: Failed to restore MySQL dump" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo "$(date) ${ENV_NAME} MySQL dump restored successfully" | tee -a ${RESTORE_LOG_FILE}
}

function apply_binlogs_until_time(){
    local stop_time="$1"
    local binlog_files=($BINLOGS_BACKUP_DIR/mysql-bin.*)

    if which mariadb 2>/dev/null; then
         BINLOG_APP="mariadb-binlog"
    else
         BINLOG_APP="mysqlbinlog"
    fi

    for binlog_file in "${binlog_files[@]}"; do
        ${BINLOG_APP} --stop-datetime="${stop_time}" "$binlog_file" | mysql -u "${DBUSER}" -p"${DBPASSWD}"
        if [[ $? -ne 0 ]]; then
            echo "$(date) ${ENV_NAME} Error: Failed to apply binlogs from $binlog_file" | tee -a ${RESTORE_LOG_FILE}
            exit 1
        fi
        echo "$(date) ${ENV_NAME} Applied binlogs from $binlog_file until $stop_time" >> ${RESTORE_LOG_FILE}
    done
}

function restore_mongodb(){
    dump_snapshot_id=$(get_dump_snapshot_id_by_name "${BACKUP_NAME}")
    restore_snapshot_by_id "${dump_snapshot_id}"
    if grep -q ^[[:space:]]*replSetName /etc/mongod.conf; then 
        export RS_NAME=$(grep ^[[:space:]]*replSetName /etc/mongod.conf|awk '{print $2}'); 
        export RS_SUFFIX="/?replicaSet=${RS_NAME}&readPreference=nearest"; 
    else 
        export RS_SUFFIX=""; 
    fi
    TLS_MODE=$(yq eval  '.net.tls.mode' /etc/mongod.conf)
    if [ "$TLS_MODE" == "requireTLS" ]; then
      SSL_TLS_OPTIONS="--ssl --sslPEMKeyFile=/var/lib/jelastic/keys/SSL-TLS/client/client.pem --sslCAFile=/var/lib/jelastic/keys/SSL-TLS/client/root.pem --tlsInsecure"
    else
      SSL_TLS_OPTIONS=""
    fi
    mongorestore ${SSL_TLS_OPTIONS} --uri="mongodb://${1}:${2}@localhost${RS_SUFFIX}" ${DUMP_BACKUP_DIR} 1>/dev/null

}

function restore_redis(){
    REDIS_CONF_PATH=$(realpath /etc/redis.conf)
    RDB_TO_RESTORE=$(ls -d /tmp/* |grep redis-dump.*);
    
    dump_snapshot_id=$(get_dump_snapshot_id_by_name "${BACKUP_NAME}")
    restore_snapshot_by_id "${dump_snapshot_id}"

    cd tmp; wget https://github.com/tair-opensource/RedisShake/releases/download/v3.1.11/redis-shake-linux-amd64.tar.gz;
    tar -xf redis-shake-linux-amd64.tar.gz;
    grep -q '^cluster-enabled yes' ${REDIS_CONF_PATH} && REDIS_TYPE="cluster" || REDIS_TYPE="standalone";
    sed -ci -e "s/^type =.*/type = '${REDIS_TYPE}'/" restore.toml;
    sed -ci -e "1s/^type =.*/type = 'restore'/" restore.toml;
    export REDISCLI_AUTH=$(cat ${REDIS_CONF_PATH} |grep '^requirepass'|awk '{print $2}');
    sed -ci -e "s/^password =.*/password = '${REDISCLI_AUTH}'/" restore.toml;
    RESTORE_MASTER_ID=$(redis-cli cluster nodes|grep master|grep -v fail|head -n 1|awk '{print $2}'|awk -F : '{print $1}')
    sed -ci -e "s/^address =.*/address = '${RESTORE_MASTER_ID}:6379'/" restore.toml;
    for i in ${RDB_TO_RESTORE}
    do
        sed -ci -e "s|^rdb_file_path =.*|rdb_file_path = '${i}'|" restore.toml;
        ./redis-shake restore.toml 1>/dev/null
    done
    rm -f ${RDB_TO_RESTORE}
    rm -f redis-shake* sync.toml restore.toml 
}

# Function to get WAL location by snapshot ID
function get_wal_location_by_snapshot_id() {
    local snapshot_id="$1"
    local wal_location=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r --arg id "$snapshot_id" '.[] | select(.short_id == $id) | .tags[2]')
    echo "$(date) ${ENV_NAME} Getting the WAL location: ${wal_location}" >> ${RESTORE_LOG_FILE}
    echo "$wal_location"
}

# Function to get WAL snapshot ID by name
function get_wal_snapshot_id_by_name() {
    local backup_name="$1"
    local snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --tag "PGWAL" --json | jq -r --arg backup_name "$backup_name" '.[] | select(.tags[0] | contains($backup_name)) | .short_id')

    if [[ $? -ne 0 || -z "$snapshot_id" ]]; then
        echo "$(date) ${ENV_NAME} Error: Failed to get WAL snapshot ID" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi

    echo "$(date) ${ENV_NAME} Getting WAL snapshot ID: $snapshot_id" >> ${RESTORE_LOG_FILE}
    echo "$snapshot_id"
}

# Function to restore PostgreSQL WAL files
function restore_postgres_wal() {
    local target_time="$1"
    local wal_dir="/var/lib/postgresql/wal_archive"
    
    echo "$(date) ${ENV_NAME} Restoring WAL files until $target_time..." | tee -a ${RESTORE_LOG_FILE}
    
    # Ensure WAL archive directory exists
    if [ ! -d "$wal_dir" ]; then
        sudo mkdir -p "$wal_dir"
        sudo chown postgres:postgres "$wal_dir"
    fi

    # Copy WAL files to archive directory
    sudo cp -r ${BINLOGS_BACKUP_DIR}/* "$wal_dir/"
    sudo chown -R postgres:postgres "$wal_dir"
    
    # Create recovery configuration
    sudo -u postgres bash -c "cat > /var/lib/postgresql/data/recovery.signal << EOF
# Recovery configuration
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'
recovery_target_time = '$target_time'
EOF"

    echo "$(date) ${ENV_NAME} WAL files restored successfully" >> ${RESTORE_LOG_FILE}
}

# Enhanced PostgreSQL restore function with PITR support
function restore_postgres() {
    if [ "$PITR" == "true" ]; then
        # Get snapshot before specified time
        dump_snapshot_id=$(get_snapshot_id_before_time "${PITR_TIME}")
        dump_snapshot_name=$(get_snapshot_name_by_id "${dump_snapshot_id}")
        
        # Get associated WAL snapshot
        wal_snapshot_id=$(get_wal_snapshot_id_by_name "${dump_snapshot_name}")
        
        # Restore main backup
        restore_snapshot_by_id "${dump_snapshot_id}"
        
        # Process dump file
        local ORIG_BACKUP="${DUMP_BACKUP_DIR}/db_backup.sql"
        local TEMP_BACKUP="/tmp/db_backup.sql"
        
        [ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
        cp "$ORIG_BACKUP" "$TEMP_BACKUP"
        
        # Remove problematic role commands
        sed -i -e '/^CREATE ROLE webadmin/d' \
               -e '/^CREATE ROLE postgres/d' \
               -e '/^DROP ROLE IF EXISTS postgres/d' \
               -e '/^DROP ROLE IF EXISTS webadmin/d' \
               -e '/^ALTER ROLE postgres WITH SUPERUSER/d' \
               -e '/^ALTER ROLE webadmin WITH SUPERUSER/d' "$TEMP_BACKUP"
        
        # Restore the database
        PGPASSWORD="${DBPASSWD}" psql --no-readline -q -U "${DBUSER}" -d postgres < "$TEMP_BACKUP"
        
        # Restore WAL files
        restore_snapshot_by_id "${wal_snapshot_id}"
        restore_postgres_wal "${PITR_TIME}"
        
        # Restart PostgreSQL to apply recovery
        jem service restart postgresql
        
        [ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
        
    else
        # Regular restore without PITR
        local ORIG_BACKUP="${DUMP_BACKUP_DIR}/db_backup.sql"
        local TEMP_BACKUP="/tmp/db_backup.sql"

        dump_snapshot_id=$(get_dump_snapshot_id_by_name "${BACKUP_NAME}")
        restore_snapshot_by_id "${dump_snapshot_id}"

        [ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
        cp "$ORIG_BACKUP" "$TEMP_BACKUP"

        # Remove problematic role commands
        sed -i -e '/^CREATE ROLE webadmin/d' \
               -e '/^CREATE ROLE postgres/d' \
               -e '/^DROP ROLE IF EXISTS postgres/d' \
               -e '/^DROP ROLE IF EXISTS webadmin/d' \
               -e '/^ALTER ROLE postgres WITH SUPERUSER/d' \
               -e '/^ALTER ROLE webadmin WITH SUPERUSER/d' "$TEMP_BACKUP"

        PGPASSWORD="${DBPASSWD}" psql --no-readline -q -U "${DBUSER}" -d postgres < "$TEMP_BACKUP" > /dev/null
        if [[ $? -ne 0 ]]; then
            echo "$(date) ${ENV_NAME} Error: Failed to restore PostgreSQL dump" | tee -a ${RESTORE_LOG_FILE}
            [ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
            exit 1
        fi

        echo "$(date) ${ENV_NAME} PostgreSQL dump restored successfully" | tee -a ${RESTORE_LOG_FILE}
        [ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
    fi
}

function restore_mysql(){
    if [ "$PITR" == "true" ]; then
        dump_snapshot_id=$(get_snapshot_id_before_time "${PITR_TIME}")
        dump_snapshot_name=$(get_snapshot_name_by_id "${dump_snapshot_id}")

        binlog_snapshot_id=$(get_binlog_snapshot_id_by_name "${dump_snapshot_name}")

        restore_snapshot_by_id "${dump_snapshot_id}"
        restore_mysql_dump

        restore_snapshot_by_id "${binlog_snapshot_id}"
        apply_binlogs_until_time "${PITR_TIME}"
    else
        dump_snapshot_id=$(get_dump_snapshot_id_by_name "${BACKUP_NAME}")
        restore_snapshot_by_id "${dump_snapshot_id}"
        restore_mysql_dump
    fi
}

### Main block

echo $$ > /var/run/${ENV_NAME}_restore.pid
source /etc/jelastic/metainf.conf;
echo $(date) ${ENV_NAME} "Restoring the DB dump" | tee -a ${RESTORE_LOG_FILE}
if [ "$COMPUTE_TYPE" == "redis" ]; then
    restore_redis;

elif [ "$COMPUTE_TYPE" == "mongodb" ]; then
    restore_mongodb;
        
elif [ "$COMPUTE_TYPE" == "postgres" ]; then
    restore_postgres;

else
    restore_mysql;

fi
rm -f /var/run/${ENV_NAME}_restore.pid
