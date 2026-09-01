# Provisions the Talos VMs on Proxmox - control plane (var.nodes) and workers
# (var.workers). Talos machine config is NOT managed here; it is rendered and
# applied with `just talos apply-node <node>` once a VM is up on the Image
# Factory ISO.

locals {
  # Arch stem (metal-amd64) is part of the name: the schematic ID is the same for
  # every arch of a schematic, so without it an arm64 ISO would collide with the
  # amd64 one on Proxmox storage.
  talos_iso_file_name = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-${trimsuffix(var.talos_image, ".iso")}.iso"
  talos_iso_url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/${var.talos_image}"

  # Every VM is built from the same resource block below; role only changes the
  # tags, the sizing defaults, and whether PCI devices are passed through. Fold
  # both input maps into one normalised map so that block is written once.
  #   - var.nodes   : control plane, uniform sizing (the cpu_cores/memory/disk_size vars)
  #   - var.workers : per-node cpu_cores/memory/disk_size overrides + optional hostpci
  vms = merge(
    {
      for name, n in var.nodes : name => {
        role        = "control-plane"
        vm_id       = n.vm_id
        mac_address = n.mac_address
        tags        = var.vm_tags
        cpu_cores   = var.cpu_cores
        memory      = var.memory
        disk_size   = var.disk_size
        hostpci     = []
      }
    },
    {
      for name, w in var.workers : name => {
        role        = "worker"
        vm_id       = w.vm_id
        mac_address = w.mac_address
        tags        = var.worker_vm_tags
        cpu_cores   = coalesce(w.cpu_cores, var.worker_cpu_cores)
        memory      = coalesce(w.memory, var.worker_memory)
        disk_size   = coalesce(w.disk_size, var.worker_disk_size)
        hostpci     = w.hostpci
      }
    },
  )
}

# Pull the schematic ISO straight onto Proxmox storage via the PVE download-url API.
# Only while var.attach_iso is set - see the cdrom block and that variable.
resource "proxmox_download_file" "talos" {
  count = var.attach_iso ? 1 : 0

  content_type = "iso"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  file_name    = local.talos_iso_file_name
  url          = local.talos_iso_url

  # The schematic ID already pins the contents; never silently re-download.
  overwrite = false
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.vms

  name        = each.key
  description = "Talos ${each.value.role} node - managed by OpenTofu (tofu/)"
  tags        = each.value.tags
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id

  machine         = var.machine_type
  bios            = var.bios
  scsi_hardware   = "virtio-scsi-single"
  on_boot         = var.start_on_boot
  stop_on_destroy = true

  # Never let the provider silently power-cycle a node to apply a change - an
  # offline-requiring update fails the apply instead. On the control plane that
  # is what keeps etcd members going down one at a time, deliberately (use
  # -target); on a worker it keeps a reboot from yanking running workloads.
  reboot_after_update = false

  agent {
    enabled = var.agent_enabled
  }

  cpu {
    cores = each.value.cpu_cores
    # "host" (var.cpu_type default): best performance for the plain nodes, and
    # required for GPU passthrough / for the NVIDIA driver to see the real CPU.
    type = var.cpu_type
    numa = var.cpu_numa
  }

  memory {
    # No `floating` -> ballooning off, so guest RAM is pinned. Required for any
    # node with hostpci (VFIO locks the whole guest map anyway).
    dedicated = each.value.memory
  }

  # Pairs with talos WatchdogTimerConfig (/dev/watchdog0): the hypervisor resets
  # the guest if the Talos watchdog stops being petted.
  watchdog {
    enabled = true
    model   = "i6300esb"
    action  = "reset"
  }

  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id = var.vm_datastore_id
      type         = "4m"
    }
  }

  # local-vms is a ZFS mirror (zfspool): disks are raw zvols, so file_format is
  # left computed rather than pinned.
  disk {
    datastore_id = var.vm_datastore_id
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # GPU / PCI passthrough (workers only; empty for the control plane). Devices
  # must already be bound to vfio-pci on the Proxmox host, with IOMMU + "above
  # 4G decoding" / ReBAR enabled in its BIOS. `mapping` (a PVE resource mapping)
  # rather than `id` so an API token can set it - see var.workers.
  dynamic "hostpci" {
    for_each = { for h in each.value.hostpci : h.device => h }
    content {
      device  = hostpci.value.device
      mapping = hostpci.value.mapping
      id      = hostpci.value.id
      pcie    = hostpci.value.pcie
      rombar  = hostpci.value.rombar
    }
  }

  # Only while var.attach_iso is set (first boot / node rebuild). q35 exposes
  # ide0/ide2 only.
  dynamic "cdrom" {
    for_each = var.attach_iso ? [1] : []
    content {
      file_id   = "${proxmox_download_file.talos[0].datastore_id}:iso/${proxmox_download_file.talos[0].file_name}"
      interface = "ide2"
    }
  }

  # Empty disk on first boot -> falls through to the ISO, which installs Talos to
  # scsi0; subsequent boots come off scsi0 directly. Once var.attach_iso is off
  # there is no ide2 to list.
  boot_order = var.attach_iso ? ["scsi0", "ide2"] : ["scsi0"]

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    vlan_id     = var.network_vlan_id
    mtu         = var.network_mtu
    mac_address = each.value.mac_address
  }

  operating_system {
    type = "l26"
  }
}
