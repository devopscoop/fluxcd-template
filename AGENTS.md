# AGENTS.md

Instructions for AI coding agents working in this repo.

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install every CLI tool the repo uses. Keep them in sync with the code:

- When you add a tool, script, or a new external command inside an existing script, add the package to BOTH files, with a comment noting what uses it.
- When a tool stops being used, remove it from both files.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch. Names differ between ecosystems — this repo already depends on two such cases: the Go (mikefarah) `yq` is Arch's `go-yq` (Arch's `yq` is the incompatible Python implementation), and the Flux Operator CLI comes from the `controlplaneio-fluxcd/tap` Homebrew tap and the AUR `flux-operator` package. If a package is AUR-only, note that in pkglist.txt's header instructions.
- Update the "Install required packages" section in README.md if the tool list changes.
