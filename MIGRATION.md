# k3s → Talos migration

Moving the homelab off the old k3s cluster onto Talos Linux. Work happens on the
`migration` branch.

## Target

| | |
| --- | --- |
| Networks | nodes/infra `10.10.2.0/24`; VIPs `10.10.10.0/24` (BGP-routed) |
| Control plane | 3 dedicated VMs `infra1/2/3` on Proxmox `infra-vm`, `10.10.2.11-13/24` |
| Workers | more Proxmox VMs on the EPYC host, and RPi5 nodes (**arm64**) — all on `10.10.2.0/24` |
| Endpoint | `infra-k8s` round-robin DNS + KubePrism; API VIP via Cilium BGP later |
| CNI | Cilium, native routing + BGP peering with the UniFi gw (AS65000 @ `10.10.2.1`) |
| GitOps | ArgoCD app-of-apps from `bootstrap/` |
| Provisioning | `tofu/` (bpg/proxmox); Talos config `talos/` via `just talos` |
| Secrets | SOPS + age (`talos/secrets.yaml`, `tofu/proxmox.sops.yaml`) |

## Status

- [x] `tofu/` provisions the 3 CP VMs (q35/OVMF, 4 vCPU / 8 GiB, 64 GiB zvol on
      `local-vms`, MAC `52:54:00:0a:02:1x`, watchdog, guest-agent)
- [x] Talos config VM-adapted (static addressing, virtio NIC alias, disk selector,
      SOPS-rendered secrets, endpoint `infra-k8s`)
- [x] Toolchain + Talos pinned to `v1.14.0-rc.2`
- [x] Cluster bootstrapped — etcd up, k8s `v1.37.0`
- [x] **A.** Cilium deployed — nodes Ready
- [ ] **A'.** Delete the dead bare-metal config from `talos/cluster.yaml.j2`
- [ ] **B.** Drop the `kube-api-proxy` socat — TEST Talos 1.14 native BGP anycast VIP
- [ ] **C.** Bootstrap CRDs (wave 0)
- [ ] **D.** Deploy CoreDNS
- [ ] **E.** Deploy ArgoCD → hand off to `bootstrap/root-app`
- [ ] Workers: `tofu/` + `talos/` configs written (`infra4` GPU, `infra5/6/7`) —
      not yet applied. RPi5 arm64 still TODO. Storage still undecided.
- [ ] `apps/nvidia-gpu-operator` — re-target from k3s to Talos (see below)
- [ ] Cut over DNS / retire the old cluster (incl. GPU VM 110 → `infra4`)

## Plan

### A. Cilium — done

Deployed via `kustomize build --enable-helm apps/cilium/overlays/prod`. Nodes Ready.
Remaining: delete the stale vendored `apps/cilium/overlays/prod/charts/cilium-1.20.0/`
(chart is pulled from the repo). Verify `cilium bgp peers` established with `10.10.2.1`.

### A'. Delete dead bare-metal config

No Meteor Lake nodes — workers are EPYC VMs (virtio, like the CP) and RPi5 (arm64).
Remove from `talos/cluster.yaml.j2` (all `# TODO`): the `atlantic` bond / VLAN link
docs, `RawVolumeConfig miroir-slow`, and the `drbd` / `drbd_transport_tcp` /
`dm_thin_pool` / `nbd` `KernelModuleConfig` docs. RPi5 arm64 workers will need a
`nodes/workers/<node>.schematic.yaml.j2` override for the arm64 image.

Also decide storage direction **before workers exist** (schematic change = node
reprovision): if it's rook-ceph, drop `siderolabs/drbd` from `schematic.yaml.j2`
and add `iscsi-tools` + `util-linux-tools`; if Miroir/DRBD9 stays, keep the drbd
extension and un-TODO the `drbd*` `KernelModuleConfig` blocks.

