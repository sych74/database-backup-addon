#!/bin/bash

REDIS_CONF_PATH=$(realpath /etc/redis.conf)
RDB_TO_RESTORE=$(ls -d /tmp/* |grep redis-dump.*);

cd tmp; wget https://github.com/tair-opensource/RedisShake/releases/download/v3.1.11/redis-shake-linux-amd64.tar.gz;
tar -xf redis-shake-linux-amd64.tar.gz;
grep -q '^cluster-enabled yes' ${REDIS_CONF_PATH} && REDIS_TYPE="cluster" || REDIS_TYPE="standalone";
sed -ci -e "s/^type =.*/type = '${REDIS_TYPE}'/" restore.toml;
sed -ci -e "1s/^type =.*/type = 'restore'/" restore.toml;
export REDISCLI_AUTH=$(cat ${REDIS_CONF_PATH} |grep '^requirepass'|awk '{print $2}');
sed -ci -e "s/^password =.*/password = '${REDISCLI_AUTH}'/" restore.toml;
RESTORE_MASTER_ID=$(redis-cli cluster nodes|grep master|grep -v fail|head -n 1|awk '{print $2}'|awk -F : '{print $1}')
sed -ci -e "s/^address =.*/address = '${RESTORE_MASTER_ID}:6379'/" restore.toml;
for i in ${RDB_TO_RESTORE}
do
    sed -ci -e "s|^rdb_file_path =.*|rdb_file_path = '${i}'|" restore.toml;
    ./redis-shake restore.toml 1>/dev/null
done
rm -f ${RDB_TO_RESTORE}
rm -f redis-shake* sync.toml restore.toml 
