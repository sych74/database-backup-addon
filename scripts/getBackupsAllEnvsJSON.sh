#!/bin/bash

restic self-update &>/dev/null || true

ENV_LIST=$(ls /data)

OUTPUT_JSON="{\"result\": 0, \"envs\": ["

if [ -n "$ENV_LIST" ]; then
    for i in $ENV_LIST; do
        DIRECTORY_LIST=$(RESTIC_PASSWORD="$i" restic -r /data/$i snapshots --json)
        [ -z "$DIRECTORY_LIST" ] || OUTPUT_JSON="${OUTPUT_JSON}{\"${i}\": ${DIRECTORY_LIST}},"
    done
    OUTPUT_JSON="${OUTPUT_JSON%,}"
fi

OUTPUT_JSON="${OUTPUT_JSON}]}"

echo $OUTPUT_JSON
