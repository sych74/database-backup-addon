#!/bin/bash

source /.jelenv

SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}'| sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"
if which mariadb 2>/dev/null; then
    CLIENT_APP="mariadb"
else
    CLIENT_APP="mysql"
fi

if [ -n "${SCHEME}" ] && [ x"${SCHEME}" == x"galera" ]; then
    curl --silent https://raw.githubusercontent.com/jelastic-jps/mysql-cluster/master/addons/recovery/scripts/db-recovery.sh > /tmp/db-recovery.sh
    bash /tmp/db-recovery.sh --scenario restore_galera --from-backup /root/db_backup.sql
else
    ${CLIENT_APP} --silent -h ${SERVER_IP_ADDR} -u ${1} -p${2} --force < /root/db_backup.sql
fi
