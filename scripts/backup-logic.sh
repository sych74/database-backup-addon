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

if [ "$COMPUTE_TYPE" == "mongodb" ]; then
    if grep -q '^replication' /etc/mongod.conf; then
        MONGO_TYPE="-replica-set"
    else
        MONGO_TYPE="-standalone"
    fi
fi

source /etc/jelastic/metainf.conf;

if [ "$COMPUTE_TYPE" == "redis" ]; then
    REDIS_CONF_PATH=$(realpath /etc/redis.conf)
    if grep -q '^cluster-enabled yes' ${REDIS_CONF_PATH}; then
        REDIS_TYPE="-cluster"
    else
        REDIS_TYPE="-standalone"
    fi
fi

function forceInstallUpdateRestic(){
        wget --tries=10 -O /tmp/installUpdateRestic ${BASE_URL}/scripts/installUpdateRestic && \
        mv -f /tmp/installUpdateRestic /usr/sbin/installUpdateRestic && \
        chmod +x /usr/sbin/installUpdateRestic && /usr/sbin/installUpdateRestic
}

function sendEmailNotification(){
    if [ -e "/usr/lib/jelastic/modules/api.module" ]; then
        [ -e "/var/run/jem.pid" ] && return 0;
        CURRENT_PLATFORM_MAJOR_VERSION=$(jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/statistic/system/rest/getversion 2>/dev/null |jq .version|grep -o [0-9.]*|awk -F . '{print $1}')
        if [ "${CURRENT_PLATFORM_MAJOR_VERSION}" -ge "7" ]; then
            echo $(date) ${ENV_NAME} "Sending e-mail notification about removing the stale lock" | tee -a $BACKUP_LOG_FILE;
            SUBJECT="Stale lock is removed on /opt/backup/${ENV_NAME} backup repo"
            BODY="Please pay attention to /opt/backup/${ENV_NAME} backup repo because the stale lock left from previous operation is removed during the integrity check and backup rotation. Manual check of backup repo integrity and consistency is highly desired."
            jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/message/email/rest/send --data-urlencode "session=$USER_SESSION" --data-urlencode "to=$USER_EMAIL" --data-urlencode "subject=$SUBJECT" --data-urlencode "body=$BODY"
            if [[ $? != 0 ]]; then
                echo $(date) ${ENV_NAME} "Sending of e-mail notification failed" | tee -a $BACKUP_LOG_FILE;
            else
                echo $(date) ${ENV_NAME} "E-mail notification is sent successfully" | tee -a $BACKUP_LOG_FILE;
            fi
        elif [ -z "${CURRENT_PLATFORM_MAJOR_VERSION}" ]; then #this elif covers the case if the version is not received
            echo $(date) ${ENV_NAME} "Error when checking the platform version" | tee -a $BACKUP_LOG_FILE;
        else
            echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE;
        fi
    else
        echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE;
    fi
}

function update_restic(){
    if which restic; then
        restic self-update || forceInstallUpdateRestic
    else
        forceInstallUpdateRestic
    fi
}

function check_backup_repo(){
    [ -d /opt/backup/${ENV_NAME} ] || mkdir -p /opt/backup/${ENV_NAME}
    export FILES_COUNT=$(ls -n /opt/backup/${ENV_NAME}|awk '{print $2}');
    if [ "${FILES_COUNT}" != "0" ]; then 
        echo $(date) ${ENV_NAME}  "Checking the backup repository integrity and consistency" | tee -a $BACKUP_LOG_FILE;
        if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]] ; then
	    echo $(date) ${ENV_NAME}  "Backup repository has a slate lock, removing" | tee -a $BACKUP_LOG_FILE;
            GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
	    sendEmailNotification
        fi
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME} check --read-data-subset=5% || { echo "Backup repository integrity check failed."; exit 1; }
    else
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic init -r /opt/backup/${ENV_NAME}
    fi
}

function rotate_snapshots(){
    echo $(date) ${ENV_NAME} "Rotating snapshots by keeping the last ${BACKUP_COUNT}" | tee -a ${BACKUP_LOG_FILE}
    if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]] ; then
        echo $(date) ${ENV_NAME}  "Backup repository has a slate lock, removing" | tee -a $BACKUP_LOG_FILE;
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
	sendEmailNotification
    fi
    { GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic forget -q -r /opt/backup/${ENV_NAME} --keep-last ${BACKUP_COUNT} --prune | tee -a $BACKUP_LOG_FILE; } || { echo "Backup rotation failed."; exit 1; }
}

