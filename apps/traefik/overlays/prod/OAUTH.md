# Create oauth secrets:
```
kubectl -n traefik create secret generic traefik-forward-auth-secrets \
  --from-literal="google-client-id=xxxxxxxxxx" \
  --from-literal="google-client-secret=xxxxxxxxxx" \
  --from-literal="secret=xxxxxxxxxx" \
  --from-literal="whitelist=email@gmail.com"
```