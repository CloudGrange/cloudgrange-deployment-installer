#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — refuse an air-gap image tarball that containerd cannot import.
#
# preview.10 shipped a cloudgrange-images-amd64.tar whose four cert-manager v1.21.2 images carried
# their linux/amd64 manifest but NOT its config or most of its layers, so on the owner's Linux
# server `k3s ctr images import` died with
#   ctr: content digest sha256:6a68bd9d…: not found     (cert-manager-cainjector's config blob)
# The build host's Docker (containerd image store) held image records whose layer blobs were gone,
# and `docker save` exported them anyway (two blobs, exit 0). New-ReleaseBundleK3s.sh no longer
# exports from Docker at all; this gate makes sure no future source can do that silently again.
#
# This walks the saved OCI layout the way `ctr images import --platform linux/amd64` does: every
# named index.json entry, down the linux/amd64 branch only (other platforms and attestation
# manifests are never read by that import, so their absence is fine), and requires the manifest,
# its config and every layer to be present with the recorded size. It also requires every image
# the chart references to be named in the tarball — repo:tag, and repo@sha256:<digest> for the
# digest-pinned ones (Add-DigestImageNames.py) — because a pod whose image is not named there
# goes to ImagePullBackOff on an air-gapped host.
#
# Usage: Test-ImageTarComplete.py <image tarball, or an extracted docker-save dir> <images.txt>
import json
import os
import sys
import tarfile

INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
PLATFORM = ("linux", "amd64")


def normalize(ref: str) -> str:
    """Docker-style short name to the fully qualified name containerd stores (tag/digest kept)."""
    first = ref.split("/", 1)[0]
    if "/" not in ref:
        return f"docker.io/library/{ref}"
    if "." not in first and ":" not in first and first != "localhost":
        return f"docker.io/{ref}"
    return ref


def expected_names(ref: str) -> list:
    """The containerd image names a chart reference needs: repo:tag, plus repo@sha256:… if pinned."""
    if "@" in ref:
        name, digest = ref.split("@", 1)
        repo = name.rsplit(":", 1)[0] if ":" in name.rsplit("/", 1)[-1] else name
        names = [normalize(f"{repo}@{digest}")]
        if name != repo:
            names.append(normalize(name))
        return names
    return [normalize(ref)]


class Layout:
    def __init__(self, path: str):
        self.dir = path if os.path.isdir(path) else None
        self.members = {}
        if self.dir is None:
            self.tar = tarfile.open(path)
            for m in self.tar.getmembers():
                if m.isfile():
                    self.members[os.path.normpath(m.name)] = m

    def size(self, rel: str):
        if self.dir is not None:
            p = os.path.join(self.dir, rel)
            return os.path.getsize(p) if os.path.isfile(p) else None
        m = self.members.get(os.path.normpath(rel))
        return None if m is None else m.size

    def json(self, rel: str):
        if self.dir is not None:
            with open(os.path.join(self.dir, rel)) as f:
                return json.load(f)
        return json.load(self.tar.extractfile(self.members[os.path.normpath(rel)]))


def blob_path(digest: str) -> str:
    algo, hexd = digest.split(":", 1)
    return f"blobs/{algo}/{hexd}"


def check_descriptor(layout, desc, where, problems) -> bool:
    size = layout.size(blob_path(desc["digest"]))
    if size is None:
        problems.append(f"{where}: {desc.get('mediaType', '?')} {desc['digest']} not in the tarball")
        return False
    if "size" in desc and size != desc["size"]:
        problems.append(f"{where}: {desc['digest']} is {size} bytes, descriptor says {desc['size']}")
        return False
    return True


def check_image(layout, desc, name, problems, depth=0):
    if depth > 4 or not check_descriptor(layout, desc, name, problems):
        return
    doc = layout.json(blob_path(desc["digest"]))
    media = desc.get("mediaType") or doc.get("mediaType")
    if media in INDEX_TYPES or "manifests" in doc:
        matches = [c for c in doc.get("manifests", [])
                   if (c.get("platform", {}).get("os"), c.get("platform", {}).get("architecture")) == PLATFORM]
        if not matches:
            problems.append(f"{name}: index {desc['digest']} has no linux/amd64 manifest")
            return
        # containerd imports the best linux/amd64 match; any of them being incomplete is a hazard.
        for child in matches:
            check_image(layout, child, name, problems, depth + 1)
        return
    for d in [doc["config"]] + doc.get("layers", []):
        check_descriptor(layout, d, name, problems)


def main(path: str, refs_file: str) -> int:
    layout = Layout(path)
    index = layout.json("index.json")
    problems = []
    named = {}
    for entry in index.get("manifests", []):
        name = entry.get("annotations", {}).get("io.containerd.image.name")
        if not name:
            continue
        named[name] = entry
        check_image(layout, entry, name, problems)
    refs = [line.strip() for line in open(refs_file) if line.strip()]
    for ref in refs:
        for want in expected_names(ref):
            if want not in named:
                problems.append(f"{ref}: no image named {want} in the tarball")
            elif "@sha256:" in want and named[want]["digest"] != want.split("@", 1)[1]:
                problems.append(f"{ref}: {want} points at {named[want]['digest']}, not the pinned digest")
    if problems:
        print(f"image tarball {path} is NOT importable offline ({len(problems)} problem(s)):", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    print(f"image tarball complete: {len(named)} named image(s), {len(refs)} chart reference(s), linux/amd64")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: Test-ImageTarComplete.py <tarball-or-dir> <images.txt>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
