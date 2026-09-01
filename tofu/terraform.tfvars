# Non-secret, environment-specific values. Secrets (PROXMOX_VE_*, the state
# passphrase) live in tofu/proxmox.sops.yaml. `just tofu ...` injects
# talos_schematic_id (from talos/schematic.yaml.j2) and talos_version (from
# talos/versions.yaml).

proxmox_node = "infra-vm"

# --- VM sizing (dedicated control plane; workloads run on separate VMs) --------
cpu_cores = 4
memory    = 8192 # MiB
disk_size = 64   # GiB

# --- Worker sizing (defaults; override per node in the workers map below) -------
# Host budget: 128 threads / 512 GiB, 2x RTX 5090. Reserve ~8 threads / ~48 GiB
# for Proxmox + ZFS ARC; control plane takes 12 threads / 24 GiB; infra4 (GPU)
# is pinned at 12 threads / 64 GiB. That leaves the three general workers at
# 24 threads / 96 GiB each with headroom to spare.
worker_cpu_cores = 24
worker_memory    = 98304 # 96 GiB
worker_disk_size = 200   # GiB

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

# --- Workers -------------------------------------------------------------------
# infra1-3 are the control plane (var.nodes); infra4+ are workers. Keys must
# match talos/nodes/workers/<key>.yaml.j2. Same MAC convention as the control
# plane (last octet mirrors the 10.10.2.x host).
#
#   infra4       GPU node, 10.10.2.14 - Both RTX 5090s are passed through; also
#                needs talos/nodes/workers/infra4.schematic.yaml.j2 (nvidia
#                extensions) and the GPUs bound to vfio-pci on the host.
#   infra5-7     general compute, 10.10.2.15-17
#
# hostpci `mapping`: name of a PVE datacenter PCI resource mapping (an API token
# can't set a raw `id`). Create them on infra-vm first - see tofu/README.md.
#   gpu0 -> 0000:81:00  (RTX 5090, PCIe slot 7; iommu group 28)
#   gpu1 -> 0000:01:00  (RTX 5090, PCIe slot 5; iommu group 73)
# Both cards are identical, so which is gpu0/gpu1 is cosmetic - infra4 gets both.
workers = {
  infra4 = {
    vm_id       = 214
    mac_address = "52:54:00:0a:02:14"
    cpu_cores   = 12
    memory      = 65536 # 64 GiB
    hostpci = [
      { device = "hostpci0", mapping = "gpu0" }, # RTX 5090 #1
      { device = "hostpci1", mapping = "gpu1" }, # RTX 5090 #2
    ]
  }
  infra5 = { vm_id = 215, mac_address = "52:54:00:0a:02:15" }
  infra6 = { vm_id = 216, mac_address = "52:54:00:0a:02:16" }
  infra7 = { vm_id = 217, mac_address = "52:54:00:0a:02:17" }
}
