# Tofu

[OpenTofu](https://opentofu.org) configuration that provisions the **Talos
control-plane VMs** (`infra1`, `infra2`, `infra3`) on the Proxmox node
`infra-vm`, using the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
provider.

Scope is deliberately small: **VMs only**. Talos machine configuration is rendered
and applied separately with `just talos apply-node <node>` once a VM is up. Cluster
workloads run on other VMs, not these.

## Layout

| Path                       | Purpose                                                          |
| -------------------------- | --------------------------------------------------------------- |
| `versions.tf`              | Provider + `required_version` pins, state encryption block       |
| `providers.tf`             | Proxmox provider (all connection settings come from the env)     |
| `variables.tf`             | Inputs, with defaults                                            |
| `main.tf`                  | ISO download + the three VMs (`for_each` over `var.nodes`)       |
| `outputs.tf`               | VM IDs and NIC MACs (for DHCP reservations)                      |
| `terraform.tfvars`         | Non-secret, environment-specific values (committed)              |
| `proxmox.sops.yaml`        | SOPS-encrypted `PROXMOX_VE_*` + state passphrase (committed)     |
| `terraform.tfstate`        | Encrypted state, committed (GitOps)                              |
| `mod.just`                 | `just tofu ...` recipes                                          |

## Secrets & state

- **Provider credentials** live in `proxmox.sops.yaml`, encrypted to the age keys
  in the repo `.sops.yaml`. `just tofu ...` injects them via `sops exec-env`, so
  no plaintext ever hits disk. Bootstrap it from the example:

  ```sh
  cp proxmox.sops.yaml.example proxmox.sops.yaml
  $EDITOR proxmox.sops.yaml          # fill in real values
  sops --encrypt --in-place proxmox.sops.yaml
  ```

- **State is committed** to git. OpenTofu's native state encryption (`aes_gcm`
  keyed by a PBKDF2 passphrase) keeps `terraform.tfstate` unreadable at rest. The
  passphrase is `TOFU_STATE_PASSPHRASE` inside `proxmox.sops.yaml`; `mod.just`
  turns it into `TF_ENCRYPTION` at runtime. Running bare `tofu` without that env
  var fails on purpose - always go through `just tofu ...`.

## Talos image

The boot ISO is pulled straight onto Proxmox storage from the
[Image Factory](https://factory.talos.dev). `talos/schematic.yaml.j2` stays the
single source of truth for extensions and kernel args: `just tofu ...` runs
`just talos schematic-id` and passes the result as `TF_VAR_talos_schematic_id`.

> If `just talos schematic-id` is not reachable as a cross-module call in your
> `just` version, drop `[private]` from that recipe in `talos/mod.just`, or set
> `talos_schematic_id` directly in `terraform.tfvars`.

Bump `talos_version` in `terraform.tfvars` in lockstep with the installer image
in `talos/cluster.yaml.j2`.

## Usage

```sh
just tofu init
just tofu plan
just tofu apply
just tofu output control_plane      # grab the NIC MACs for DHCP reservations
just tofu run state list            # any other subcommand
just tofu destroy
```

### First bring-up

1. `just tofu apply` - creates the ISO download + three stopped/started VMs.
2. Add DHCP reservations for the MACs from `just tofu output control_plane` so
   each node lands on a stable address in `10.10.2.0/24`.
3. Boot order is `scsi0` then the ISO, so the empty disk falls through to the
   installer on first boot; Talos installs to `scsi0` and reboots off it.
4. `just talos apply-node infra1` (then `infra2`, `infra3`) to push machine config.
5. Bootstrap etcd on the first node: `talosctl -n infra1 bootstrap`.

## Prerequisites on the `talos/` side

The Talos config under `talos/` is currently written for bare metal. Before these
VMs can join, that side needs:

- **Node subnet 10.10.2.0/24.** The control plane runs on the infra-vm host
  network (`vmbr0`, untagged), not `192.168.42.0/24`. Update
  `talos/cluster.yaml.j2` -> `KubeNodeConfig.nodeIP.validSubnets` and
  `KubeletConfig` `validSubnets`, and `talos/controlplane.yaml.j2` ->
  `etcd.advertisedSubnets`. If bare-metal workers stay on `192.168.42.0/24`,
  list both subnets so each node matches exactly one, and make sure the two
  route to each other.
- **VM network config.** The `LinkAliasConfig` / `BondConfig` / `VLANConfig`
  chain keys off the `atlantic` NIC driver and does not apply to a virtio NIC.
  The VMs need a `LinkAliasConfig` matching `link.driver == "virtio_net"` plus a
  `DHCPv4Config` (or static `AddressConfig` + `RouteConfig` on 10.10.2.0/24).
- **`k8s.internal`** must resolve to the three control-plane addresses (or a VIP /
  load balancer in front of them).
- **Install disk selector.** `talos/cluster.yaml.j2`'s `UnattendedInstallConfig`
  matches `disk.model == "MK000480GWCEV"`; no virtual disk matches. Override
  `provisioning.diskSelector` for the VMs (e.g. `disk.transport == "scsi"`, or by
  size).
- **Schematic.** The shared schematic carries bare-metal extensions (`i915`,
  `thunderbolt`, `drbd`, `intel-ucode`, `mei`) and Meteor Lake kernel args. Add
  `siderolabs/qemu-guest-agent` and set `agent_enabled = true` if you want
  graceful shutdown and IP reporting.
