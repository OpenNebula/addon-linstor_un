# ----------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project (OpenNebula.org), C12G Labs           #
#                                                                               #
# Licensed under the Apache License, Version 2.0 (the "License"); you may       #
# not use this file except in compliance with the License. You may obtain       #
# a copy of the License at                                                      #
#                                                                               #
# http://www.apache.org/licenses/LICENSE-2.0                                    #
#                                                                               #
# Unless required by applicable law or agreed to in writing, software           #
# distributed under the License is distributed on an "AS IS" BASIS,             #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.      #
# See the License for the specific language governing permissions and           #
# limitations under the License.                                                #
#------------------------------------------------------------------------------ #

#--------------------------------------------------------------------------------
# Parse the output of linstor -m --output-version v0 storagepools list in json
# format and generates a monitor string for linstor pool.
# You **MUST** define JQ util before using this function
#   @param $1 the json output of the command
#--------------------------------------------------------------------------------
linstor_monitor_storpool() {
    echo "$1" | $JQ -r '.[].stor_pools[]?.free_space | .free_capacity, .total_capacity' \
        | $AWK '{if (NR % 2) {free+=$1/1024} else {total+=$1/1024}};
        END{ printf "USED_MB=%0.f\nTOTAL_MB=%0.f\nFREE_MB=%0.f\n", total-free, total, free }'
}

