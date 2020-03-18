#!/usr/bin/env bash

# Orchestrate the automatic execution of all the cql migration scripts when starting the cluster

# Protect from iterating on empty directories
shopt -s nullglob

# set -x # trace
set -e # fail on error


finish() {
    if [ "$?" -ne 0 ]; then
        echo "migration failed"
        exit 1
    fi
}

trap "finish" EXIT

function usage() {
    echo "usage: $0 <dfce|referentiel>"
}

function main() {

    parseArguments $@
    waitForClusterConnection

    log "ensure migrator schema is created"
    create_migrator_schema

    log "execute all non already executed scripts from $CQL_FILES_PATH"
    migrateAll "$CQL_FILES_PATH/*.cql"

    log "migration done"
}

function parseArguments() {
    if [[ "$#" -ne 1 ]]; then
        usage
        exit 1
    fi

    CASSANDRA_CONTACT_POINT=${CASSANDRA_CONTACT_POINT:-localhost}
    MIGRATOR_KEYSPACE=${MIGRATOR_KEYSPACE:-migrator}
    MIGRATOR_SCHEMA_CREATE_SCRIPT="{{ install_dir }}/migrator/create-migrator-schema.cql"

    TARGET_KEYSPACE=${1}
    CQL_FILES_PATH="{{folder_cql_scripts}}/$TARGET_KEYSPACE/changelog"

    # set this to true and it will not execute cql scripts but still update the migrator keyspace.
    # It is useful when using this tool for the first time on an existing cluster
    FAKE_MIGRATION=${FAKE_MIGRATION:-false}

    echo "CASSANDRA_CONTACT_POINT=$CASSANDRA_CONTACT_POINT"
    echo "CQL_FILES_PATH=${CQL_FILES_PATH}"
    echo "MIGRATOR_KEYSPACE=$MIGRATOR_KEYSPACE"
    echo "TARGET_KEYSPACE=$TARGET_KEYSPACE"

}

function create_migrator_schema() {
    cqlsh -f "$MIGRATOR_SCHEMA_CREATE_SCRIPT" $CASSANDRA_CONTACT_POINT
}

function migrateAll() {
    local filePattern=$1
    # loop over migration scripts
    loadExecutedScripts
    for cqlFile in $filePattern; do
        migrateOne $cqlFile
    done
}

function migrateOne() {
    cqlFile=$1
    filename=$(basename "$1")
    if isExecuted; then
        logDebug "skipping $cqlFile already executed"
    else

        if [ "$FAKE_MIGRATION" != true ]; then
            _start=$(date +"%s")
            executeCqlScript
           _end=$(date +"%s")
           duration=`expr $_end - $_start || true`
        else
            duration=0
        fi

        logExecutedScript $duration
        log "$cqlFile executed with success in $duration seconds"
    fi
}

#load already executed scripts in the `scripts` global variable: dictionary[scriptName->checksum]
unset scripts
declare -A scripts
function loadExecutedScripts() {
    #allow spaces in cqlsh output
    IFS=$'\n'
    local rows=($(cqlsh -k $MIGRATOR_KEYSPACE -e "select script_name, checksum from schema_version WHERE target_keyspace = '$TARGET_KEYSPACE'" $CASSANDRA_CONTACT_POINT | tail -n+4 | sed '$d' |sed '$d'))

    for r in "${rows[@]}"
    do
        local scriptName=$(echo "$r" |cut -d '|' -f 1 | sed s'/^[[:space:]]*//' | sed s'/[[:space:]]*$//')
        local checksum=$(echo "$r" |cut -d '|' -f 2 | sed s'/^[[:space:]]*//' | sed s'/[[:space:]]*$//')
        scripts["X"${scriptName}]="$checksum"
    done
    unset IFS
}

function isExecuted() {
    echo ${scripts["X"${filename}]}
    if [[ ! ${scripts["X"${filename}]} = "" ]]; then
        if checksumEquals $cqlFile; then
            return 0
        else
            exitWithError "$cqlFile has already been executed but has a different checksum logged in the schema_version table.
            scripts must not be changed after being executed.
            to resolve this issue you can:
            - revert the modified script to its initial state and create a new script
            OR
            - delete the script entry from the schema_version table
            "
        fi
    else
        return 1
    fi
}

function executeCqlScript {
    log "execute: $cqlFile"
    cqlsh -k $TARGET_KEYSPACE -f $cqlFile $CASSANDRA_CONTACT_POINT

    # if execution failed
    if [ $? -ne 0 ]; then
        exitWithError "fail to apply script $filename
        stop applying database changes"
    fi
    logDebug "execution of $cqlFile succeeded"
}

function checksumEquals {
    local checksum=$(md5sum $cqlFile | cut -d ' ' -f 1)
    local foundChecksum=${scripts["X"${filename}]}

    if [[ "$checksum" == "$foundChecksum" ]]; then
        logDebug "checksum equals for $cqlFile, checksum=$checksum"
        return 0
    else
        logDebug "different checksum found for $cqlFile
        checksum=$checksum
   foundChecksum=$foundChecksum"
        return 1
    fi
}

function logExecutedScript {
    local duration=$1
    local checksum=$(md5sum $cqlFile | cut -d ' ' -f 1)

    logDebug "save $cqlFile execution in schema_version table"
    local query="INSERT INTO schema_version (target_keyspace, script_name, checksum, executed_by, executed_on, execution_time, status) VALUES ('$TARGET_KEYSPACE', '$filename', '$checksum', '$USER', dateof(now()), $duration, 'success');"
    cqlsh -k $MIGRATOR_KEYSPACE -e "$query" $CASSANDRA_CONTACT_POINT
}

function waitForClusterConnection() {
    log "waiting for cassandra connection..."
    retryCount=0
    maxRetry=20
    cqlsh -e "Describe KEYSPACES;" $CASSANDRA_CONTACT_POINT &>/dev/null
    while [ $? -ne 0 ] && [ "$retryCount" -ne "$maxRetry" ]; do
        logDebug 'cassandra not reachable yet. sleep and retry. retryCount =' $retryCount
        sleep 5
        ((retryCount+=1))
        cqlsh -e "Describe KEYSPACES;" $CASSANDRA_CONTACT_POINT &>/dev/null
    done

    if [ $? -ne 0 ]; then
      log "not connected after " $retryCount " retry. Abort the migration."
      exit 1
    fi

    log "connected to cassandra cluster"
}

function exitWithError() {
    echo "ERROR :
        $*"
    exit 1
}

function log {
    echo "[$(date)]: $*"
}

function logDebug {
    ((DEBUG_LOG)) && echo "[DEBUG][$(date)]: $*" || true
}

main $@