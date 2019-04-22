# Unofficial Linstor Storage Driver

## Requirements

* Installed `jq` and `linstor` on the OpenNebula frontend.
* Configured linstor cluster and access to it from OpenNebula frontend.

## OpenNebula Installation

* Copy [vmm overriders](vmm/kvm) to `/var/lib/one/remotes/vmm/kvm/`
* Copy [datastore drivers](datastore/linstor_un) to `/var/lib/one/remotes/datastore/linstor_un`
* Copy [transport drivers](tm/linstor_un) to `/var/lib/one/remotes/tm/linstor_un`
* Move [datastore config](datastore/linstor_un/linstor_un.conf) to `/var/lib/one/remotes/etc/datastore/linstor_un/linstor_un.conf`

### Update **oned.conf**:

Modify **VM_MAD** section for the **kvm** driver:
- add `save=save_linstor_un` and `restore=restore_linstor_un` overrides to local actions.

```diff
 VM_MAD = [
     NAME           = "kvm",
-    ARGUMENTS      = "-t 15 -r 0 kvm",
+    ARGUMENTS      = "-t 15 -r 0 kvm -l save=save_linstor_un,restore=restore_linstor_un",
 ]
```

Modify **TM_MAD** section for the **one_tm** driver:
- add `linstor_un` transfer drivers list.

```diff
 TM_MAD = [
     EXECUTABLE = "one_tm",
-    ARGUMENTS = "-t 15 -d dummy,lvm,shared,fs_lvm,qcow2,ssh,ceph,dev,vcenter,iscsi_libvirt"
+    ARGUMENTS = "-t 15 -d dummy,lvm,shared,fs_lvm,qcow2,ssh,ceph,dev,vcenter,iscsi_libvirt,linstor_un"
 ]
```

Modify **DATASTORE_MAD** section for the **one_datastore** driver:
- add `linstor_un` to datastore mads and system datastore tm drivers list.

```diff
 DATASTORE_MAD = [
     EXECUTABLE = "one_datastore",
-    ARGUMENTS  = "-t 15 -d dummy,fs,lvm,ceph,dev,iscsi_libvirt,vcenter -s shared,ssh,ceph,fs_lvm,qcow2,vcenter"
+    ARGUMENTS  = "-t 15 -d dummy,fs,lvm,ceph,dev,iscsi_libvirt,vcenter,linstor_un -s shared,ssh,ceph,fs_lvm,qcow2,vcenter,linstor_un"
 ]
```

Add new **TM_MAD_CONF** section:

```
TM_MAD_CONF = [
    name = "linstor_un", ln_target = "NONE", clone_target = "SELF", shared = "yes", ALLOW_ORPHANS="yes"
]
```

Add new **DS_MAD_CONF** section:
```
DS_MAD_CONF = [
    NAME = "linstor_un", REQUIRED_ATTRS = "BRIDGE_LIST", PERSISTENT_ONLY = "NO",
    MARKETPLACE_ACTIONS = "export"
]
```

### Update **vmm_execrc**:

- add `kvm-linstor_un` to the LIVE_DISK_SNAPSHOTS list

```diff
-LIVE_DISK_SNAPSHOTS="kvm-qcow2 kvm-ceph"
+LIVE_DISK_SNAPSHOTS="kvm-qcow2 kvm-ceph kvm-linstor_un"
```

## OpenNebula Configuration

To use your Ceph cluster with the OpenNebula, you need to define a System and Image datastores. Each Image/System Datastore pair will share same following Ceph configuration attributes:

| Attribute                 | Description                                                                                                      | Mandatory |
|---------------------------|------------------------------------------------------------------------------------------------------------------|-----------|
| `NAME`                    | The name of the datastore                                                                                        | **YES**   |
| `CLONE_MODE`              | `snapshot` - will create snapshot for instantiate VMs. `copy` - create full copy of image, this is default mode. | NO        |
| `BRIDGE_LIST`             | Space separated hosts list used for transfer operations. Copy data between images and etc.                       | **YES**   |
| `LS_CONTROLLERS`          | Comma separated linstor controllers list for establish connection.                                               | NO        |
| `NODE_LIST`               | Space separated hosts list to place replicas. Replicas will always be created on all these hosts.                | **YES** * |
| `LAYER_LIST`              | Comma separated layer list to place replicas.                                                                    | NO        |
| `PROVIDERS`               | Comma separated providers list to place replicas.                                                                | NO        |
| `REPLICAS_ON_SAME`        | Space separated aux-properties list to always place replicas on hosts with same aux-property.                    | NO        |
| `REPLICAS_ON_DIFFERENT`   | Space separated aux-properties list to always place replicas on hosts with different aux-property.               | NO        |
| `AUTO_PLACE`              | Number of replicas for creating new volumes.                                                                     | **YES** * |
| `CHECKPOINT_AUTO_PLACE`   | Number of replicas for save checkpoint file for suspend and offline migration process.                           | NO        |
| `DO_NOT_PLACE_WITH`       | Space separated resources list to avid placing replicas on same place with them.                                 | NO        |
| `DO_NOT_PLACE_WITH_REGEX` | Regular expression to avoid placing replicas on same place with targeted resources.                              | NO        |
| `STORAGE_POOL`            | Storage pool name to place replicas.                                                                             | **YES**   |
| `DISKLESS_POOL`           | Diskless pool to place diskless replicas. Default: `DfltDisklessStorPool`.                                       | NO        |
| `ENCRYPTION`              | `yes` - will enable encryption during volume creation. | NO                                                      |           |

*\* - only one attribute required*

> **Note**: You may add another Image and System Datastores pointing to other pools with different allocation/replication policies in Linstor.


### Create a System Datastore

System Datastore also requires these attributes:

| Attribute | Description  | Mandatory |
|-----------|--------------|-----------|
| `TYPE`    | `SYSTEM_DS`  | **YES**   |
| `TM_MAD`  | `linstor_un` | **YES**   |

Create a System Datastore in Sunstone or through the CLI, for example:

```
cat > system-ds.conf <<EOT
NAME="linstor-system"
TYPE="SYSTEM_DS"
STORAGE_POOL="data"
AUTO_PLACE="2"
CHECKPOINT_AUTO_PLACE="1"
BRIDGE_LIST="node1 node2 node3"
DISK_TYPE="BLOCK"
TM_MAD="linstor_un"
EOF

onedatastore create -f system-ds.conf
```

### Create an Image Datastore

Apart from the previous attributes, that need to be the same as the associated System Datastore, the following can be set for an Image Datastore:


| Attribute     | Description                                           | Mandatory |
|---------------|-------------------------------------------------------|-----------|
| `NAME`        | The name of the datastore                             | **YES**   |
| `DS_MAD`      | `linstor_un`                                          | **YES**   |
| `TM_MAD`      | `linstor_un`                                          | **YES**   |
| `DISK_TYPE`   | `BLOCK`                                               | **YES**   |
| `STAGING_DIR` | Default path for image operations in the bridges      | NO        |

An example of datastore:

```
cat > images-ds.conf <<EOT
NAME="linstor-images"
TYPE="IMAGE_DS"
STORAGE_POOL="data"
AUTO_PLACE="2"
BRIDGE_LIST="node1 node2 node3"
DISK_TYPE="BLOCK"
DS_MAD="linstor_un"
TM_MAD="linstor_un"
EOF

onedatastore create -f system-ds.conf
```
