# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the release must really be able to build the Azure Container Apps installer asset.
#
# The bug: Publish-GitHubRelease.sh built Install-CloudGrange-Aca.zip by running
#     "$(dirname "$0")/New-AcaInstallerZip.sh" --out "$WORK/aca"
# as a command, but that file was committed mode 100644. Every other sibling call in this repo
# goes through `bash <script>`, so nothing else depended on the mode bit and nobody noticed. On a
# clean checkout the step died with "Permission denied", the GitHub release went out WITHOUT the
# asset, and the public Container Apps install guide told operators to download a file that was
# not there. It survived because no release had been cut between the asset being wired in and the
# 2609.0.0-preview.27 run, which is exactly where it fired.
#
# What this gate holds:
#   1. New-AcaInstallerZip.sh is mode 100755 in the GIT INDEX (checkout mode is not enough: the
#      index is what a fresh clone gets, and a Windows working tree reports 755 for everything);
#   2. any sibling .sh this repo invokes as a bare command — rather than as an argument to
#      bash/sh/source — is likewise 100755;
#   3. the builder actually runs the way the publisher runs it and produces an archive that
#      carries the wrapper and its Bicep, so the documented download is a real installer.
#
# Runs with the rest of the suite: sudo python3 -m unittest discover -s test/appliance
import os
import re
import subprocess
import tempfile
import unittest
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ACA_ZIP_BUILDER = "scripts/release/New-AcaInstallerZip.sh"
PUBLISHER = "scripts/release/Publish-GitHubRelease.sh"

# `"$(dirname "$0")/Name.sh"` — the sibling-invocation idiom used in this repo. The character
# class must be "not a paren", not "not a quote": the substitution itself contains quotes
# (`$(dirname "$0")`), and a `[^"]*` version silently matches nothing, which makes this whole
# check vacuous. It was written that way first and passed against the real defect.
SIBLING = re.compile(r'"\$\([^()]*dirname[^()]*\)/([A-Za-z0-9._-]+\.sh)"')


def index_modes():
    """Modes from the git index. Skips where git cannot read the checkout (a Windows-created
    worktree is unreadable from WSL), so the gate is authoritative in a clone and never a
    spurious failure elsewhere."""
    probe = subprocess.run(["git", "-C", REPO, "ls-files", "-s", "*.sh"],
                           capture_output=True, text=True)
    if probe.returncode != 0:
        raise unittest.SkipTest(f"git cannot read this checkout: {probe.stderr.strip()[:200]}")
    out = probe.stdout
    modes = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        modes[line.split("\t", 1)[1]] = line.split(" ", 1)[0]
    return modes


class AcaInstallerAssetIsBuildable(unittest.TestCase):
    def setUp(self):
        self.modes = index_modes()

    def test_the_aca_installer_zip_builder_is_executable_in_the_git_index(self):
        self.assertIn(ACA_ZIP_BUILDER, self.modes)
        self.assertEqual(
            "100755", self.modes[ACA_ZIP_BUILDER],
            "New-AcaInstallerZip.sh must be executable in the index: Publish-GitHubRelease.sh "
            "builds Install-CloudGrange-Aca.zip with it, and the public Container Apps install "
            "guide tells operators to download that asset. Mode 100644 published a release "
            "without it.")

    def test_no_sibling_script_is_run_as_a_bare_command_unless_it_is_executable(self):
        bad = []
        for path, _mode in sorted(self.modes.items()):
            if path.startswith(("archive/", "experiments/")):
                continue
            with open(os.path.join(REPO, path), encoding="utf-8") as fh:
                for n, raw in enumerate(fh, 1):
                    line = raw.strip()
                    if line.startswith("#"):
                        continue
                    for m in SIBLING.finditer(line):
                        before = line[:m.start()].rstrip()
                        if re.search(r'(?:^|[;&|(]\s|\s)(bash|sh|source|\.)$', before) \
                                or before.endswith(("bash", "sh", "source", ".")):
                            continue          # run by an interpreter: the mode bit is not read
                        if before.endswith(("$(cd", "(cd", "cd")) or "dirname" in m.group(0) and "/.." in line:
                            continue          # a path expression, not an invocation
                        callee = m.group(1)
                        for p, mode in self.modes.items():
                            if os.path.basename(p) == callee and mode != "100755":
                                bad.append(f"{path}:{n} runs {callee} as a bare command, but "
                                           f"{p} is mode {mode} in the git index")
        self.assertEqual([], bad, "\n".join(bad))

    def test_the_builder_produces_an_archive_carrying_the_wrapper_and_its_templates(self):
        with tempfile.TemporaryDirectory() as out:
            r = subprocess.run(["bash", os.path.join(REPO, ACA_ZIP_BUILDER), "--out", out],
                               capture_output=True, text=True)
            self.assertEqual(0, r.returncode, r.stderr[-2000:])
            zip_path = os.path.join(out, "Install-CloudGrange-Aca.zip")
            self.assertTrue(os.path.isfile(zip_path), os.listdir(out))
            names = zipfile.ZipFile(zip_path).namelist()
        self.assertIn("scripts/Install-CloudGrange-Aca.sh", names)
        self.assertTrue([n for n in names if n.endswith(".bicep")],
                        "the archive carries no Bicep; the wrapper has nothing to deploy")

    def test_the_publisher_still_builds_and_uploads_the_aca_asset(self):
        with open(os.path.join(REPO, PUBLISHER), encoding="utf-8") as fh:
            body = fh.read()
        self.assertIn("New-AcaInstallerZip.sh", body)
        self.assertIn("Install-CloudGrange-Aca.zip", body)


if __name__ == "__main__":
    unittest.main()
