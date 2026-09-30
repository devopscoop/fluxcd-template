# Everything. Attached to the "admin" Kubernetes-auth role (configure.sh),
# which only the openbao-admin ServiceAccount can log in to.
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
