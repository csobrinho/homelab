# Adapted from https://github.com/onedr0p/home-ops

output "talos_iso" {
  description = "ISO file provisioned on Proxmox for the control-plane VMs to boot."
  value       = "${var.iso_datastore_id}:iso/${proxmox_download_file.talos.file_name}"
}

output "control_plane" {
  description = "Per-node facts. Use mac_address to create DHCP reservations / static leases."
  value = {
    for name, vm in proxmox_virtual_environment_vm.controlplane : name => {
      vm_id       = vm.vm_id
      node        = vm.node_name
      mac_address = one(vm.network_device).mac_address
    }
  }
}
