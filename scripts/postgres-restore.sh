#!/bin/bash

CLIENT_APP="psql"
PGPASSWORD=${2} ${CLIENT_APP} --no-readline -q -U ${1} -d postgres < /root/db_backup.sql;
