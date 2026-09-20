# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — release-artifact provenance (scripts/release/image-provenance.sh).
#
# Nothing used to prove which source commit a released container image came from. A stale label
# cost five rebuilds, and the release tooling has a "retag an unchanged image" path
# (--already-pushed, and retagging a previous release's digest) where an image was once retagged
# from a build that PREDATED the fix it was supposed to carry (the relay, preview.10).
#
# What this gate holds:
#   1. every `docker build` / `docker buildx build` the release tooling runs stamps the image with
#      org.opencontainers.image.revision and .version from the shared helper — removing the stamp
#      from any call site fails here;
#   2. cg_assert_image_provenance really refuses: a wrong revision, a missing revision label, a
#      wrong version and an unreadable image are each a non-zero exit with a message naming the
#      image, the expected value and the found value — the real function is run against a fake
#      `crane`/`docker` on PATH, so the checking code itself is exercised, not a description of it;
#   3. New-PlatformRelease.sh calls the assertion on every path that publishes an image, including
#      the retag and --already-pushed paths, and requires --source-sha for every component before
#      anything is pulled, tagged or pushed — removing the assertion fails here;
#   4. cg_provenance_labels refuses a dirty source tree (a revision label naming HEAD while the
#      working tree differs from it is the exact lie this is meant to prevent).
#
# Runs with the rest of the suite: sudo python3 -m unittest discover -s test/appliance
import json
import os
import re
import stat
import subprocess
import tempfile
import textwrap
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(REPO, "scripts", "release", "image-provenance.sh")
PLATFORM_RELEASE = os.path.join(REPO, "scripts", "release", "New-PlatformRelease.sh")
PORTAL_BUILD = os.path.join(REPO, "scripts", "release", "Build-PortalImage.sh")
UPDATER_BUILD = os.path.join(REPO, "images", "platform-updater", "build.sh")

SHA_OK = "a" * 40
SHA_OTHER = "b" * 40
VERSION = "2609.0.0-preview.12"


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class FakeRegistry(object):
    """A directory on PATH holding a fake `crane` (and no docker) that serves one image config."""

    def __init__(self, labels):
        self.dir = tempfile.mkdtemp(prefix="cg-prov-")
        config = {"config": {"Labels": labels}} if labels is not None else {"config": {}}
        with open(os.path.join(self.dir, "config.json"), "w", encoding="utf-8") as fh:
            json.dump(config, fh)
        self._write("crane", textwrap.dedent(
            """\
            #!/bin/bash
            # fake crane: `crane config [--platform P] <ref>` prints the staged image config.
            [ "$1" = config ] || exit 2
            cat "$(dirname "$0")/config.json"
            """))
        # A `docker` that never has the image locally, so the helper falls through to crane.
        self._write("docker", "#!/bin/bash\nexit 1\n")

    def _write(self, name, body):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def assert_provenance(self, ref, want_sha, want_version, mode="remote"):
        """Run the REAL cg_assert_image_provenance against this fake registry."""
        env = dict(os.environ, PATH=self.dir + os.pathsep + os.environ.get("PATH", ""))
        script = '. "%s"\ncg_assert_image_provenance "$@"\n' % HELPER
        return subprocess.run(["bash", "-c", script, "bash", ref, want_sha, want_version, mode],
                              capture_output=True, text=True, env=env)


