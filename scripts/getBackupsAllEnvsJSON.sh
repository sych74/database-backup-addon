#!/bin/bash

restic self-update &>/dev/null || true

OUTPUT_JSON="{\"result\": 0, \"envs\": {"

for i in $(ls /data); do

    PITR=false
    PITR_START_TIME=null

    SNAPSHOTS_JSON=$(RESTIC_PASSWORD="$i" restic -r /data/$i snapshots --json | jq 'sort_by(.time) | reverse')

    DIRECTORY_LIST=$(echo "$SNAPSHOTS_JSON" | jq -r '[.[] | select(.tags | index("BINLOGS") | not) | .tags[0] | split(" ")[0]] | map("\"" + . + "\"") | join(",")')

    SERVER_VERSION=$(echo "$SNAPSHOTS_JSON" | jq -r '[.[] | .tags[0] | capture("\\((?<server_version>[^)]+)").server_version] | unique | .[0]')

    SERVER=$(echo "$SERVER_VERSION" | cut -d'-' -f1)
    VERSION=$(echo "$SERVER_VERSION" | cut -d'-' -f2-)

    if [[ "$SERVER" == "mariadb" || "$SERVER" == "postgres" || "$SERVER" == "mysql" ]]; then
        FIRST_SNAPSHOT=$(echo "$SNAPSHOTS_JSON" | jq '.[0]')

        if echo "$FIRST_SNAPSHOT" | jq -e '.tags | index("PITR")' &>/dev/null; then
            PITR=true
            FIRST_TAG=$(echo "$FIRST_SNAPSHOT" | jq -r '.tags[0]')
            PITR_START_TIME=$(echo "$FIRST_TAG" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_UTC')

            SNAPSHOT_COUNT=$(echo "$SNAPSHOTS_JSON" | jq 'length')
            for (( j=1; j < SNAPSHOT_COUNT-2; j+=2 )); do
                SECOND_TAG=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$j].tags[0]")
                THIRD_TAG=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$((j+1))].tags[0]")

                if [[ "$SECOND_TAG" == "$THIRD_TAG" ]]; then
                    PITR_START_TIME=$(echo "$SECOND_TAG" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_UTC')
                else
                    break
                fi
            done
        fi
    fi

    PITR_START_TIME=$(echo "$PITR_START_TIME" | jq -R)

    if [ -n "$DIRECTORY_LIST" ]; then
        OUTPUT_JSON="${OUTPUT_JSON}\"${i}\": { \"server\": \"${SERVER}\", \"version\": \"${VERSION}\", \"pitr\": ${PITR}, \"pitrStartTime\": ${PITR_START_TIME}, \"backups\": [${DIRECTORY_LIST}] },"
    else
        OUTPUT_JSON="${OUTPUT_JSON}\"${i}\": { \"server\": \"${SERVER}\", \"version\": \"${VERSION}\", \"pitr\": ${PITR}, \"pitrStartTime\": ${PITR_START_TIME}, \"backups\": [] },"
    fi
done

OUTPUT_JSON=${OUTPUT_JSON::-1}
OUTPUT_JSON="${OUTPUT_JSON}}}"

echo "$OUTPUT_JSON"
