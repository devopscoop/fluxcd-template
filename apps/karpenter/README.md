# karpenter

[Karpenter](https://karpenter.sh/) provisions and consolidates EC2 nodes in
response to pending pods. Three apps make up the deployment, reconciled in
this order via `dependsOn`:

1. `apps/karpenter-crd` — the CRDs, from the separate karpenter-crd chart so
   they can actually be upgraded (Helm never touches a chart's `crds/`
   directory on upgrade). Keep its version in lockstep with the main chart.
2. `apps/karpenter` — the controller, installed into kube-system with
   `crds: Skip`.
3. `apps/karpenter-custom-resources` — the default NodePool and EC2NodeClass.

The AWS side (controller IRSA role, `karpenter-node` role, interruption
queue, `karpenter.sh/discovery` tags) lives in aws-eks-template
(`cluster/karpenter.tf`); its outputs name the values to paste here.

## TODO

- Look into encrypted root volumes for Karpenter-launched nodes. They
  currently get the AMI's default volume settings, while the blue node
  group's launch template (aws-eks-template `cluster/main.tf`) encrypts the
  root volume with the customer-managed KMS key (`alias/eks/project1-dev/ebs`).
  Parity needs `blockDeviceMappings` with `kmsKeyID` in the EC2NodeClass
  (apps/karpenter-custom-resources) plus key-policy grants in aws-eks-template
  so instances launched by Karpenter (no ASG service-linked role involved) can
  use the key.
