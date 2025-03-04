#!/bin/bash

restic self-update &>/dev/null || true

ENV_LIST=$(ls -Qm /data)

OUTPUT_JSON="{\"result\": 0, \"envs\": [${ENV_LIST}], \"backups\": {"

if [ -n "$ENV_LIST" ]; then

    for i in $(ls /data)
    do
        DIRECTORY_LIST=$(RESTIC_PASSWORD="$i" restic -r /data/$i snapshots|awk '{print $5}'|grep -v 'Paths'|grep '[0-9.*]'|awk '{print "\""$1"\""}'|tr '\n' ',')
        [ -z "${DIRECTORY_LIST}" ] || DIRECTORY_LIST=${DIRECTORY_LIST::-1}
        OUTPUT_JSON="${OUTPUT_JSON}\"${i}\":[${DIRECTORY_LIST}],"
    done

    OUTPUT_JSON=${OUTPUT_JSON::-1}
fi

echo $OUTPUT_JSON}}