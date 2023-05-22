#!/bin/bash

BASE_URL=$2
BACKUP_TYPE=$3
NODE_ID=$4
BACKUP_LOG_FILE=$5
ENV_NAME=$6
BACKUP_COUNT=$7
DBUSER=$8
DBPASSWD=$9

BACKUP_ADDON_REPO=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $1"/"$2}')
BACKUP_ADDON_BRANCH=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $3}')
BACKUP_ADDON_COMMIT_ID=$(git ls-remote https://github.com/${BACKUP_ADDON_REPO}.git | grep "/${BACKUP_ADDON_BRANCH}$" | awk '{print $1}')

if [ "$COMPUTE_TYPE" == "redis" ]; then
    if grep -q '^cluster-enabled yes' /etc/redis.conf; then
        REDIS_TYPE="-cluster"
    else
        REDIS_TYPE="-standalone"
    fi
fi

function check_backup_repo(){
    [ -d /opt/backup/${ENV_NAME}  ] || mkdir -p /opt/backup/${ENV_NAME}
    RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME}  snapshots || RESTIC_PASSWORD=${ENV_NAME} restic init -r /opt/backup/${ENV_NAME}
    echo $(date) ${ENV_NAME}  "Checking the backup repository integrity and consistency" | tee -a ${BACKUP_LOG_FILE}
    { RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME} check | tee -a $BACKUP_LOG_FILE; } || { echo "Backup repository integrity check (before backup) failed."; exit 1; }
}

function rotate_snapshots(){
    echo $(date) ${ENV_NAME} "Rotating snapshots by keeping the last ${BACKUP_COUNT}" | tee -a ${BACKUP_LOG_FILE}
    { RESTIC_PASSWORD=${ENV_NAME} restic forget -q -r /opt/backup/${ENV_NAME} --keep-last ${BACKUP_COUNT} --prune | tee -a $BACKUP_LOG_FILE; } || { echo "Backup rotation failed."; exit 1; }
}

function create_snapshot(){
    echo $(date) ${ENV_NAME} "Saving the DB dump to ${DUMP_NAME} snapshot" | tee -a ${BACKUP_LOG_FILE}
    DUMP_NAME=$(date "+%F_%H%M%S"-\($COMPUTE_TYPE-$COMPUTE_TYPE_FULL_VERSION$REDIS_TYPE\))
    if [ "$COMPUTE_TYPE" == "redis" ]; then
        RDB_TO_BACKUP=$(ls -d /tmp/* |grep redis-dump.*);
        RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME}  backup --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ${RDB_TO_BACKUP} | tee -a ${BACKUP_LOG_FILE};
    else
        RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME}  backup --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ~/db_backup.sql | tee -a ${BACKUP_LOG_FILE}
    fi
}

function backup(){
    echo $$ > /var/run/${ENV_NAME}_backup.pid
    echo $(date) ${ENV_NAME} "Creating the ${BACKUP_TYPE} backup (using the backup addon with commit id ${BACKUP_ADDON_COMMIT_ID}) on storage node ${NODE_ID}" | tee -a ${BACKUP_LOG_FILE}
    source /etc/jelastic/metainf.conf;
    echo $(date) ${ENV_NAME} "Creating the DB dump" | tee -a ${BACKUP_LOG_FILE}
    if [ "$COMPUTE_TYPE" == "redis" ]; then
        RDB_TO_REMOVE=$(ls -d /tmp/* |grep redis-dump.*)
        rm -f ${RDB_TO_REMOVE}
        export REDISCLI_AUTH=$(cat /etc/redis.conf |grep '^requirepass'|awk '{print $2}');
        if [ "$REDIS_TYPE" == "-standalone" ]; then
            redis-cli --rdb /tmp/redis-dump-standalone.rdb
        else
            export MASTERS_LIST=$(redis-cli cluster nodes|grep master|grep -v fail|awk '{print $2}'|awk -F : '{print $1}');
            for i in $MASTERS_LIST
            do
                redis-cli -h $i --rdb /tmp/redis-dump-cluster-$i.rdb || { echo "DB backup process failed."; exit 1; }
            done
        fi
    else
        if [ "$COMPUTE_TYPE" == "postgres" ]; then
            PGPASSWORD="${DBPASSWD}" psql -U ${DBUSER} -d postgres -c "SELECT current_user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
            PGPASSWORD="${DBPASSWD}" pg_dumpall -U ${DBUSER} > db_backup.sql || { echo "DB backup process failed."; exit 1; }
            sed -ci -e '/^ALTER ROLE webadmin WITH SUPERUSER/d' db_backup.sql 
        else
            mysql -h localhost -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW COLUMNS FROM user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
            mysqldump -h localhost -u ${DBUSER} -p${DBPASSWD} --force --single-transaction --quote-names --opt --all-databases > db_backup.sql || { echo "DB backup process failed."; exit 1; }
        fi
    fi
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
    *)
        echo "Usage: $0 {backup|check_backup_repo|rotate_snapshots|create_snapshot}"
        exit 2
esac

exit $?
