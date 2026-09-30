# Read-only on the whole kv v2 store, for the ClusterSecretStore in
# apps/external-secrets-custom-resources. External Secrets never writes to
# OpenBao here (no PushSecrets), so it gets no write capability.
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