Other config cleanup (from the 2026-08-31 review, deferred):
- `apps/cilium/overlays/prod/frr.conf` — neighbors are `10.10.2.31–38`; actual
  scheme is CP `infra1-3` `.11–.13`, workers `infra4-7` `.14–.17`. Reconcile
  (Cilium BGP peers from worker node IPs).
- etcd `listen-metrics-urls: http://0.0.0.0:2381` (`controlplane.yaml.j2`) is
  unauthenticated on all interfaces. Once Prometheus exists, either restrict via
  a Talos ingress firewall rule (fleet-wide, port 2381 ← `10.10.2.0/24`) or move
  the bind into the per-node files (they already carry the node IP).
- `apps/cilium/overlays/prod/charts/cilium-1.19.6|1.20.0|1.20.1/` — gitignored
  local cruft; the chart is pulled from `helm.cilium.io` at build time. Delete.

### B. Drop the socat API proxy

The `10.10.10.x` API VIP can't be a Talos `Layer2VIPConfig` — that's ARP-based and
needs the VIP in the node interface's own subnet; VIPs are on `10.10.10.0/24`.

**→ LET'S TEST: Talos 1.14 native BGP anycast.** Per CP node:

```yaml
apiVersion: v1alpha1
kind: DummyLinkConfig
name: dummy0
addresses: [{ address: 10.10.10.10/32 }]     # anycast API VIP
---
apiVersion: v1alpha1
kind: BGPInstanceConfig
name: fabric
localASN: 65002
routerID: 10.10.2.1X                          # node-unique
advertise: [dummy0]
neighbors:
  - { address: 10.10.2.1, peerASN: 65000, bfd: {} }
```

All 3 CP nodes originate `10.10.10.10/32`; the UniFi gw ECMPs / fails over (BFD
sub-second). apiserver already listens `0.0.0.0:6443`. Point `infra-k8s` DNS at
`10.10.10.10`, add it to `certExtraSANs`, optionally make it `controlPlane.endpoint`.
Pure L3 (cross-subnet OK), independent of Cilium (bootstrap-safe), no socat.

**Open question for the test:** Talos BGP and Cilium BGP can't both peer the same gw
from the same node IP (gw rejects the 2nd session). Resolutions:
- run Talos BGP for the API VIP + Cilium LB via **L2 announcements** (forces the
  service LB pool into `10.10.2.0/24`); or
- split by role once workers exist — Talos BGP on CP nodes, Cilium BGP on workers.

Fallbacks if the test doesn't pan out: (1) DNS-only — `infra-k8s` round-robin +
KubePrism, just delete `kube-api-proxy`; (2) `LoadBalancer` Service + hand-maintained
`EndpointSlice` → `10.10.2.11-13:6443`, Cilium-BGP-advertised.

### C. Bootstrap CRDs (wave 0)

CRDs that apps assume exist before ArgoCD reconciles — install first:

- Prometheus-operator (`ServiceMonitor`, `PrometheusRule`, …) — Cilium sets
  `serviceMonitor.trustCRDsExist: true`
- gateway-api / external-secrets / snapshot-controller / etc. as the app set needs

Cilium ships its own CRDs (`includeCRDs: true`), so A doesn't depend on this.

### D. CoreDNS

Disabled in Talos (`KubeCoreDNSConfig enabled: false`) to self-manage. Deploy the
`coredns/coredns` chart. (Or flip `enabled: true` for Talos-managed.) With B done
it's off the API-endpoint critical path, but everything else needs it.

### E. ArgoCD

Install ArgoCD, then:

```sh
kubectl apply -f bootstrap/root-app/application.yaml
```

App-of-apps from `bootstrap/apps` takes over — including adopting Cilium and CoreDNS.

## Later — workers + storage

