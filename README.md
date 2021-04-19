# Linstor Storage Driver (unofficial)

## Description

Community driven full-feature Linstor storage driver for OpenNebula

Read the [**blog article**](https://opennebula.org/linstor_un-new-storage-driver-for-opennebula-2/) for more details...

### Comparsion to addon-linstor

Why not simply use the [official Linstor driver](https://github.com/OpenNebula/addon-linstor)? I was trying an official Linstor driver for OpenNebula, before I made a decidion to write my own implementation. And I didn't like it because of reasons, that are mostly described below

* Bash-written.
  Unlike official Linstor driver which is written in python, this driver is written in bash. Any driver action is just a conventional bash script, which is calling standard shell-commands, meaning these scripts can be easily updated or extended.
* Uses OpenNebula native library
  This driver uses standard OpenNebula library which provides simplicity developing and debugging driver actions, e.g. you will always see what exact command was unsuccessful from the VM log, if something went wrong.
* Does not requires external dependings.
  Official driver needs configured linstor-client and extra python-bindings on every compute node. This driver has a central managment model from the OpenNebula frontend node, so it requires only `jq` and `linstor-client` installed on the frontend node, and no external components on compute nodes. It's also worth noting, that you still need linstor-satellite and drbd9 module to build linstor-cluster.
* Usually supports newer versions of OpenNebula.
* Can work with any backend, even without snapshots support.

## Compatibility

This add-on is compatible with:

* OpenNebula 5.8+
* Linstor server 1.7.0+
* Linstor client 1.1.1+

## OpenNebula Installation

### Requirements

* Installed `jq` and `linstor` on the OpenNebula frontend.
* Configured Linstor cluster and access to it from the OpenNebula frontend server.
* All OpenNebula hosts should have DRBD9 module installed and be registred in Linstor cluster as satellite nodes.

### Installation steps

* Copy [vmm overriders](vmm/kvm) to `/var/lib/one/remotes/vmm/kvm/`
* Copy [datastore drivers](datastore/linstor_un) to `/var/lib/one/remotes/datastore/linstor_un`
* Copy [transport drivers](tm/linstor_un) to `/var/lib/one/remotes/tm/linstor_un`
* Move [datastore config](datastore/linstor_un/linstor_un.conf) to `/var/lib/one/remotes/etc/datastore/linstor_un/linstor_un.conf`

*Only for OpenNebula 5.10 and below*:
* Uncomment `LEGACY_MONITORING=1` option in `linstor_un.conf` 

#### Update **oned.conf**:

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
    NAME = "linstor_un", LN_TARGET = "NONE", CLONE_TARGET = "SYSTEM", SHARED = "yes",
    DS_MIGRATE = "YES", ALLOW_ORPHANS="yes"
]
```

Add new **DS_MAD_CONF** section:
```
DS_MAD_CONF = [
    NAME = "linstor_un", PERSISTENT_ONLY = "NO",
    MARKETPLACE_ACTIONS = "export"
]
```

#### Update **vmm_execrc**:

- add `kvm-linstor_un` to the LIVE_DISK_SNAPSHOTS list

```diff
-LIVE_DISK_SNAPSHOTS="kvm-qcow2 kvm-ceph"
+LIVE_DISK_SNAPSHOTS="kvm-qcow2 kvm-ceph kvm-linstor_un"
```

## LINSTOR Configuration

* Install Linstor-satellite and DRBD9 kernel module on all your compute nodes.
* Nodes in linstor must have same name like for OpenNebula hosts.
* Linstor-client should be installed and working on control-plane nodes.
* Create Resource group:
  ```
  linstor resource-group create opennebula --place-count 2 --storage-pool thinlvm
  linstor volume-group create opennebula
  ```
  Resource group must have storage-pool assigned and single volume-group created.

## OpenNebula Configuration

To use your Linstor cluster with the OpenNebula, you need to define a System and Image datastores. Each Image/System Datastore pair will share same following Linstor configuration attributes:

| Attribute                  | Description                                                                                                      | Mandatory            |
|----------------------------|------------------------------------------------------------------------------------------------------------------|----------------------|
| `NAME`                     | The name of the datastore                                                                                        | **YES**              |
| `CLONE_MODE`               | `snapshot` - will create snapshot for instantiate VMs. `copy` - create full copy of image, this is default mode. | NO                   |
| `BRIDGE_LIST`              | Space separated hosts list used for transfer operations. Copy data between images and etc. Default: all hosts.   | NO                   |
| `LS_CONTROLLERS`           | Comma separated linstor controllers list for establish connection.                                               | NO                   |
| `LS_CERTFILE`              | SSL certificate file.                                                                                            | NO                   |
| `LS_KEYFILE`               | SSL key file.                                                                                                    | NO                   |
| `LS_CAFILE`                | SSL CA certificate file.                                                                                         | NO                   |
| `RESOURCE_GROUP`           | Resource group to spawn the resources.                                                                           | **YES** <sup>1</sup> |
| `NODE_LIST`                | Space separated hosts list to place replicas. Replicas will always be created on all these hosts.                | **YES** <sup>1</sup> |
| `LAYER_LIST`               | Comma separated layer list to place replicas.                                                                    | NO                   |
| `PROVIDERS`                | Comma separated providers list to place replicas.                                                                | NO                   |
| `REPLICAS_ON_SAME`         | Space separated aux-properties list to always place replicas on hosts with same aux-property.                    | NO                   |
| `REPLICAS_ON_DIFFERENT`    | Space separated aux-properties list to always place replicas on hosts with different aux-property.               | NO                   |
| `REPLICA_COUNT`            | Number of replicas for creating new volumes.                                                                     | **YES** <sup>1</sup> |
| `CHECKPOINT_REPLICA_COUNT` | Number of replicas for save checkpoint file for suspend and offline migration process.                           | NO                   |
| `DO_NOT_PLACE_WITH`        | Space separated resources list to avid placing replicas on same place with them.                                 | NO                   |
| `DO_NOT_PLACE_WITH_REGEX`  | Regular expression to avoid placing replicas on same place with targeted resources.                              | NO                   |
| `STORAGE_POOL`             | Space separated storage pool names to place replicas.                                                            | **YES** <sup>2</sup> |
| `DISKLESS_POOL`            | Diskless pool to place diskless replicas. Default: `DfltDisklessStorPool`.                                       | NO                   |
| `PREFER_NODE`              | `yes` - try to place and copy the data on the node that will afterwards be used by the VM                        | NO                   |
| `ENCRYPTION`               | `yes` - will enable encryption during volume creation.                                                           | NO                   |

*<sup>1</sup> - only one attribute required*  
*<sup>2</sup> - required if no RESOURCE_GROUP specified*

> **Note**: You may add another Image and System Datastores pointing to other pools with different allocation/replication policies in Linstor.

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

```bash
cat > images-ds.conf <<EOT
NAME="linstor-images"
TYPE="IMAGE_DS"
RESOURCE_GROUP="opennebula"
DISK_TYPE="BLOCK"
DS_MAD="linstor_un"
TM_MAD="linstor_un"
RESTRICTED_DIRS=/
SAFE_DIRS=/var/tmp
EOT

onedatastore create images-ds.conf
```

### Create a System Datastore

System Datastore also requires these attributes:

| Attribute | Description  | Mandatory |
|-----------|--------------|-----------|
| `TYPE`    | `SYSTEM_DS`  | **YES**   |
| `TM_MAD`  | `linstor_un` | **YES**   |

Create a System Datastore in Sunstone or through the CLI, for example:

```bash
cat > system-ds.conf <<EOT
NAME="linstor-system"
TYPE="SYSTEM_DS"
STORAGE_POOL="data"
RESOURCE_GROUP="opennebula"
PREFER_NODE="yes"
CHECKPOINT_REPLICA_COUNT="1"
TM_MAD="linstor_un"
EOT

onedatastore create system-ds.conf
```

## Development

To contribute bug patches or new features, you can use the github Pull Request model. It is assumed that code and documentation are contributed under the Apache License 2.0. 

More info:
* [How to Contribute](http://opennebula.org/addons/contribute/)
* Support: [OpenNebula user forum](https://forum.opennebula.org/c/support)
* Development: [OpenNebula developers forum](https://forum.opennebula.org/c/development)
* Issues Tracking: [Github issues](https://github.com/OpenNebula/addon-linstor_un/issues)

## Author

* Andrei Kvapil <[kvapss@gmail.com](mailto:kvapss@gmail.com)>
