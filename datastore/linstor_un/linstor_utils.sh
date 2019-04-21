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
# Parse the output of linstor -m storagepools list in json format and generates a
# monitor string for linstor pool.
# You **MUST** define JQ util before using this function
#   @param $1 the json output of the command
#--------------------------------------------------------------------------------
linstor_monitor_storpool() {
    echo "$1" | $JQ -r '.[].stor_pools[].free_space | .free_capacity, .total_capacity' \
        | $AWK '{if (NR % 2) {free+=$1/1024} else {total+=$1/1024}};
        END{ printf "USED_MB=%0.f\nTOTAL_MB=%0.f\nFREE_MB=%0.f\n", total-free, total, free }'
}


#--------------------------------------------------------------------------------
# Getting volume size from linstor server
#   @param $1 resource name
#   @return volume size in kilobytes
#--------------------------------------------------------------------------------
linstor_vd_size() {
    $LINSTOR -m volume-definition list | $JQ -r ".[].rsc_dfns[] |
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
    $LINSTOR -m resource list -r $RES | \
        $JQ -r '.[].resources[].node_name' | \
        xargs
}

#-------------------------------------------------------------------------------
# Gets the hosts list contains resource
#   @param $1 - the resource name (to search)
#   @return hosts list contains the resource
#-------------------------------------------------------------------------------
function linstor_get_diskless_hosts_for_res {
    local RES="$1"
    $LINSTOR -m resource list -r $RES | \
        $JQ -r '.[].resources[].node_name' | \
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
function linstor_get_host_for_res {
    local RES="$1"
    local MUST_CONTAIN="${2:-0}"
    local RR_ID="$3"

    local IMAGE_NODES="$(linstor_get_hosts_for_res $RES)"
    unset REDUCED_LIST
    for NODE in $BRIDGE_LIST; do
        if [[ " $IMAGE_NODES " =~ " $NODE " ]] ; then
            local REDUCED_LIST="$REDUCED_LIST $NODE"
        fi
    done

    local REDUCED_LIST=$(remove_off_hosts "$REDUCED_LIST")
    if [ -n "$REDUCED_LIST" ]; then
        local HOSTS_ARRAY=($REDUCED_LIST)
        local N_HOSTS=${#HOSTS_ARRAY[@]}

        if [ -n "$RR_ID" ]; then
            local ARRAY_INDEX=$(($RR_ID % ${N_HOSTS}))
        else
            local ARRAY_INDEX=$((RANDOM % ${N_HOSTS}))
        fi

        echo ${HOSTS_ARRAY[$ARRAY_INDEX]}
    else
        if [ "$MUST_CONTAIN" = "1" ]; then
            error_message "All hosts from 'BRIDGE_LIST' that contains $RES are offline, error or disabled"
            exit -1
        else
	    get_destination_host $RR_ID
        fi
    fi
}


#-------------------------------------------------------------------------------
# Gets the resources list used for the virtual machine
#   @param $1 - the vmid (to search)
#   @return list of resources belongs to the VM
#-------------------------------------------------------------------------------
function linstor_get_res_for_vmid {
    local VMID="$1"
    local RD_DATA="$($LINSTOR -m resource-definition list)"
    if [ $? -ne 0 ]; then
        echo "Error getting resource-definition list"
        exit -1
    fi

    echo "$RD_DATA" | \
        $JQ -r ".[].rsc_dfns[].rsc_name | \
        select(. | test(\"^one-vm-${VMID}-disk-[0-9]+$\"))"
}



function linstor_exec_and_log {
    message=$2

    EXEC_LOG_ERR=`$LINSTOR $@ 2>&1 1>/dev/null`
    EXEC_LOG_RC=$?

    if [ $EXEC_LOG_RC -ne 0 ]; then
        log_error "Command \"$1\" failed: $EXEC_LOG_ERR"

        if [ -n "$2" ]; then
            error_message "$2"
        else
            error_message "Error executing $1: $EXEC_LOG_ERR"
        fi
        exit $EXEC_LOG_RC
    fi
}

#-------------------------------------------------------------------------------
# Executes a linstor command, if it fails returns error message but does not exit
# If a second parameter is present it is used as the error message when
# the command fails
#   @param $1 - the command (to execute)
#   @param $2 - error message (optional)
#-------------------------------------------------------------------------------
function linstor_exec_and_log_no_error {
    EXEC_LOG=`exec $LINSTOR -m $1 2>&1`
    EXEC_LOG_RC=$?

    EXEC_LOG_ERR=$(echo "$EXEC_LOG" | \
        $JQ -r '.[] | select(.error_report_ids) | \
        .message + \
        " Error reports: [ " + (.error_report_ids | join(", ")) + " ]"')

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
#-------------------------------------------------------------------------------
function linstor_cleanup_trap {
    for RES in $LINSTOR_CLEANUP_RD; do
        linstor_exec_and_log_no_error \
            "resource-definition delete $RES --async"
    done

    for NODE_RES in $LINSTOR_CLEANUP_R; do
        if ! [[ " $LINSTOR_CLEANUP_RD " =~ " $RES " ]]; then
            break
        fi
        NODE=${NODE_RES%%:*}
        RES=${NODE_RES##*:}
        linstor_exec_and_log_no_error \
            "resource delete $NODE $RES --async"
    done
}
