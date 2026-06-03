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
  .items[] |= (
    if (
      .kind == "Deployment" or
      .kind == "StatefulSet" or
      .kind == "DaemonSet"
    ) then
      .metadata.labels["sablier.group"] = "'"$name"'" |
      .metadata.labels["sablier.enable"] = "true"
    elif (
      .kind == "Middleware" and
      .metadata.name == "middleware-sablier"
    ) then
      .spec.plugin.sablier.group = "'"$name"'"
    else
      .
    end
  )
'