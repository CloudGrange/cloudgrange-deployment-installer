#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — make digest-pinned images resolvable after an air-gapped import.
#
# The chart pins images as repo:tag@sha256:<digest>. containerd's CRI resolves such a reference
# only against a local image NAMED repo@sha256:<digest>; an image imported from a `docker save`
# tarball carries only its repo:tag name, so the kubelet ignores it and tries to pull — which fails
# offline. Proven on kind v1.34: an imported image with the matching content digest still went to
# ImagePullBackOff until a repo@sha256 name was added (`ctr images tag`), after which the same pod
# started with no pull.
#
# This adds, for every digest-pinned reference, a second entry to the saved OCI index.json that
# points at the same manifest and carries io.containerd.image.name=<repo>@sha256:<digest>.
# `ctr images import` (what K3s and kind use for image tarballs) creates one image per annotated
# entry, so both names exist after the import.
#
# Usage: Add-DigestImageNames.py <extracted docker-save dir> <file listing the pinned references>
import json
import sys


def normalize(repo: str) -> str:
    """Docker-style short names to the fully qualified name containerd stores."""
    first = repo.split("/", 1)[0]
    if "/" not in repo:
        return f"docker.io/library/{repo}"
    if "." not in first and ":" not in first and first != "localhost":
        return f"docker.io/{repo}"
    return repo


def main(root: str, refs_file: str) -> int:
    index_path = f"{root}/index.json"
    index = json.load(open(index_path))
    manifests = index.get("manifests", [])
    by_digest = {m["digest"]: m for m in manifests}
    existing = {m.get("annotations", {}).get("io.containerd.image.name") for m in manifests}
    added = 0
    for line in open(refs_file):
        ref = line.strip()
        if "@sha256:" not in ref:
            continue
        name, digest = ref.split("@", 1)
        repo = name.rsplit(":", 1)[0] if ":" in name.rsplit("/", 1)[-1] else name
        target = f"{normalize(repo)}@{digest}"
        if target in existing:
            continue
        if digest not in by_digest:
            print(f"no saved manifest with digest {digest} for {ref}", file=sys.stderr)
            return 1
        entry = json.loads(json.dumps(by_digest[digest]))
        annotations = {k: v for k, v in entry.get("annotations", {}).items()
                       if k != "org.opencontainers.image.ref.name"}
        annotations["io.containerd.image.name"] = target
        entry["annotations"] = annotations
        manifests.append(entry)
        existing.add(target)
        added += 1
    manifests.sort(key=lambda e: json.dumps(e, sort_keys=True))
    index["manifests"] = manifests
    json.dump(index, open(index_path, "w"), indent=None, sort_keys=True)
    print(f"added {added} digest image name(s)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__ or "usage: Add-DigestImageNames.py <dir> <refs file>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
