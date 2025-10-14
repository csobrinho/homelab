## Cilium

1. Download the latest cilium version

```sh
# Detect architecture
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

# Download and install
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum -c cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Verify
cilium version
```

2. Update the `/etc/systemd/system/k3s.service` for each control plane and add:
```
'--flannel-backend' 'none' \
'--disable-network-policy' \
'--disable-kube-proxy' \
```

Control plane should look like:
```
ExecStart=/usr/local/bin/k3s \
    server \
    '--server' 'https://10.10.2.10:6443' \
    '--disable' 'servicelb,traefik' \
    '--embedded-registry' \
    '--flannel-backend' 'none' \
    '--disable-network-policy' \
    '--disable-kube-proxy' \
    '--etcd-s3' \
    '--etcd-s3-endpoint' 's3.sobrinho.pt' \
    '--etcd-s3-access-key' 'xxxxxxxxxxx' \
    '--etcd-s3-secret-key' 'xxxxxxxxxxxxx' \
    '--etcd-s3-bucket' 'etcd' \
```

3. Restart the daemons:

```sh
sudo systemctl daemon-reload
sudo systemctl restart k3s  # or k3s-agent on workers
```

4. Remove the flanel interface from all nodes:

```sh
sudo ip link delete flannel.1 2>/dev/null || echo "flannel.1 not found"
ip link show flannel.1  # Should return error
```

5. Install Cilium CNI from one control plane node:
```sh
export KUBECONFIG=~/.kube/config

cilium install --version 1.18.2 --values apps/cilium/overlays/prod/values.yaml

# Wait for Cilium to be ready
cilium status --wait
```