function create_snapshot(){
    source /etc/jelastic/metainf.conf 
    echo $(date) ${ENV_NAME} "Saving the DB dump to ${DUMP_NAME} snapshot" | tee -a ${BACKUP_LOG_FILE}
    DUMP_NAME=$(date "+%F_%H%M%S_%Z"-${BACKUP_TYPE}\($COMPUTE_TYPE-$COMPUTE_TYPE_FULL_VERSION$REDIS_TYPE$MONGO_TYPE\))
    if [ "$COMPUTE_TYPE" == "redis" ]; then
        RDB_TO_BACKUP=$(ls -d /tmp/* |grep redis-dump.*);
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ${RDB_TO_BACKUP} | tee -a ${BACKUP_LOG_FILE};
    elif [ "$COMPUTE_TYPE" == "mongodb" ]; then
        echo $(date) ${ENV_NAME} "Saving the DB dump to ${DUMP_NAME} snapshot" | tee -a ${BACKUP_LOG_FILE}
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ~/dump | tee -a ${BACKUP_LOG_FILE}	    
    else
        GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ~/db_backup.sql | tee -a ${BACKUP_LOG_FILE}
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
        export REDISCLI_AUTH=$(cat ${REDIS_CONF_PATH} |grep '^requirepass'|awk '{print $2}');
        if [ "$REDIS_TYPE" == "-standalone" ]; then
            redis-cli --rdb /tmp/redis-dump-standalone.rdb
        else
            export MASTERS_LIST=$(redis-cli cluster nodes|grep master|grep -v fail|awk '{print $2}'|awk -F : '{print $1}');
            for i in $MASTERS_LIST
            do
                redis-cli -h $i --rdb /tmp/redis-dump-cluster-$i.rdb || { echo "DB backup process failed."; exit 1; }
            done
        fi
    elif [ "$COMPUTE_TYPE" == "postgres" ]; then
        PGPASSWORD="${DBPASSWD}" psql -U ${DBUSER} -d postgres -c "SELECT current_user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
	PGPASSWORD="${DBPASSWD}" pg_dumpall -U webadmin | grep -v '^ALTER ROLE webadmin WITH SUPERUSER' > db_backup.sql || { echo "DB backup process failed."; exit 1; } 
    elif [ "$COMPUTE_TYPE" == "mongodb" ]; then
        if grep -q ^[[:space:]]*replSetName /etc/mongod.conf; then
            RS_NAME=$(grep ^[[:space:]]*replSetName /etc/mongod.conf|awk '{print $2}');
	    RS_SUFFIX="/?replicaSet=${RS_NAME}&readPreference=nearest";
        else
            RS_SUFFIX="";
        fi
	TLS_MODE=$(yq eval  '.net.tls.mode' /etc/mongod.conf)
        if [ "$TLS_MODE" == "requireTLS" ]; then
	    SSL_TLS_OPTIONS="--ssl --sslPEMKeyFile=/var/lib/jelastic/keys/SSL-TLS/client/client.pem --sslCAFile=/var/lib/jelastic/keys/SSL-TLS/client/root.pem --tlsInsecure"
        else
	    SSL_TLS_OPTIONS=""
	fi
        mongodump ${SSL_TLS_OPTIONS} --uri="mongodb://${DBUSER}:${DBPASSWD}@localhost${RS_SUFFIX}"
    else
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
            DUMP_APP="mysql"
        fi
        ${CLIENT_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW COLUMNS FROM user" || { echo "DB credentials specified in add-on settings are incorrect!"; exit 1; }
        ${DUMP_APP} -h ${SERVER_IP_ADDR} -u ${DBUSER} -p${DBPASSWD} --force --single-transaction --quote-names --opt --all-databases > db_backup.sql || { echo "DB backup process failed."; exit 1; }
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
     update_restic)
	$1
        ;;
    *)
        echo "Usage: $0 {backup|check_backup_repo|rotate_snapshots|create_snapshot|update_restic}"
        exit 2
esac

exit $?
