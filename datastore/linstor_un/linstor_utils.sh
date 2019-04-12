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
