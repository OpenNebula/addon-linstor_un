# Unofficial Linstor Storage Driver

## Requirements

* Installed `jq` and `linstor` on the OpenNebula frontend.
* Configured linstor cluster

## Installation

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

## Configuration

Example images datastore:

```
NAME="linstor-images"
TYPE="IMAGE_DS"
STORAGE_POOL="data"
AUTO_PLACE="2"
BRIDGE_LIST="node1 node2 node3"
DISK_TYPE="BLOCK"
DS_MAD="linstor_un"
TM_MAD="linstor_un"
```

Example system datastore:

```
NAME="linstor-system"
TYPE="SYSTEM_DS"
STORAGE_POOL="data"
AUTO_PLACE="2"
CHECKPOINT_AUTO_PLACE="1"
BRIDGE_LIST="node1 node2 node3"
DISK_TYPE="BLOCK"
TM_MAD="linstor_un"
```
