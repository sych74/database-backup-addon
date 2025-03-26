#!/bin/bash

restic self-update &>/dev/null || true

OUTPUT_JSON="{\"result\": 0, \"envs\": {"

for i in $(ls /data); do
    SNAPSHOTS_JSON=$(RESTIC_PASSWORD="$i" restic -r /data/$i snapshots --json)
    DIRECTORY_LIST=$(echo "$SNAPSHOTS_JSON" | jq -r '[.[] | .tags[0] | split(" ")[0]] | map("\"" + . + "\"") | join(",")')

    SERVER_VERSION=$(echo "$SNAPSHOTS_JSON" | jq -r '[.[] | .tags[0] | capture("\\((?<server_version>[^)]+)").server_version] | unique | .[0]')

    SERVER=$(echo "$SERVER_VERSION" | cut -d'-' -f1)
    VERSION=$(echo "$SERVER_VERSION" | cut -d'-' -f2-)

    if [ -n "$DIRECTORY_LIST" ]; then
        OUTPUT_JSON="${OUTPUT_JSON}\"${i}\": { \"server\": \"${SERVER}\", \"version\": \"${VERSION}\", \"backups\": [${DIRECTORY_LIST}] },"
    else
        OUTPUT_JSON="${OUTPUT_JSON}\"${i}\": { \"server\": \"${SERVER}\", \"version\": \"${VERSION}\", \"backups\": [] },"
    fi
done

OUTPUT_JSON=${OUTPUT_JSON::-1}
OUTPUT_JSON="${OUTPUT_JSON}}}"

echo "$OUTPUT_JSON"