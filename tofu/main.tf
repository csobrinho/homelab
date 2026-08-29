# Adapted from https://github.com/onedr0p/home-ops
#
# Provisions the Talos control-plane VMs on Proxmox. Talos machine config is NOT
# managed here - it is rendered and applied with `just talos apply-node <node>`
# once a VM is up on the Image Factory ISO.

locals {
  talos_iso_file_name = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}.iso"
  talos_iso_url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/${var.talos_image}"
}

# Pull the schematic ISO straight onto Proxmox storage via the PVE download-url API.
resource "proxmox_download_file" "talos" {
  content_type = "iso"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  file_name    = local.talos_iso_file_name
  url          = local.talos_iso_url

  # The schematic ID already pins the contents; never silently re-download.
  overwrite = false
}

resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = var.nodes

  name        = each.key
  description = "Talos control-plane node - managed by OpenTofu (tofu/)"
  tags        = var.vm_tags
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id

  machine         = var.machine_type
  bios            = var.bios
  scsi_hardware   = "virtio-scsi-single"
  on_boot         = var.start_on_boot
  stop_on_destroy = true

  agent {
    enabled = var.agent_enabled
  }

  cpu {
    cores = var.cpu_cores
    type  = var.cpu_type
    numa  = var.cpu_numa
  }

  memory {
    dedicated = var.memory
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
      file_format  = "raw"
    }
  }

  disk {
    datastore_id = var.vm_datastore_id
    interface    = "scsi0"
    size         = var.disk_size
    iothread     = true
    discard      = "on"
    ssd          = true
    file_format  = "raw"
  }

  cdrom {
    file_id   = "${proxmox_download_file.talos.datastore_id}:iso/${proxmox_download_file.talos.file_name}"
    interface = "ide3"
  }

  # Empty disk on first boot -> falls through to the ISO, which installs Talos to
  # scsi0; subsequent boots come off scsi0 directly.
  boot_order = ["scsi0", "ide3"]

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
