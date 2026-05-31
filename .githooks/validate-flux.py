#!/usr/bin/env python3
"""Pre-commit hook to validate FluxCD conventions.

Checks:
1. Namespace resources in staged YAML files must have
   kustomize.toolkit.fluxcd.io/prune: disabled annotation.
2. dependsOn entries in Flux Kustomizations must reference
   existing Kustomization files in flux/flux-system/.
"""

import os
import sys
import yaml
from pathlib import Path


def find_all_yaml(paths):
    for p in paths:
        p = Path(p)
        if p.is_file() and p.suffix in (".yaml", ".yml"):
            yield p
        elif p.is_dir():
            for f in p.rglob("*"):
                if f.is_file() and f.suffix in (".yaml", ".yml"):
                    yield f


def load_yaml_docs(path):
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if doc is not None:
                yield doc


def check_prune_annotation(path, doc, errors):
    kind = doc.get("kind")
    if kind != "Namespace":
        return
    annotations = doc.get("metadata", {}).get("annotations", {})
    val = annotations.get("kustomize.toolkit.fluxcd.io/prune")
    if val != "disabled":
        errors.append(
            f"{path}: Namespace {doc['metadata'].get('name', '?')} is missing "
            f"annotation 'kustomize.toolkit.fluxcd.io/prune: disabled'"
        )


def check_depends_on_targets(flux_system_dir, errors):
    if not flux_system_dir.exists():
        return

    kustomizations = {}
    flux_files = list(flux_system_dir.glob("*.yaml"))

    for f in flux_files:
        for doc in load_yaml_docs(f):
            if doc.get("apiVersion") == "kustomize.toolkit.fluxcd.io/v1" and doc.get("kind") == "Kustomization":
                name = doc["metadata"]["name"]
                kustomizations[name] = {"file": f, "deps": set(), "doc": doc}

    for name, info in kustomizations.items():
        depends_on = info["doc"].get("spec", {}).get("dependsOn", [])
        for dep in depends_on:
            dep_name = dep.get("name")
            if not dep_name:
                errors.append(
                    f"{info['file']}: dependsOn entry missing 'name' field "
                    f"in Kustomization '{name}'"
                )
                continue
            info["deps"].add(dep_name)
            if dep_name not in kustomizations:
                errors.append(
                    f"{info['file']}: dependsOn references '{dep_name}', "
                    f"but no Flux Kustomization with that name exists in {flux_system_dir}/"
                )

    visited = set()
    path_stack = set()

    def detect_cycle(name):
        if name in path_stack:
            cycle = " -> ".join(list(path_stack) + [name])
            errors.append(
                f"Circular dependsOn detected: {cycle}"
            )
            return
        if name in visited:
            return
        visited.add(name)
        path_stack.add(name)
        for dep in kustomizations.get(name, {}).get("deps", set()):
            detect_cycle(dep)
        path_stack.discard(name)

    for name in kustomizations:
        detect_cycle(name)


def main():
    staged_files = sys.argv[1:]

    repo_root = Path(os.environ.get("REPO_ROOT", os.getcwd()))
    flux_system_dir = repo_root / "flux" / "flux-system"

    errors = []
    seen_files = set()

    for yaml_file in find_all_yaml(staged_files):
        if yaml_file in seen_files:
            continue
        seen_files.add(yaml_file)
        try:
            for doc in load_yaml_docs(yaml_file):
                check_prune_annotation(yaml_file, doc, errors)
        except (yaml.YAMLError, OSError) as e:
            errors.append(f"{yaml_file}: Failed to parse YAML: {e}")

    check_depends_on_targets(flux_system_dir, errors)

    if errors:
        for err in errors:
            print(f"FAIL: {err}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
