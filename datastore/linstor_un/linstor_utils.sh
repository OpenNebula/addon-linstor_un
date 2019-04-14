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
# Parse the output of linstor -m volume-definition list in json format and take
# size of the volume definition for the resource
# You **MUST** define JQ util before using this function
#   @param $1 the json output of the command
#   @param $2 resource name
#--------------------------------------------------------------------------------
linstor_vd_size() {
    echo "$1" | $JQ -r ".[].rsc_dfns[] |
	select(.rsc_name==\"${2}\").vlm_dfns[] |
        select(.vlm_nr==0).vlm_size"
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

#--------------------------------------------------------------------------------
# Deploy new volume on linstor
#   @param $1 the volume (to create)
#   @param $2 the size
#   Gets environment variables:
#   - VOL_CREATE_ARGS
#   - RES_CREATE_ARGS
#--------------------------------------------------------------------------------
linstor_deploy_volume() {
    local RES="$1"
    local SIZE="$2"

    if [ -z "$NODE_LIST" ] && [ -z "$AUTO_PLACE" ]; then
        error_message "Datastore template missing 'NODE_LIST' or 'AUTO_PLACE' attribute."
        exit -1
    fi

    local REGISTER_CMD=$(cat <<EOF
        set -e -o pipefail
    
        $LINSTOR resource-definition create "$RES"
        trap '$LINSTOR resource-definition delete "$RES" --async' EXIT
        ( exec $LINSTOR volume-definition create $VOL_CREATE_ARGS "$RES" "$SIZE" )
        ( exec $LINSTOR resource create $RES_CREATE_ARGS --storage-pool "$STORAGE_POOL" $NODE_LIST "$RES" )
        trap '' EXIT
EOF
)

    multiline_exec_and_log "$REGISTER_CMD" \
                    "Error registering $DST"


}

#--------------------------------------------------------------------------------
# Attach diskless resource to the node if not exist
#   @param $1 the node
#   @param $2 the volume (to attach)
#   @param $3 the diskless storage pool name (optional)
#--------------------------------------------------------------------------------
linstor_attach_volume() {
    local NODE="$1"
    local RES="$2"
    local DISKLESS_POOL="${3:-DfltDisklessStorPool}"
    local ATTACH_CMD=$(cat <<EOF
        set -e -o pipefail
    
        CREATED_RES=\$($LINSTOR -m resource list -r "$RES" -n "$NODE" | $JQ -r '.[].resources[].name')
        if [ -z "\$CREATED_RES"]; then
            $LINSTOR resource create -s "$DISKLESS_POOL" "$NODE" "$RES" 
        fi
EOF
)

    multiline_exec_and_log "$ATTACH_CMD" "Error attaching $RES on $NODE"
}

#--------------------------------------------------------------------------------
# Detach diskless resource from the node if exist and diskless
#   @param $1 the node
#   @param $2 the volume (to detach)
#   @param $3 async execution (1 - yes, 0 - no)
#--------------------------------------------------------------------------------
linstor_detach_volume() {
    local NODE="$1"
    local RES="$2"
    local ASYNC="${3:-0}"
    if [ "$ASYNC" -eq 1 ]; then
        local ASYNC_ARG="--async"
    fi
    local DETACH_CMD=$(cat <<EOF
        set -e -o pipefail
    
        DISKLESS_RES=\$($LINSTOR -m resource list -r "$RES" -n "$NODE" | $JQ -r '.[].resources[] | select(.rsc_flags[] | contains("DISKLESS")) | .name')
        if [ -n "\$DISKLESS_RES" ]; then
            $LINSTOR resource delete "$NODE" "$RES" $ASYNC_ARG
        fi
EOF
)
    multiline_exec_and_log "$DETACH_CMD" "Error detaching $RES from $NODE"

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

    local IMAGE_NODES="$($LINSTOR -m resource list -r "${RES}" | $JQ -r '.[].resources[].node_name' | xargs)"
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
