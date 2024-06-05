#!/bin/bash

CLIENT_APP="psql"
SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}'| sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"
PGPASSWORD=${2} psql --no-readline -q -U ${1} -d postgres < /root/db_backup.sql;
