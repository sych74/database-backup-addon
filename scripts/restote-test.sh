#!/bin/bash

DBUSER=$1
DBPASSWD=$2
RESTORE_LOG_FILE=$3
PITR=$4

DUMP_BACKUP_DIR=/root/backup/dump
BINLOGS_BACKUP_DIR=/root/backup/binlogs
SQL_DUMP_NAME=db_backup.sql

if [ -f /root/.backupedenv ]; then
    ENV_NAME=$(cat /root/.backupedenv)
else
    echo "The /root/.backupedenv file with ENV_NAME doesnt exist."
    exit 1;
fi

if [ -z "$PITR" ]; then
    PITR="false"
fi

if [ "$PITR" == "true" ]; then
    if [ -f /root/.backuptime ]; then
        BACKUP_TIME=$(cat /root/.backuptime)
    else
        echo "The /root/.backuptime file with BACKUP_TIME doesnt exist."
        exit 1;
    fi
else
    if [ -f /root/.backupid ]; then
        BACKUP_NAME=$(cat /root/.backupid)
    else
        echo "The /root/.backupid file with BACKUP_NAME doesnt exist."
        exit 1;
    fi
fi

function find_closest_snapshot_id_before_time() {
    local target_datetime="$1"
    RESTIC_PASSWORD=env-9009578 restic -r /opt/backup/env-9009578 snapshots --tag "PITR" --json | jq -r '.[] | "\(.time) \(.short_id) \(.tags[0])"' | sort -r | while read snapshot_time      snapshot_id snapshot_tag; do
        snapshot_tag_date=$(echo "$snapshot_tag" | grep -oP '\d{4}-\d{2}-\d{2}_\d{6}')
        snapshot_datetime=$(echo "$snapshot_tag_date" | sed 's/_/ /' | sed 's/\(....\)-\(..\)-\(..\) \(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')
        snapshot_datetime_epoch=$(date -d "$snapshot_datetime" +%s)
        target_epoch=$(date -d "$target_datetime" +%s)
        if [ "$snapshot_datetime_epoch" -le "$target_epoch" ]; then
            result_snapshot_id=$snapshot_id
            return 0
        fi
    done
    if [[ -z "$result_snapshot_id" ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to get DB dump snapshot ID before time $target_datetime" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    else
        echo $(date) ${ENV_NAME} "Getting DB dump snapshot ID before time $target_datetime: $result_snapshot_id" >> ${RESTORE_LOG_FILE}
        echo $result_snapshot_id;
    fi
}

function get_dump_snapshot_id_by_name(){
    local backup_name="$1"
    local snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r '.[] | select(.tags[0] | contains('$backup_name')) | select((.tags[1] | contains("BINLOGS") | not) // true) | .short_id')
    if [[ $? -ne 0 || -z "$snapshot_id" ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to get DB dump snapshot ID" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Getting DB dump snapshot ID: $snapshot_id" >> ${RESTORE_LOG_FILE}
    echo $snapshot_id
}

function get_binlog_snapshot_id_by_name(){
    local backup_name="$1"
    local snapshot_id=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --tag "BINLOGS" --json | jq -r '.[] | select(.tags[0] | contains('$backup_name')) | .short_id')
    if [[ $? -ne 0 || -z "$snapshot_id" ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to get DB binlogs snapshot ID" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Getting DB binlogs snapshot ID: $snapshot_id" >> ${RESTORE_LOG_FILE}
    echo $snapshot_id
}


function get_snapshot_name_by_id(){
    local snapshot_id="$1"
    local snapshot_name=$(GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} snapshots --json | jq -r --arg id "$snapshot_id" '.[] | select(.short_id == $id) | .tags[0]')
    if [[ $? -ne 0 || -z "$dump_name" ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to get snapshot name for $snapshot_id" | tee -a ${RESTORE_LOG_FILE}
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Getting the snapshot name: ${snapshot_name}" >> ${BACKUP_LOG_FILE}
    echo ${snapshot_name}
}

function restore_snapshot_by_id(){
    local snapshot_id="$1"
    RESTIC_PASSWORD=${ENV_NAME} GOGC=20 restic -r /opt/backup/${ENV_NAME} restore ${snapshot_id} --target / 
    if [[ $? -ne 0 ]]; then
        echo $(date) ${ENV_NAME} "Error: Failed to restore snapshot ID $snapshot_id" | tee -a ${RESTORE_LOG_FILE};
        exit 1
    fi
    echo $(date) ${ENV_NAME} "Snapshot ID: $snapshot_id restored successfully" >> ${RESTORE_LOG_FILE}
}

