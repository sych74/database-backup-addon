#!/bin/bash

CLIENT_APP="psql"
ORIG_BACKUP="/root/db_backup.sql"
TEMP_BACKUP="/tmp/db_backup.sql"

[ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
cp "$ORIG_BACKUP" "$TEMP_BACKUP"

sed -i -e '/^CREATE ROLE webadmin/d' \
       -e '/^CREATE ROLE postgres/d' \
       -e '/^DROP ROLE IF EXISTS postgres/d' \
       -e '/^DROP ROLE IF EXISTS webadmin/d' \
       -e '/^ALTER ROLE postgres WITH SUPERUSER/d' \
       -e '/^ALTER ROLE webadmin WITH SUPERUSER/d' "$TEMP_BACKUP"

PGPASSWORD=${2} ${CLIENT_APP} --no-readline -q -U ${1} -d postgres < "$TEMP_BACKUP";

[ -f "$TEMP_BACKUP" ] && rm -f "$TEMP_BACKUP"
