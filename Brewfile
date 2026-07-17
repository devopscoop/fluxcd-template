# Brewfile for fluxcd-template
#
# Installs every CLI tool used or referenced by this repo.
# Usage: brew bundle

tap "controlplaneio-fluxcd/tap"

# age (includes age-keygen) - encrypting/decrypting the SOPS age key
brew "age"

# bash - all repo scripts use `#!/usr/bin/env bash`
brew "bash"

# curl - update_flux-instance.sh queries the GitHub API and ghcr.io
brew "curl"

# dyff - YAML diffing, referenced in apps/templates/helm/values.yaml
brew "dyff"

# flux-operator - the Flux Operator CLI used by deploy.sh (NOT the standard
# `flux` CLI, which appears only in commented-out lines)
brew "controlplaneio-fluxcd/tap/flux-operator"

# git - commit/push throughout the bootstrap
brew "git"

# helm - pulling charts, showing values, prototyping installs
brew "helm"

# pre-commit - git hook framework used by .pre-commit-config.yaml
brew "pre-commit"

# python - runs the local validate-flux pre-commit hook
brew "python"

# sops - encrypting/decrypting Helm values secrets
brew "sops"

# vim - documented editor steps for app values files
brew "vim"

# yq - YAML edits in deploy scripts. Must be the Go (mikefarah) yq, which this is.
brew "yq"
