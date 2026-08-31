# Tofu

[OpenTofu](https://opentofu.org) configuration that provisions the **Talos
control-plane VMs** (`infra1`, `infra2`, `infra3`) on the Proxmox node
`infra-vm`, using the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
provider.

Scope is deliberately small: **VMs only**. Talos machine configuration is rendered
and applied separately with `just talos apply-node <node>` once a VM is up. Cluster
workloads run on other VMs, not these.

## Failure domains

All three control-plane VMs - and the worker VMs - run on the single Proxmox host
`infra-vm`. The 3-node control plane protects against VM-, Talos- and
etcd-disk-level failure, but **not host failure**: an `infra-vm` outage takes the
whole cluster down and loses etcd quorum. No second Proxmox host is planned. The
only route to a real second failure domain is the RPi5 nodes (arm64) added later -
one could carry a control-plane member if etcd host-redundancy becomes a
requirement.

## Layout

| Path                       | Purpose                                                          |
| -------------------------- | --------------------------------------------------------------- |
| `versions.tf`              | Provider + `required_version` pins, state encryption block       |
| `providers.tf`             | Proxmox provider (all connection settings come from the env)     |
| `variables.tf`             | Inputs (`nodes` comes from `terraform.tfvars`; the rest default) |
| `main.tf`                  | ISO download + the three VMs (`for_each` over `var.nodes`)       |
| `outputs.tf`               | VM IDs and NIC MACs (for DHCP reservations)                      |
| `terraform.tfvars`         | Non-secret, environment-specific values (committed)              |
| `proxmox.sops.yaml`        | SOPS-encrypted `PROXMOX_VE_*` + state passphrase (committed)     |
| `terraform.tfstate`        | Encrypted state, committed (GitOps)                              |
| `mod.just`                 | `just tofu ...` recipes                                          |

## Secrets & state

- **Provider credentials** live in `proxmox.sops.yaml`, encrypted to the age keys
  in the repo `.sops.yaml`. `just tofu ...` injects them via `sops exec-env`, so
  no plaintext ever hits disk. On a fresh clone, recreate it with the keys the
  provider (`providers.tf`) and `mod.just` expect:

  ```sh
  sops edit proxmox.sops.yaml        # sops creates + encrypts on save
  ```

  | Key                     | Value                                              |
  | ----------------------- | -------------------------------------------------- |
  | `PROXMOX_VE_ENDPOINT`   | `https://<pve-host>:8006/`                          |
  | `PROXMOX_VE_API_TOKEN`  | `<user>@<realm>!<token-id>=<uuid>`                  |
  | `PROXMOX_VE_INSECURE`   | `"true"` to skip TLS verification of the PVE cert   |
  | `TOFU_STATE_PASSPHRASE` | long random string; encrypts `terraform.tfstate`   |

- **State is committed** to git. OpenTofu's native state encryption (`aes_gcm`
  keyed by a PBKDF2 passphrase) keeps `terraform.tfstate` unreadable at rest. The
  passphrase is `TOFU_STATE_PASSPHRASE` inside `proxmox.sops.yaml`; `mod.just`
  turns it into `TF_ENCRYPTION` at runtime. Running bare `tofu` without that env
  var fails on purpose - always go through `just tofu ...`.

## Talos image

The boot ISO is pulled straight onto Proxmox storage from the
[Image Factory](https://factory.talos.dev). Two files in `talos/` stay the single
source of truth; `just tofu ...` injects both as `TF_VAR_*`:

- `schematic.yaml.j2` -> `talos_schematic_id` (via `just talos schematic-id`):
  system extensions and kernel args.
- `versions.yaml` (`.version.talos`) -> `talos_version`: the release tag. The same
  file drives the installer image and kubelet image in `talos/cluster.yaml.j2`,
  so the ISO and the installed system never diverge. Bump it there.

The ISO filename embeds the version, so bumping `talos_version` replaces the
download resource - the old ISO is deleted, the new one fetched. If you bump it
while `attach_iso` is still `true` and the VMs are running, detach first (set
`attach_iso = false`, apply) or Proxmox will refuse to delete the in-use ISO.
Past bring-up this is moot: `attach_iso = false` and OS upgrades go through
`just talos upgrade-node`.

> If `just talos schematic-id` is not reachable as a cross-module call in your
> `just` version, drop `[private]` from that recipe in `talos/mod.just`, or set
> `talos_schematic_id` directly in `terraform.tfvars`.

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
6. Once all three are installed and healthy, set `attach_iso = false` in
   `terraform.tfvars` and `just tofu apply` - this deletes the ISO and detaches
   the CD-ROM, so later `talos/versions.yaml` bumps don't churn the VMs. OS
   upgrades from here on are `just talos upgrade-node <node>`.

## Talos machine config

Not managed here. `talos/README.md` covers how per-node configs are rendered and
applied; `MIGRATION.md` tracks the k3s -> Talos plan and current state (node
subnet, endpoint, DNS, storage direction, remaining `# TODO` items).

The install `diskSelector` in `talos/cluster.yaml.j2` is
`!disk.readonly && !disk.cdrom && disk.size > 10u * GB` - it picks the single
writable virtio disk and skips the read-only ISO loop/cdrom devices.
