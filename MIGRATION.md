# k3s → Talos migration

Moving the homelab off the old k3s cluster onto Talos Linux. Work happens on the
`migration` branch.

## Target

| | |
| --- | --- |
| Control plane | 3 dedicated VMs `infra1/2/3` on Proxmox `infra-vm`, `10.10.2.11-13/24` |
| Workers | bare-metal Meteor Lake nodes (wiped + rejoined later, `192.168.42.0/24`) |
| Endpoint | `infra-k8s` today (round-robin DNS); → Talos Layer-2 VIP later |
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
- [x] Cluster bootstrapped — etcd up, k8s `v1.37.0`, nodes registered (NotReady, no CNI)
- [ ] **A.** Deploy Cilium → nodes Ready
- [ ] **B.** Replace `kube-api-proxy` socat with a Talos-native API VIP
- [ ] **C.** Bootstrap CRDs (wave 0)
- [ ] **D.** Deploy CoreDNS
- [ ] **E.** Deploy ArgoCD → hand off to `bootstrap/root-app`
- [ ] Workers + storage
- [ ] Cut over DNS / retire the old cluster

## Plan

### A. Cilium

```sh
kustomize build --enable-helm apps/cilium/overlays/prod | kubectl apply -f -
kubectl -n kube-system delete pod -l k8s-app=cilium      # pick up the Talos caps
kubectl -n kube-system get pods -l k8s-app=cilium -w
```

- Chart `1.20.1` is pulled from the repo (`kustomization.yaml`); delete the stale
  vendored `apps/cilium/overlays/prod/charts/cilium-1.20.0/`.
- Verify: `cilium status`, `cilium bgp peers` (established with `10.10.2.1`), the
  LB pool in `lb-pools.yaml` serves the API VIP address.

### B. Drop socat → Talos-native API LB

Currently the API VIP (`infra-adm`) is a socat `DaemonSet` (`kube-api-proxy.yaml`)
behind a Cilium `LoadBalancer` — an in-cluster dependency for the control-plane
endpoint. Replace with a Talos `Layer2VIPConfig` on the CP nodes:

- pick a spare `10.10.2.x` (e.g. `.10`); Talos elects the holder via etcd and
  announces it with gratuitous ARP (same-subnet requirement is met)
- add the doc to `talos/controlplane.yaml.j2`, `just talos apply-node` each node
- repoint `infra-adm` / `infra-k8s` DNS at the VIP
- optionally set `cluster.yaml.j2` `controlPlane.endpoint` to it (SANs already cover it)
- then delete `kube-api-proxy.yaml` + its LB pool

Not cluster-dependent — can be done any time.

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

- Wipe the bare-metal nodes, rejoin as Talos workers on `192.168.42.0/24`:
  create `talos/workers.yaml.j2` + `talos/nodes/workers/`, and move the
  bare-metal-only docs currently marked `# TODO` in `cluster.yaml.j2`
  (bond/VLAN link config, `RawVolumeConfig miroir-slow`, drbd `KernelModuleConfig`)
  into that layer.
- Enable `advertisementType: PodCIDR` in `apps/cilium/overlays/prod/bgp-config.yaml`
  — workers on a different subnet break `autoDirectNodeRoutes`.
- Storage: rook-ceph and/or `miroir` DRBD9 replication on the workers.

## Bring-up reference

- **Proxmox token** (`tofu@pve!controlplane`, role `TofuProvision`) needs
  `SDN.Use` on PVE 9 for bridge assignment (plain bridges are in the
  `localnetwork` SDN zone). Add any further privileges hit during `tofu apply`
  to `tofu/README.md`.
- **First `apply-config`** is `--insecure` to the node's *maintenance* DHCP IP
  (`10.10.2.121-123`); the static `.11-.13` only exists after the config installs
  and the node reboots, after which the API needs mTLS (`talosconfig`).
- **talosconfig:**
  ```sh
  sops decrypt talos/secrets.yaml > /tmp/s.yaml
  talosctl gen config main https://infra-k8s:6443 --with-secrets /tmp/s.yaml \
    --talos-version v1.14.0-rc.2 --output-types talosconfig -o talosconfig
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
