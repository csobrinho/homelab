# Non-secret, environment-specific values. Secrets (PROXMOX_VE_*, the state
# passphrase) live in tofu/proxmox.sops.yaml. The schematic ID is injected by
# `just tofu ...` from talos/schematic.yaml.j2.

proxmox_node = "infra-vm"

# Match the Talos version used by talos/cluster.yaml.j2's installer image.
# 1.14.0 GA isn't out yet; rc.2 is the latest tag at the factory.
talos_version = "v1.14.0-rc.2"

# --- VM sizing (dedicated control plane; workloads run on separate VMs) --------
cpu_cores = 4
memory    = 8192 # MiB
disk_size = 64   # GiB

# talos/schematic.yaml.j2 includes siderolabs/qemu-guest-agent.
agent_enabled = true

# --- Proxmox placement -------------------------------------------------------
vm_datastore_id  = "local-vms"
iso_datastore_id = "local"

# --- Networking ------------------------------------------------------------
# Control plane lives on 10.10.2.0/24 - the same untagged L2 as the infra-vm
# host (vmbr0 -> bond0, not VLAN-aware). No tag. talos/ must be updated so the
# node subnet is 10.10.2.0/24 (see tofu/README.md).
network_bridge = "vmbr0"
# network_vlan_id stays null (untagged)
# network_mtu    = 1

# --- Nodes -----------------------------------------------------------------
# Keys must match talos/nodes/controlplane/<key>.yaml.j2. MAC prefix 52:54:00 is
# the KVM locally-administered OUI; last octet mirrors the 10.10.2.x host.
nodes = {
  infra1 = { vm_id = 211, mac_address = "52:54:00:0a:02:11" }
  infra2 = { vm_id = 212, mac_address = "52:54:00:0a:02:12" }
  infra3 = { vm_id = 213, mac_address = "52:54:00:0a:02:13" }
}
