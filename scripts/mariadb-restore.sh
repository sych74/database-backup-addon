#!/bin/bash

SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}'| sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"
if which mariadb 2>/dev/null; then
    CLIENT_APP="mariadb"
else
    CLIENT_APP="mysql"
fi

${CLIENT_APP} --silent -h ${SERVER_IP_ADDR} -u ${1} -p${2} --force < /root/db_backup.sql;
