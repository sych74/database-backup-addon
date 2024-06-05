
PGPASSWORD=%(dbpass) psql --no-readline -q -U %(dbuser) -d postgres < /root/db_backup.sql 2> >(tee -a %(restoreLogFile) >&2); else true; fi',
