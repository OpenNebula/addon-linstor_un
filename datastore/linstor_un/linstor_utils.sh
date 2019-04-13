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
# Attach diskless resource to the node if not exist
#   @param $1 the node
#   @param $2 the volume (to attach)
#   @param $3 the diskless storage pool name (optional)
#--------------------------------------------------------------------------------
linstor_attach_resource() {
    NODE="$1"
    RES="$2"
    DISKLESS_POOL="${3:-DfltDisklessStorPool}"
    ATTACH_CMD=$(cat <<EOF
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
#--------------------------------------------------------------------------------
linstor_detach_resource() {
    NODE="$1"
    RES="$2"
    DETACH_CMD=$(cat <<EOF
        set -e -o pipefail
    
        DISKLESS_RES=\$($LINSTOR -m resource list -r "$RES" -n "$NODE" | $JQ -r '.[].resources[] | select(.rsc_flags[] | contains("DISKLESS")) | .name')
        if [ -n "\$DISKLESS_RES" ]; then
            $LINSTOR resource delete "$NODE" "$RES" 
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
function get_destination_host_for_res {
    RES="$1"
    MUST_CONTAIN="${2:-0}"
    RR_ID="$3"

    IMAGE_NODES="$($LINSTOR -m resource list -r "${RES}" | $JQ -r '.[].resources[].node_name' | xargs)"
    unset REDUCED_LIST
    for NODE in $BRIDGE_LIST; do
        if [[ " $IMAGE_NODES " =~ " $NODE " ]] ; then
            REDUCED_LIST="$REDUCED_LIST $NODE"
        fi
    done

    REDUCED_LIST=$(remove_off_hosts "$REDUCED_LIST")
    if [ -n "$REDUCED_LIST" ]; then
        HOSTS_ARRAY=($REDUCED_LIST)
        N_HOSTS=${#HOSTS_ARRAY[@]}

        if [ -n "$RR_ID" ]; then
            ARRAY_INDEX=$(($RR_ID % ${N_HOSTS}))
        else
            ARRAY_INDEX=$((RANDOM % ${N_HOSTS}))
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
