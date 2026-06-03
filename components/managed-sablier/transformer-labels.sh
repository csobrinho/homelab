#!/usr/bin/env sh
set -e

input=$(cat)
name=$(echo "$input" | yq '
  .items[] |
  select(
    .kind == "Deployment" or
    .kind == "StatefulSet" or
    .kind == "DaemonSet"
  ) |
  .metadata.labels["app.kubernetes.io/instance"]
' | head -1 | tr -d '"')

echo "$input" | yq '
  (.items[] | select(
    .kind == "Deployment" or
    .kind == "StatefulSet" or
    .kind == "DaemonSet"
  )) |= (
    .metadata.labels["sablier.group"] = "'"$name"'" |
    .metadata.labels["sablier.enable"] = "true"
  ) |
  (.items[] | select(
    .kind == "Middleware" and
    .metadata.name == "middleware-sablier"
  )).spec.plugin.sablier.group = "'"$name"'" |
  (.items[] | select(
    .kind == "IngressRoute"
  )).spec.routes[0].middlewares += [{"name": "middleware-sablier"}]
'
