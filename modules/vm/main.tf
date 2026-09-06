resource "vsphere_virtual_machine" "this" {
  name              = var.name
  folder            = var.folder
  resource_pool_id  = var.resource_pool_id
  datastore_id      = var.datastore_id
  storage_policy_id = var.storage_policy_id

  num_cpus             = var.num_cpus
  num_cores_per_socket = 1
  memory               = var.memory_mb
  guest_id             = "ubuntu64Guest"
  firmware             = "efi"

  # Guard latency-sensitive roles (etcd) against noisy-neighbor contention.
  # A hard MHz cpu_reservation isn't used because it isn't portable across
  # heterogeneous hosts in the cluster; shares plus a full memory reservation
  # (no ballooning/swapping) is the more portable form of the same guarantee.
  memory_reservation = var.reserve_memory ? var.memory_mb : 0
  cpu_share_level    = var.cpu_share_level

  tags = var.tag_ids

  # Required by the vSphere CSI driver to reliably match a PV's backing VMDK
  # to the node it's attached to.
  enable_disk_uuid = true

  # The source template is stuck on vmx-10 (vSphere 5.5 era). vSphere CSI's
  # CNS disk-attach operation requires at least vmx-13. This was originally
  # pinned to 20 for headroom below this cluster's max (8.0.3 supports up to
  # vmx-21), but every VM ended up live at vmx-21 anyway after a rebuild --
  # Terraform doesn't support downgrading hardware version, so any apply
  # after that drift fails outright ("cannot downgrade virtual machine
  # hardware version") until the config is bumped to match. Set to 21 to
  # match; re-verify against `host.config.product` before raising further.
  hardware_version = 21

  # A hardware-version upgrade means a slower-than-usual first boot as the
  # guest renegotiates virtual devices; the provider's 5-minute default has
  # been observed to time out on this even though the VM comes up fine.
  wait_for_guest_net_timeout = 10

  network_interface {
    network_id = var.network_id
  }

  disk {
    label             = "disk0"
    size              = var.disk_gb
    thin_provisioned  = true
    storage_policy_id = var.storage_policy_id
  }

  # Required whenever the source template carries vApp properties in its OVF
  # (true of Ubuntu's official cloud-image OVAs) -- vSphere delivers the vApp
  # environment to the clone via an ISO mounted here, even though we don't
  # use vApp properties ourselves and rely on extra_config/GuestInfo instead.
  cdrom {
    client_device = true
  }

  clone {
    template_uuid = var.template_uuid
  }

  # The source template carries leftover vApp properties (a plaintext password
  # and an unrelated third-party SSH public key) from however it was originally
  # built. We don't use vApp properties for provisioning -- explicitly blank
  # these out on every clone rather than silently inheriting them.
  vapp {
    properties = {
      "password"    = ""
      "public-keys" = ""
    }
  }

  # Cloud-init picks these up via the VMware GuestInfo datasource. No vSphere
  # guest customization is used here on purpose -- cloud-init owns hostname,
  # networking, and provisioning.
  extra_config = {
    "guestinfo.userdata"          = base64encode(var.userdata)
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(var.metadata)
    "guestinfo.metadata.encoding" = "base64"
  }

  lifecycle {
    ignore_changes = [
      clone[0].template_uuid,
      # Terraform cannot safely apply a changed extra_config to a VM in-place
      # once RKE2/etcd is already running on it: cloud-init's per-instance
      # write_files/runcmd stage never re-runs on an existing disk (so the
      # new content wouldn't even take effect), and on a control-plane node
      # specifically, an in-place guestinfo update can make etcd come back
      # up believing it's a different member than the one etcd remembers --
      # "not a member of the etcd cluster", looping forever. Rolling out a
      # genuinely new extra_config onto an existing node is a deliberate,
      # one-at-a-time `terraform apply -replace=<this resource address>`,
      # never an in-place update -- see CLAUDE.md's etcd-identity rough edge.
      extra_config,
      # Confirmed live (pyvmomi read of config.vAppConfig.property right
      # after Terraform reported this reconfigure "complete"): the blank-out
      # above never actually persists -- vCenter keeps reporting the
      # template's original plaintext password and SSH key on every refresh
      # regardless. So every apply was reconfiguring all 9 VMs' vApp
      # properties for a change that silently never took effect, and a vApp
      # reconfigure forces a real guest OS reboot -- meaning every single
      # apply was rebooting the entire cluster for a no-op, which is what
      # was actually causing the cascade of "connection refused"/etcd-
      # timeout failures during unrelated installs this session, not
      # primarily the shared-datastore instability itself. Since the
      # blanking doesn't work via live reconfigure, the real fix is at the
      # template level (rebuild it without the baked-in credentials) --
      # not something to keep re-attempting here every apply.
      vapp,
      # Any CNS-attached (CSI/PVC-backed) volume on a node shows up on
      # refresh as an unmanaged extra `disk` block, which Terraform then
      # wants to relabel from its synthetic "orphaned_disk_N" name to
      # "<remove, keep disk>" -- previously treated as a harmless,
      # cosmetic-only bookkeeping fix (see CLAUDE.md's Registry section).
      # Confirmed NOT harmless: CNS actively attaches/detaches these disks
      # as pods get scheduled/rescheduled, so the disk list Terraform saw at
      # plan time can already be stale by apply time -- a real apply hit
      # exactly this and failed with "Invalid configuration for device '0'"
      # partway through, leaving all 6 worker VMs powered off. Ignoring the
      # whole `disk` list (not just the synthetic entries) is the only way
      # to express this with Terraform's ignore_changes syntax, since the
      # orphaned entries are dynamically many and can't be targeted by
      # index -- the tradeoff is that resizing the boot disk via var.disk_gb
      # no longer triggers a managed resize either, which this repo doesn't
      # currently do anywhere.
      disk,
    ]
  }
}