class ProvenanceAssertionTest(unittest.TestCase):
    """The gate refuses, and says why. Each case runs the real shell function."""

    def test_matching_labels_pass(self):
        reg = FakeRegistry({"org.opencontainers.image.revision": SHA_OK,
                            "org.opencontainers.image.version": VERSION})
        r = reg.assert_provenance("ghcr.io/cloudgrange/cloudgrange-relay@sha256:" + "0" * 64, SHA_OK, VERSION)
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn("[provenance]", r.stdout)

    def test_wrong_revision_is_refused(self):
        """The burn: an image built from a commit that predates the fix it should carry."""
        ref = "ghcr.io/cloudgrange/cloudgrange-relay:%s" % VERSION
        reg = FakeRegistry({"org.opencontainers.image.revision": SHA_OTHER,
                            "org.opencontainers.image.version": VERSION})
        r = reg.assert_provenance(ref, SHA_OK, VERSION)
        self.assertNotEqual(0, r.returncode, "a wrong revision must stop the release")
        self.assertIn("PROVENANCE FAILURE", r.stderr)
        self.assertIn(ref, r.stderr)          # names the image
        self.assertIn(SHA_OTHER, r.stderr)    # names the found SHA
        self.assertIn(SHA_OK, r.stderr)       # names the expected SHA

    def test_missing_revision_label_is_refused(self):
        ref = "ghcr.io/cloudgrange/cloudgrange-api:%s" % VERSION
        reg = FakeRegistry({"org.opencontainers.image.version": VERSION})
        r = reg.assert_provenance(ref, SHA_OK, VERSION)
        self.assertNotEqual(0, r.returncode, "a missing revision label must stop the release")
        self.assertIn("carries no org.opencontainers.image.revision label", r.stderr)
        self.assertIn(SHA_OK, r.stderr)

    def test_no_labels_at_all_is_refused(self):
        reg = FakeRegistry(None)
        r = reg.assert_provenance("ghcr.io/cloudgrange/cloudgrange-api:%s" % VERSION, SHA_OK, VERSION)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("PROVENANCE FAILURE", r.stderr)

    def test_wrong_version_is_refused(self):
        """A hand-retagged older digest published under the new tag: right source, wrong build."""
        reg = FakeRegistry({"org.opencontainers.image.revision": SHA_OK,
                            "org.opencontainers.image.version": "2609.0.0-preview.10"})
        r = reg.assert_provenance("ghcr.io/cloudgrange/cloudgrange-relay:%s" % VERSION, SHA_OK, VERSION)
        self.assertNotEqual(0, r.returncode, "an image built as another version must stop the release")
        self.assertIn("built as version 2609.0.0-preview.10", r.stderr)
        self.assertIn(VERSION, r.stderr)

    def test_unreadable_image_is_refused_not_ignored(self):
        reg = FakeRegistry({"org.opencontainers.image.revision": SHA_OK,
                            "org.opencontainers.image.version": VERSION})
        reg._write("crane", "#!/bin/bash\nexit 1\n")
        r = reg.assert_provenance("ghcr.io/cloudgrange/cloudgrange-api:%s" % VERSION, SHA_OK, VERSION)
        self.assertNotEqual(0, r.returncode, "an image whose labels cannot be read must never read as good")

    def test_expected_revision_must_be_a_full_sha(self):
        reg = FakeRegistry({"org.opencontainers.image.revision": "deadbeef",
                            "org.opencontainers.image.version": VERSION})
        r = reg.assert_provenance("ghcr.io/cloudgrange/cloudgrange-api:%s" % VERSION, "deadbeef", VERSION)
        self.assertNotEqual(0, r.returncode, "a short/abbreviated expected SHA must not be accepted")


class ProvenanceLabelTest(unittest.TestCase):
    def _git(self, *args, **kw):
        return subprocess.run(["git"] + list(args), cwd=kw.get("cwd"), capture_output=True, text=True,
                              env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))

    def _labels(self, src, version, env=None):
        script = ('. "%s"\ncg_provenance_labels "$1" "$2" || exit 1\nprintf "%%s\\n" "${CG_PROVENANCE_LABELS[@]}"\n'
                  % HELPER)
        return subprocess.run(["bash", "-c", script, "bash", src, version],
                              capture_output=True, text=True, env=dict(os.environ, **(env or {})))

    def test_labels_carry_head_and_version(self):
        src = tempfile.mkdtemp(prefix="cg-prov-src-")
        self._git("init", "-q", cwd=src)
        open(os.path.join(src, "f"), "w").close()
        self._git("add", "f", cwd=src)
        self._git("commit", "-qm", "x", cwd=src)
        head = self._git("rev-parse", "HEAD", cwd=src).stdout.strip()
        r = self._labels(src, VERSION)
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn("org.opencontainers.image.revision=" + head, r.stdout)
        self.assertIn("org.opencontainers.image.version=" + VERSION, r.stdout)

    def test_dirty_tree_is_refused(self):
        src = tempfile.mkdtemp(prefix="cg-prov-src-")
        self._git("init", "-q", cwd=src)
        open(os.path.join(src, "f"), "w").close()
        self._git("add", "f", cwd=src)
        self._git("commit", "-qm", "x", cwd=src)
        with open(os.path.join(src, "f"), "w") as fh:
            fh.write("changed\n")
        r = self._labels(src, VERSION)
        self.assertNotEqual(0, r.returncode, "a dirty tree would stamp a commit that is not what is built")
        self.assertIn("uncommitted changes", r.stderr)

    def test_non_git_source_is_refused(self):
        src = tempfile.mkdtemp(prefix="cg-prov-src-")
        r = self._labels(src, VERSION)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("not a git checkout", r.stderr)


