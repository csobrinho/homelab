# Create cloudflare secret:
```
kubectl create secret generic cloudflare-token-secret -n traefik --from-literal="cloudflare-token=$CF_AP_TOKEN"
```