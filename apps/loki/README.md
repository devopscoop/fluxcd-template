# Loki

Grafana Loki as a log store, deployed in **SingleBinary** mode backed by
**S3-compatible object storage**. Logs are queried through the existing Grafana
in `kube-prometheus-stack` (a Loki datasource is provisioned there via
`grafana.additionalDataSources`).

Loki only *stores* logs — `apps/alloy` ships pod logs into it.

## Before deploying

1. Create two buckets in your object store (e.g. Rook-Ceph RGW, MinIO, or AWS
   S3): one for chunks and one for the ruler.
2. Fill in the `CHANGEME-*` placeholders:
   - `values.yaml` → `loki.storage.bucketNames` and `loki.storage.s3`
     (endpoint, region). For Rook-Ceph RGW the endpoint is
     `rook-ceph-rgw-<store>.rook-ceph.svc:80` and keep `s3ForcePathStyle: true`.
   - `helm_secrets.yaml.decrypted` → `accessKeyId` / `secretAccessKey`.
3. Encrypt the secret: `./encrypt_secrets.sh` (requires your age key configured
   in `.sops.yaml`).

## Notes

- Retention is set to 31 days (`loki.limits_config.retention_period`) and
  enforced by the in-process compactor.
- The query/push endpoint is `http://loki-gateway.loki.svc.cluster.local`.
- To scale beyond ~tens of GB/day, switch `deploymentMode` to `SimpleScalable`
  and give `read`/`write`/`backend` non-zero replica counts.