class EveryBuildIsStampedTest(unittest.TestCase):
    """Removing the stamp from any release build call site fails here."""

    # Every script in the repo that builds a first-party image for a release.
    BUILD_SCRIPTS = [PORTAL_BUILD, UPDATER_BUILD]

    def test_no_unstamped_build_call_site_exists(self):
        """Find EVERY docker build in the release tooling, not just the ones we know about."""
        found = []
        for root, dirs, files in os.walk(REPO):
            dirs[:] = [d for d in dirs if d not in (".git", "archive", "experiments", "docs")]
            rel_root = os.path.relpath(root, REPO).replace(os.sep, "/")
            if not (rel_root.startswith("scripts/release") or rel_root.startswith("images")):
                continue
            for name in files:
                if not name.endswith(".sh"):
                    continue
                path = os.path.join(root, name)
                for line in read(path).splitlines():
                    # docker at command position only, so a usage string mentioning "docker build"
                    # is not mistaken for a call site.
                    if (re.search(r"(?:^\s*|[;&|]\s*|\bexec\s+)docker\s+(?:buildx\s+)?build\b", line)
                            and not line.lstrip().startswith("#")):
                        found.append((path, line.strip()))
        self.assertTrue(found, "no docker build call site found at all: has the release tooling moved?")
        for path, line in found:
            self.assertIn('"${CG_PROVENANCE_LABELS[@]}"', line,
                          "%s builds an image without the provenance labels: %s" % (path, line))

    def test_each_build_script_sources_the_helper_and_asserts(self):
        for path in self.BUILD_SCRIPTS:
            body = read(path)
            self.assertIn("image-provenance.sh", body, "%s does not source the provenance helper" % path)
            self.assertIn("cg_provenance_labels", body, "%s does not compute the provenance labels" % path)
            self.assertIn("cg_assert_image_provenance", body,
                          "%s does not read its own image's labels back" % path)


class PlatformReleaseAssertsProvenanceTest(unittest.TestCase):
    """New-PlatformRelease.sh must not be able to publish an unproved image."""

    BODY = None

    @classmethod
    def setUpClass(cls):
        cls.BODY = read(PLATFORM_RELEASE)

    def test_sources_the_shared_helper(self):
        self.assertIn("image-provenance.sh", self.BODY)

    def test_requires_a_source_sha_per_component(self):
        self.assertIn("--source-sha", self.BODY)
        self.assertRegex(self.BODY, r"SOURCE_SHA\[\$comp\]",
                         "the release must demand the source HEAD of every component")

    def test_asserts_the_published_image(self):
        self.assertGreaterEqual(self.BODY.count("cg_assert_image_provenance"), 2,
                                "the release must assert both before a retag and on the published bytes")
        self.assertIn('cg_assert_image_provenance "$repo@$digest" "$want_sha" "$want_ver" remote', self.BODY,
                      "the PUBLISHED image (by digest) must be the thing that is checked")

    def test_retag_path_is_checked_before_the_push(self):
        """The path that burned us: an 'unchanged' image retagged from an older build."""
        self.assertIn('cg_assert_image_provenance "$src" "$want_sha" "$want_ver" local', self.BODY,
                      "a retagged source image must be refused before it is tagged and pushed")

    def test_source_sha_is_demanded_for_already_pushed_too(self):
        """--already-pushed publishes images it did not build: it is exactly the path to check."""
        self.assertRegex(self.BODY, r'if \[ "\$PUSH" != 0 \]; then\n\s+missing=\(\)',
                         "--source-sha must be required for --push AND --already-pushed")

    def test_arg_parser_refuses_a_short_sha(self):
        r = subprocess.run(["bash", PLATFORM_RELEASE, "--version", VERSION, "--out", tempfile.mkdtemp(),
                            "--chart-base-url", "https://example.invalid/r", "--source-sha", "api=deadbeef"],
                           capture_output=True, text=True)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("not a full 40-hex commit sha", r.stderr)

    def test_already_pushed_without_source_sha_is_refused_before_anything_runs(self):
        r = subprocess.run(["bash", PLATFORM_RELEASE, "--version", VERSION, "--out", tempfile.mkdtemp(),
                            "--chart-base-url", "https://example.invalid/r", "--already-pushed"],
                           capture_output=True, text=True)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("--source-sha", r.stderr)
        for comp in ("cloudgrange-api", "cloudgrange-portal", "cloudgrange-relay",
                     "cloudgrange-platform-updater"):
            self.assertIn(comp, r.stderr)

    def test_manifest_records_the_proved_revision(self):
        self.assertIn('components[name]["revision"] = revision', self.BODY)


if __name__ == "__main__":
    unittest.main()
