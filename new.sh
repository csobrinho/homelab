#!/bin/env bash
[[ $# -lt 1 ]] && { echo "usage: new.sh app-name [ns-name] [subdomain]"; exit 1; }

set -x
set -eu -o pipefail

app="$1"
ns="${2:-$1}"
subdomain="${3:-$1}"

cd /data/config/homelab

cp -R "apps/cyberchef/" "apps/$app"
cp "bootstrap/apps/apps/cyberchef-app.yaml" "bootstrap/apps/apps/$app-app.yaml"
sed -i "s,resources:,resources:\n  - apps/$app-app.yaml," "bootstrap/apps/kustomization.yaml"

find "apps/$app" "bootstrap/apps/apps/$app-app.yaml" -type f -exec sed -i "s,namespace: cyberchef,namespace: $ns,g" {} \+
find "apps/$app" -name "ns.yaml" -exec sed -i "s,name: cyberchef,name: $ns,g" {} \+
find "apps/$app" "bootstrap/apps/apps/$app-app.yaml" -type f -exec sed -i "s,cyberchef.sobrinho.pt,$subdomain.sobrinho.pt,g" {} \+
find "apps/$app" "bootstrap/apps/apps/$app-app.yaml" -type f -exec sed -i "s,cyberchef,$app,g" {} \+