- **EPYC VM workers**: configs written (not applied). `tofu/terraform.tfvars`
  `var.workers` = `infra4` (12 vCPU / 64 GiB, 2× RTX 5090 passthrough, replaces
  k3s VM 110) + `infra5/6/7` (24 vCPU / 96 GiB). `talos/workers.yaml.j2` +
  `talos/nodes/workers/*.yaml.j2`; `infra4` also has a `.schematic.yaml.j2` with
  `nvidia-open-gpu-kernel-modules-production` + `nvidia-container-toolkit-production`
  (595.91.07; the RTX 5090 / Blackwell GB202 is open-module only — the closed
  `nonfree-kmod-nvidia` bailed `RmInitAdapter ... requires ... open kernel
  modules` on first boot) and is tainted `nvidia.com/gpu=present:NoSchedule`.
  All on `10.10.2.0/24`, so
  `autoDirectNodeRoutes` keeps working fleet-wide — no PodCIDR BGP needed.
  Bring-up: `just tofu apply`, DHCP reservations, `just talos apply-node <n>`
  (workers just join — no `bootstrap`). GPU host prep (vfio-pci bind, IOMMU,
  ReBAR, `lspci` slot IDs) is in `tofu/README.md`.
- **NVIDIA on Talos** (`apps/nvidia-gpu-operator`): today's overlay is k3s-shaped
  (`driver.usePrecompiled`, `toolkit.enabled`, k3s containerd paths). On Talos
  the extension already ships the driver + toolkit + `nvidia` RuntimeClass, so
  flip to `driver.enabled: false`, `toolkit.enabled: false`, drop the k3s
  `CONTAINERD_*` env, keep the device plugin + `time-slicing-config-all` +
  dcgm-exporter. Do this as part of wave E (ArgoCD), not before.
- **RPi5 workers** (arm64): not tofu — flash the Talos arm64 SBC image. Needs an
  arm64 schematic (`nodes/workers/<node>.schematic.yaml.j2`) and arm64-safe
  workload scheduling (`kubernetes.io/arch` nodeAffinity or multi-arch images).
- Storage: rook-ceph (and/or `miroir` DRBD9) once there are worker nodes to host it.

## Bring-up reference

- **Proxmox token** (`tofu@pve!controlplane`, role `TofuProvision`) needs
  `SDN.Use` on PVE 9 for bridge assignment (plain bridges are in the
  `localnetwork` SDN zone), and `Mapping.Use` + `Mapping.Audit` for `infra4`'s
  GPU passthrough (a token can't set a raw `hostpci` path — only a PVE PCI
  *resource mapping*; `gpu0`/`gpu1` created as root). Add any further privileges
  hit during `tofu apply` to `tofu/README.md`.
- **First `apply-config`** is `--insecure` to the node's *maintenance* DHCP IP
  (`10.10.2.121-123`); the static `.11-.13` only exists after the config installs
  and the node reboots, after which the API needs mTLS (`talosconfig`).
- **talosconfig:**
  ```sh
  sops decrypt talos/secrets.yaml > /tmp/s.yaml
  talosctl gen config main https://infra-k8s:6443 --with-secrets /tmp/s.yaml \
    --talos-version "$(yq -r .version.talos talos/versions.yaml)" \
    --output-types talosconfig -o talosconfig
  rm /tmp/s.yaml
  talosctl config endpoint 10.10.2.11 10.10.2.12 10.10.2.13
  ```
- **Disk selector** must exclude the ISO's loop/cdrom:
  `!disk.readonly && !disk.cdrom && disk.size > 10u * GB`.
- **Cilium on Talos** needs `cgroup.autoMount.enabled: false`, a capability set
  without `SYS_MODULE`, and `socketLB.hostNamespaceOnly: true` (for Talos
  `forwardKubeDNSToHost`).
- **Full shutdown:** `just talos shutdown-cluster`. Never Proxmox "Stop" — use
  "Shutdown" (ACPI) or the recipe.
- **`tofu/terraform.tfstate`** is committed, encrypted (OpenTofu native
  `aes_gcm`/`pbkdf2`, passphrase in `proxmox.sops.yaml`). Re-commit after every
  `just tofu apply`. Losing the age key = unrecoverable state and secrets.
