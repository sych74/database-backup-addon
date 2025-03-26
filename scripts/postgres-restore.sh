#!/bin/bash

CLIENT_APP="psql"
ORIG_BACKUP="/root/db_backup.sql"
TEMP_BACKUP="/tmp/db_backup.sql"

# Check if db_backup.sql is compressed and decompress it
if [ -f "/root/db_backup.sql.gz" ]; then
    gunzip -c /root/db_backup.sql.gz > /root/db_backup.sql
fi

[ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
cp "$ORIG_BACKUP" "$TEMP_BACKUP"

sed -i -e "/^CREATE ROLE webadmin/d" \
       -e "/^CREATE ROLE postgres/d" \
       -e "/^CREATE ROLE ${1}/d" \
       -e "/^DROP ROLE IF EXISTS postgres/d" \
       -e "/^DROP ROLE IF EXISTS webadmin/d" \
       -e "/^DROP ROLE IF EXISTS ${1}/d" \
       -e "/^ALTER ROLE postgres WITH SUPERUSER/d" \
       -e "/^ALTER ROLE webadmin WITH SUPERUSER/d" \
       -e "/^ALTER ROLE ${1} WITH SUPERUSER/d" "$TEMP_BACKUP"

PGPASSWORD=${2} ${CLIENT_APP} --no-readline -q -U ${1} -d postgres < "$TEMP_BACKUP" > /dev/null;

[ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
