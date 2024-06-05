#!/bin/bash

CLIENT_APP="psql"
SERVER_IP_ADDR=$(ip a | grep -A1 venet0 | grep inet | awk '{print $2}'| sed 's/\/[0-9]*//g' | tail -n 1)
[ -n "${SERVER_IP_ADDR}" ] || SERVER_IP_ADDR="localhost"
PGPASSWORD=%(dbpass) psql --no-readline -q -U %(dbuser) -d postgres < /root/db_backup.sql 2> >(tee -a %(restoreLogFile) >&2); else true; fi',
