# Provisions the Talos VMs on Proxmox (control plane + workers). Talos machine
# config itself is applied separately with `just talos apply-node <node>`.

locals {
  # Arch stem in the name: schematic ID is shared across arches, so without it
  # an arm64 ISO would collide with amd64 on Proxmox storage.
  talos_iso_file_name = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-${trimsuffix(var.talos_image, ".iso")}.iso"
  talos_iso_url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/${var.talos_image}"

  # One resource block for every VM; role just changes tags/sizing/hostpci.
  #   - var.nodes   : control plane, uniform sizing
  #   - var.workers : per-node cpu_cores/memory/disk_size overrides + hostpci
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

# Pulls the schematic ISO onto Proxmox storage. Only while var.attach_iso.
resource "proxmox_download_file" "talos" {
  count = var.attach_iso ? 1 : 0

  content_type = "iso"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  file_name    = local.talos_iso_file_name
  url          = local.talos_iso_url

  # Schematic ID already pins the contents; never silently re-download.
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

  # Headless, no console interaction - drop the emulated USB tablet.
  tablet_device = false

  # Never silently power-cycle a node - fail the apply instead (use -target
  # for an intentional one-at-a-time change).
  reboot_after_update = false

  agent {
    enabled = var.agent_enabled
  }

  cpu {
    cores = each.value.cpu_cores
    # "host": best perf, and required for GPU passthrough / NVIDIA driver.
    type = var.cpu_type
    numa = var.cpu_numa
  }

  memory {
    # No `floating` -> ballooning off, guest RAM pinned (required with hostpci).
    dedicated = each.value.memory
  }

  # Pairs with talos WatchdogTimerConfig: hypervisor resets the guest if the
  # Talos watchdog stops being petted.
  watchdog {
    enabled = true
    model   = "i6300esb"
    action  = "reset"
  }

  # No display needed; drops the VGA framebuffer device (and its idle-power
  # redraw cost) in favor of a plain serial console.
  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id = var.vm_datastore_id
      type         = "4m"
    }
  }

  # local-vms is a ZFS zvol pool; file_format left computed rather than pinned.
  disk {
    datastore_id = var.vm_datastore_id
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # GPU passthrough (workers only). Devices must already be bound to vfio-pci,
  # with IOMMU + above-4G decoding enabled. `mapping` (not `id`) so an API
  # token can set it.
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

  # First boot / rebuild only. q35 exposes ide0/ide2 only.
  dynamic "cdrom" {
    for_each = var.attach_iso ? [1] : []
    content {
      file_id   = "${proxmox_download_file.talos[0].datastore_id}:iso/${proxmox_download_file.talos[0].file_name}"
      interface = "ide2"
    }
  }

  # Falls through to the ISO on first boot; scsi0 directly after.
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

  # cpu.affinity is managed imperatively (`qm set`), not here - Proxmox
  # restricts writing it to password/ticket auth, API tokens can't set it at
  # all (bpg/terraform-provider-proxmox#1180), so tofu can never own this
  # field. Without ignore_changes, every apply tries to reconcile the live
  # value back to "unset" and fails the same way. See MIGRATION.md.
  lifecycle {
    ignore_changes = [cpu[0].affinity]
  }
}
