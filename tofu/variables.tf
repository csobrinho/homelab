# Adapted from https://github.com/onedr0p/home-ops

variable "proxmox_node" {
  description = "Proxmox VE node that hosts the control-plane VMs."
  type        = string
  default     = "infra-vm"
}

variable "nodes" {
  description = <<-EOT
    Control-plane VMs to create, keyed by hostname. Each key MUST match a
    talos/nodes/controlplane/<key>.yaml.j2 file. mac_address is optional; when
    omitted Proxmox generates one and it is pinned in (encrypted) state, so it
    stays stable across re-applies. Set it explicitly if you want to create the
    DHCP reservation before the VM exists.

    No default: terraform.tfvars is the single source of truth for the node set.
  EOT
  type = map(object({
    vm_id       = number
    mac_address = optional(string)
  }))
}

variable "cpu_cores" {
  description = "vCPUs per control-plane VM."
  type        = number
  default     = 4
}

variable "cpu_type" {
  description = "QEMU CPU type. 'host' for best performance; 'x86-64-v3' for live-migration portability across mixed hardware."
  type        = string
  default     = "host"
}

variable "cpu_numa" {
  description = "Expose NUMA topology to the guest."
  type        = bool
  default     = true
}

variable "memory" {
  description = "RAM per control-plane VM, in MiB."
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "System disk size per control-plane VM, in GiB. Talos installs here; etcd lives on it."
  type        = number
  default     = 64
}

variable "vm_datastore_id" {
  description = "Proxmox datastore for the VM system disk (and EFI disk when bios = ovmf)."
  type        = string
  default     = "local-vms"
}

variable "iso_datastore_id" {
  description = "Proxmox datastore that holds ISO images. Must allow content type 'iso'."
  type        = string
  default     = "local"
}

variable "attach_iso" {
  description = <<-EOT
    Download the Image Factory ISO and attach it as a CD-ROM. Needed only for
    first boot / rebuilding a node from an empty disk. Once every node is
    installed, set false: `tofu apply` then deletes the ISO from Proxmox storage
    and detaches the drive, and Talos version bumps (done with `just talos
    upgrade-node`, which pulls the installer from the factory directly) no longer
    touch these VMs. To rebuild one node later: set true, `tofu apply -target`
    that VM, re-image, set false again.
  EOT
  type        = bool
  default     = true
}

variable "network_bridge" {
  description = "Proxmox bridge for the VM NIC."
  type        = string
  default     = "vmbr0"
}

variable "network_vlan_id" {
  description = "VLAN tag for the VM NIC. null = untagged / bridge-native VLAN."
  type        = number
  default     = null
}

variable "network_mtu" {
  description = "NIC MTU (VirtIO only). 1 = inherit the bridge MTU. Use 9000 only if the whole path is jumbo-clean."
  type        = number
  default     = 1
}

variable "bios" {
  description = "Firmware: 'ovmf' (UEFI, also provisions an EFI disk) or 'seabios' (legacy). Cannot be changed on an existing VM."
  type        = string
  default     = "ovmf"

  validation {
    condition     = contains(["seabios", "ovmf"], var.bios)
    error_message = "bios must be 'seabios' or 'ovmf'."
  }
}

variable "machine_type" {
  description = "QEMU machine type."
  type        = string
  default     = "q35"
}

variable "agent_enabled" {
  description = <<-EOT
    Enable the QEMU guest-agent integration. Requires the
    'siderolabs/qemu-guest-agent' system extension in the Talos schematic (it is
    in talos/schematic.yaml.j2). Set false only if that extension is dropped, or
    `tofu apply` hangs waiting for an agent that never answers.
  EOT
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start the VM automatically when the Proxmox node boots."
  type        = bool
  default     = true
}

variable "vm_tags" {
  description = "Tags applied to every control-plane VM in the Proxmox UI."
  type        = list(string)
  default     = ["talos", "kubernetes", "controlplane", "opentofu"]
}

variable "talos_version" {
  description = <<-EOT
    Talos release for the Image Factory ISO, e.g. v1.14.0-rc.2. Read from
    talos/versions.yaml (.version.talos) and injected as TF_VAR_talos_version by
    `just tofu ...` so that file stays the single source of truth (shared with
    talos/cluster.yaml.j2's installer image tag).
  EOT
  type        = string
}

variable "talos_schematic_id" {
  description = <<-EOT
    Image Factory schematic ID. It is derived from talos/schematic.yaml.j2 by
    `just talos schematic-id`; `just tofu ...` injects it as
    TF_VAR_talos_schematic_id so the YAML stays the single source of truth for
    system extensions and kernel args.
  EOT
  type        = string
}

variable "talos_image" {
  description = "Image Factory artifact to download for the boot ISO."
  type        = string
  default     = "metal-amd64.iso"
}
