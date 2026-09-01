# Adapted from https://github.com/onedr0p/home-ops

output "talos_iso" {
  description = "ISO file provisioned on Proxmox for the VMs to boot; null once var.attach_iso is off."
  value       = var.attach_iso ? "${var.iso_datastore_id}:iso/${proxmox_download_file.talos[0].file_name}" : null
}

output "control_plane" {
  description = "Per-node facts for the control plane. Use mac_address to create DHCP reservations / static leases."
  value = {
    for name, vm in proxmox_virtual_environment_vm.node : name => {
      vm_id       = vm.vm_id
      node        = vm.node_name
      mac_address = one(vm.network_device).mac_address
    } if local.vms[name].role == "control-plane"
  }
}

output "workers" {
  description = "Per-node facts for the workers. Use mac_address to create DHCP reservations / static leases."
  value = {
    for name, vm in proxmox_virtual_environment_vm.node : name => {
      vm_id       = vm.vm_id
      node        = vm.node_name
      mac_address = one(vm.network_device).mac_address
    } if local.vms[name].role == "worker"
  }
}