#--------------------------------------------------------------------------------
# Parse the output of linstor -m --output-version v0 resource-definition list in
# json format and generates a monitor strings for every VM.
# You **MUST** define JQ util before using this function
#   @param $1 the json output of the command
#   @param $2 the ID of system datastore (to monitor)
#--------------------------------------------------------------------------------
linstor_monitor_resources() {
    local DS_ID=$2
    local RES_SIZES_DATA=$($LINSTOR -m --output-version v0 resource list-volumes | \
        $JQ '.[].resources[]? | {res: .name, size: .vlms[0].allocated}' )
    RES_SIZES_STATUS=$?
    if [ $RES_SIZES_STATUS -ne 0 ]; then
        echo "$RES_SIZES_DATA"
        exit $RES_SIZES_STATUS
    fi

    while read VM_JSON; do
        # {
        #   <vmid>: [
        #     { <disk_id>: {res: <res_name>, props: []} },
        #     ...
        #   ]
        # }
        local VM_ID=$(echo "$VM_JSON" | $JQ -r '. | keys[0]')
        echo -n "VM=[ID=$VM_ID,POLL=\""
            while read DISK_JSON; do
                local DISK_ID=$(echo "$DISK_JSON" | $JQ -r '. | keys[]')
                local RES=$(echo "$DISK_JSON" | $JQ -r '.[].res')
                local DISK_SIZE_K=$(echo "$RES_SIZES_DATA" | $JQ -r "select(.res==\"${RES}\").size" | sort -n | tail -n1)
                local DISK_SIZE=$((DISK_SIZE_K/1024))
                local SNAP_IDS=$(echo "$DISK_JSON" | $JQ -r '.[].props[].key' | sed -n 's|Aux/one/SNAPSHOT_\([0-9]\+\)/DISK_SIZE|\1|p' | sort -nr | xargs)

                echo -n "DISK_SIZE=[ID=${DISK_ID},SIZE=${DISK_SIZE}] "

                # From last to first
                for SNAP_ID in $SNAP_IDS; do
                    local SNAP_DISK_SIZE_K=$(echo "$DISK_JSON" | $JQ -r ".[].props | from_entries.\"Aux/one/SNAPSHOT_${SNAP_ID}/DISK_SIZE\"")
                    local SNAP_DISK_SIZE=$((SNAP_DISK_SIZE_K/1024))
                    local SNAP_SIZE=$((DISK_SIZE-SNAP_DISK_SIZE))
                    echo -n "SNAPSHOT_SIZE=[ID=${SNAP_ID},DISK_ID=${DISK_ID},SIZE=${SNAP_SIZE}] "
                    # Subtract next snapshot from current one
                    local DISK_SIZE="$SNAP_DISK_SIZE"
                done

            done < <(echo "${VM_JSON}" | $JQ -c ".\"${VM_ID}\"[]")
        echo "\"]"
    done < <(echo "$1" | $JQ -c "[(
        .[].rsc_dfns[] | select(select(.rsc_dfn_props).rsc_dfn_props | from_entries | select(.\"Aux/one/DS_ID\"==\"$DS_ID\")) |
        {vmid: (.rsc_dfn_props | from_entries.\"Aux/one/VM_ID\"),
        disk_id: (.rsc_dfn_props | from_entries.\"Aux/one/DISK_ID\"),
        res: .rsc_name,
        props: ([.rsc_dfn_props[]| select(.key | startswith(\"Aux/one\"))])}
        )] |
        group_by(.vmid)[] | {(.[0].vmid): [.[] | {(.disk_id): {res: .res, props: .props}}]}")
}

#--------------------------------------------------------------------------------
# Getting volume size from linstor server
#   @param $1 resource name
#   @return volume size in kilobytes
#--------------------------------------------------------------------------------
linstor_vd_size() {
    $LINSTOR -m --output-version v0 volume-definition list | \
        $JQ -r ".[].rsc_dfns[]? |
        select(.rsc_name==\"${1}\").vlm_dfns[] | select(.vlm_nr==0).vlm_size"
}

#--------------------------------------------------------------------------------
# Read environment variables and generate keys for linstor commands
#   Gets environment variables:
#   - LS_CONTROLLERS
#   - REPLICAS_ON_SAME
#   - REPLICAS_ON_DIFFERENT
#   - AUTO_PLACE
#   - DO_NOT_PLACE_WITH
#   - DO_NOT_PLACE_WITH_REGEX
#   - LAYER_LIST
#   - PROVIDERS
#   - ENCRYPTION
#   Sets environment variables:
#   - LINSTOR
#   - VOL_CREATE_ARGS
#   - RES_CREATE_ARGS
#--------------------------------------------------------------------------------
linstor_load_keys() {
    if [ -n "$LS_CONTROLLERS" ]; then
        LINSTOR="$LINSTOR --controllers $LS_CONTROLLERS"
    fi
    if [ -n "$REPLICAS_ON_SAME" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --replicas-on-same $REPLICAS_ON_SAME"
    fi
    if [ -n "$REPLICAS_ON_DIFFERENT" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --replicas-on-different $REPLICAS_ON_DIFFERENT"
    fi
    if [ -n "$AUTO_PLACE" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --auto-place $AUTO_PLACE"
    fi
    if [ -n "$DO_NOT_PLACE_WITH" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --do-not-place-with $DO_NOT_PLACE_WITH"
    fi
    if [ -n "$DO_NOT_PLACE_WITH_REGEX" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --do-not-place-with-regex $DO_NOT_PLACE_WITH_REGEX"
    fi
    if [ -n "$LAYER_LIST" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --layer-list $LAYER_LIST"
    fi
    if [ -n "$PROVIDERS" ]; then
        RES_CREATE_ARGS="$RES_CREATE_ARGS --providers $PROVIDERS"
    fi
    if [ "$ENCRYPTION" = "yes" ]; then
        VOL_CREATE_ARGS="$VOL_CREATE_ARGS --encrypt"
    fi
}

#-------------------------------------------------------------------------------
# Gets the hosts list contains resource
#   @param $1 - the resource name (to search)
#   @return hosts list contains the resource
#-------------------------------------------------------------------------------
function linstor_get_hosts_for_res {
    local RES="$1"
    $LINSTOR -m --output-version v0 resource list -r $RES | \
        $JQ -r '.[].resources[]?.node_name' | \
        xargs
}

#-------------------------------------------------------------------------------
# Gets the hosts list contains resource
#   @param $1 - the resource name (to search)
#   @return hosts list contains the resource
#-------------------------------------------------------------------------------
function linstor_get_diskless_hosts_for_res {
    local RES="$1"
    $LINSTOR -m --output-version v0 resource list -r $RES | \
        $JQ -r '.[].resources[]? | select(.rsc_flags[]? |
        contains("DISKLESS")) | .node_name' | \
        xargs
}

#-------------------------------------------------------------------------------
# Gets snapshots for resource
#   @param $1 - the resource name (to search)
#   @param $2 - enable reverse sorting (1 - yes, 0 - no)
#   @return snapshot ID list for the resource
#-------------------------------------------------------------------------------
function linstor_get_snaps_for_res {
    local RES="$1"
    case "$2" in
        1) local SORT_FLAGS=nr ;;
        *) local SORT_FLAGS=n ;;
    esac

    $LINSTOR -m --output-version v0 snapshot list | \
        $JQ -r ".[].snapshot_dfns[]? | \
        select(.rsc_name==\"${RES}\") | .snapshot_name" | \
        $AWK -F- '$1 == "snapshot" && $2 ~ /^[0-9]+$/ {print $2}' | \
        sort -${SORT_FLAGS} | \
        xargs
}

#-------------------------------------------------------------------------------
# Gets the host contains volume to be used as bridge to talk to the storage system
# Implements a round robin for the bridges
#   @param $1 - the volume (to search)
#   @param $2 - host must contain the volume (1 - yes, 0 - no)
#   @param $3 - ID to be used to round-robin between host bridges. Random if
#   not defined
#   @return host to be used as bridge
#-------------------------------------------------------------------------------
function linstor_get_bridge_host {
    local RES="$1"
    local MUST_CONTAIN="${2:-0}"
    local RR_ID="$3"
    local HOSTS_ARRAY=()

    if [ -z "$BRIDGE_LIST" ]; then
        # Get online hosts
        local REDUCED_LIST="$(onehost list --no-pager --csv \
                --filter="STAT!=off,STAT!=err,STAT!=dsbl" --list=NAME,STAT | awk -F, 'NR>1{print $1}')"

        if [ -z "$REDUCED_LIST" ]; then
            error_message "'BRIDGE_LIST' is not specified, all other nodes are offline, error or disabled"
            exit -1
        fi
    else
        # Remove offline hosts
        local REDUCED_LIST=$(remove_off_hosts "$BRIDGE_LIST")
        if [ -z "$REDUCED_LIST" ]; then
            error_message "All hosts from 'BRIDGE_LIST' are offline, error or disabled"
            exit -1
        fi
    fi

    # Remove hosts not containing resource
    if [ -n "$RES" ]; then
        local RES_HOSTS="$(linstor_get_hosts_for_res $RES)"
        for HOST in $REDUCED_LIST; do
            if [[ " $RES_HOSTS " =~ " $HOST " ]] ; then
                local HOSTS_ARRAY+=($HOST)
            fi
        done
    fi

    # Fallback to hosts from BRIDGE_LIST
    local N_HOSTS=${#HOSTS_ARRAY[@]}
    if [ "$N_HOSTS" = 0 ]; then
        if [ "$MUST_CONTAIN" = "1" ]; then
            error_message "All hosts from 'BRIDGE_LIST' that contains $RES are offline, error or disabled"
            exit -1
        else
            local HOSTS_ARRAY=($REDUCED_LIST)
            local N_HOSTS=${#HOSTS_ARRAY[@]}
        fi
    fi

    # Select random host
    if [ -n "$RR_ID" ]; then
        local ARRAY_INDEX=$(($RR_ID % ${N_HOSTS}))
    else
        local ARRAY_INDEX=$((RANDOM % ${N_HOSTS}))
    fi

    echo ${HOSTS_ARRAY[$ARRAY_INDEX]}
}


#-------------------------------------------------------------------------------
# Gets the linstor resources with specific property assigned to it
#   @param $1 - property name (to search)
#   @param $2 - value
#   @return list of resources belongs to this key=value
#-------------------------------------------------------------------------------
function linstor_get_res_for_property {
    local PROPERTY="$1"
    local VALUE="$2"

    local RD_DATA="$($LINSTOR -m --output-version v0 resource-definition list)"
    if [ $? -ne 0 ]; then
        echo "Error getting resource-definition list"
        exit -1
    fi

    echo "$RD_DATA" | \
        $JQ -r ".[].rsc_dfns[]? | select(
        select(.rsc_dfn_props).rsc_dfn_props |
        from_entries | select(.\"${PROPERTY}\"==\"${VALUE}\"
        )).rsc_name"
}

#-------------------------------------------------------------------------------
# Executes a linstor command, if it fails returns error message but does not exit
# If a second parameter is present it is used as the error message when
# the command fails
#   @param $1 - the command (to execute)
#   @param $2 - error message (optional)
#-------------------------------------------------------------------------------
function linstor_exec_and_log_no_error {
    EXEC_LOG=`exec $LINSTOR -m --output-version v0 $1 2>&1`
    EXEC_LOG_RC=$?

    EXEC_LOG_ERR=$(echo "$EXEC_LOG" | \
        $JQ -r '.[] | select(.error_report_ids) |
        .message + " Error reports: [ " + (.error_report_ids | join(", ")) + " ]"')

    if [ -z "$EXEC_LOG_ERR" ]; then
        EXEC_LOG_ERR="$EXEC_LOG"
    else
        EXEC_LOG_RC=1
    fi

    if [ $EXEC_LOG_RC -ne 0 ]; then
        error_message "Command \"linstor $1\" failed: $EXEC_LOG_ERR"
        return $EXEC_LOG_RC
    fi
}

#-------------------------------------------------------------------------------
# Executes a linstor command, if it fails returns error message and exits
# If a second parameter is present it is used as the error message when
# the command fails
#   @param $1 - the command (to execute)
#   @param $2 - error message (optional)
#-------------------------------------------------------------------------------
function linstor_exec_and_log {
    linstor_exec_and_log_no_error "$@"
    EXEC_LOG_RC=$?

    if [ $EXEC_LOG_RC -ne 0 ]; then
        exit $EXEC_LOG_RC
    fi
}

#-------------------------------------------------------------------------------
# Cleans up created linstor resources and resource-definitions
#   Gets environment variables:
#   - LINSTOR_CLEANUP_RD
#   - LINSTOR_CLEANUP_R
#   - LINSTOR_CLEANUP_SNAPSHOT
#-------------------------------------------------------------------------------
function linstor_cleanup_trap {
    for RES in $LINSTOR_CLEANUP_RD; do
        linstor_exec_and_log_no_error \
            "resource-definition delete $RES"
    done

    for RES_SNAPSHOT in $LINSTOR_CLEANUP_SNAPSHOT; do
        local RES=${RES_SNAPSHOT%%:*}
        local SNAPSHOT=${RES_SNAPSHOT##*:}
        linstor_exec_and_log_no_error \
            "snapshot delete $RES $SNAPSHOT"
    done

    for NODE_RES in $LINSTOR_CLEANUP_RES; do
        if ! [[ " $LINSTOR_CLEANUP_RD " =~ " $RES " ]]; then
            break
        fi
        local NODE=${NODE_RES%%:*}
        local RES=${NODE_RES##*:}
        linstor_exec_and_log_no_error \
            "resource delete $NODE $RES --async"
    done
}
