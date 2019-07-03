# Linstor Storage Driver (unofficial)

## Description

Community driven full-feature Linstor storage driver for OpenNebula

### Comparsion to addon-linstor

Why not simple use [official Linstor driver](https://github.com/OpenNebula/addon-linstor)? I was try official Linstor driver for OpenNebula before I made decidion to write my own implementation. And I didn't liked it because of the some reasons, most of them are listed here:

* Bash-written.
  Unlike official Linstor driver which is written on python, this driver is written on bash. Any driver action is just a conventional bash script, which is calling standard shell-commands, these scripts can be easily updated or extended.
* Uses OpenNebula native library
  This driver uses standard OpenNebula library which is provides simplicity to developing and debugging driver actions, e.g. you will always see what exactly command was unsuccessful from the VM log, if something went wrong.
* Does not requires external dependings.
  Official driver requires configured linstor-client and extra python-bindings on every compute node. This driver have central managment model from the OpenNebula frontend node, so it requires only `jq` and `linstor-client` installed on the frontend node, and nothing external components installed on compute nodes. Worth noting you still need linstor-satellite and drbd9 module to build linstor-cluster.
* Can work with newer versions of OpenNebula and supports modern linstor features like **REPLICAS_ON_SAME**, **REPLICAS_ON_DIFFERENT** and others.
* Can work with any backend, even without snapshots support.

## Compatibility

This add-on is compatible with OpenNebula 5.6+

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
    NAME = "linstor_un", LN_TARGET = "NONE", CLONE_TARGET = "SELF", SHARED = "yes",
    DS_MIGRATE = "YES", DRIVER = "raw", ALLOW_ORPHANS="yes"
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

## OpenNebula Configuration

To use your Linstor cluster with the OpenNebula, you need to define a System and Image datastores. Each Image/System Datastore pair will share same following Linstor configuration attributes:

| Attribute                 | Description                                                                                                      | Mandatory |
|---------------------------|------------------------------------------------------------------------------------------------------------------|-----------|
| `NAME`                    | The name of the datastore                                                                                        | **YES**   |
| `CLONE_MODE`              | `snapshot` - will create snapshot for instantiate VMs. `copy` - create full copy of image, this is default mode. | NO        |
| `BRIDGE_LIST`             | Space separated hosts list used for transfer operations. Copy data between images and etc. Default: all hosts.   | NO        |
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
| `ENCRYPTION`              | `yes` - will enable encryption during volume creation.                                                           | NO        |

*\* - only one attribute required*

> **Note**: You may add another Image and System Datastores pointing to other pools with different allocation/replication policies in Linstor.


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
AUTO_PLACE="2"
CHECKPOINT_AUTO_PLACE="1"
TM_MAD="linstor_un"
EOT

onedatastore create system-ds.conf
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

```bash
cat > images-ds.conf <<EOT
NAME="linstor-images"
TYPE="IMAGE_DS"
STORAGE_POOL="data"
AUTO_PLACE="2"
DISK_TYPE="BLOCK"
DS_MAD="linstor_un"
TM_MAD="linstor_un"
EOT

onedatastore create images-ds.conf
```

## Development

To contribute bug patches or new features, you can use the github Pull Request model. It is assumed that code and documentation are contributed under the Apache License 2.0. 

More info:
* [How to Contribute](http://opennebula.org/addons/contribute/)
* Support: [OpenNebula user forum](https://forum.opennebula.org/c/support)
* Development: [OpenNebula developers forum](https://forum.opennebula.org/c/development)
* Issues Tracking: [Github issues](https://github.com/OpenNebula/addon-linstor_un/issues)

## Author

* [kvaps](mailto:kvapss@gmail.com)


