# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the release image build must be reliable from nothing.
#
# The bug this guards: a release build failed with
#   NETSDK1064: Package Microsoft.AspNetCore.OpenApi ... was not found
# at `dotnet publish`, and retrying with `--no-cache` could not clear it. Two independent causes,
# both in the .NET Dockerfiles rather than in any one build:
#
#   1. api and relay mounted the SAME BuildKit cache mount id (`cg-nuget`) with the default
#      `sharing=shared`, and the release built every component in parallel, so two restores could
#      write one directory at once.
#   2. `dotnet publish --no-restore` assumes the cache mount still holds what the restore layer put
#      there. A cache mount is reclaimable, so BuildKit's GC can drop it BETWEEN those two layers;
#      project.assets.json then names packages that are gone and --no-restore cannot recover.
#
# And the reason it looked unfixable: `--no-cache` skips the LAYER cache and leaves cache MOUNTS
# untouched. Only `docker builder prune --filter type=exec.cachemount` clears them.
#
# scripts/release/Build-PlatformImages.sh is the one supported way to build release images. It
# refuses a source tree that has regressed on (1) or (2), and its --clean prunes the cache mounts.
# This suite plants each regression and proves the gate catches it, and holds the --clean
# semantics, so none of it can quietly rot back.
#
# Runs with the rest of the suite: sudo python3 -m unittest discover -s test/appliance
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "release", "Build-PlatformImages.sh")

GOOD_DOCKERFILE = textwrap.dedent(
    """\
    FROM scratch AS build
    RUN --mount=type=secret,id=nuget_token,required=false \\
        --mount=type=cache,id=cg-nuget-api,sharing=locked,target=/root/.nuget/packages \\
        dotnet restore src/X/X.csproj --locked-mode
    COPY . .
    RUN --mount=type=secret,id=nuget_token,required=false \\
        --mount=type=cache,id=cg-nuget-api,sharing=locked,target=/root/.nuget/packages \\
        dotnet publish src/X/X.csproj -c Release -o /app/publish -p:RestoreLockedMode=true
    """
)


def run_gate(dockerfile_text, component="api"):
    """Run only the Dockerfile cache contract of Build-PlatformImages.sh against a source tree."""
    src = tempfile.mkdtemp()
    try:
        with open(os.path.join(src, "Dockerfile"), "w", encoding="utf-8") as fh:
            fh.write(dockerfile_text)
        # Source the script's function without running a build: the script is written so that
        # sourcing it with no arguments fails on argument validation, so the function is lifted
        # out with sed. This keeps the gate itself as the single definition.
        harness = textwrap.dedent(
            f"""\
            set -euo pipefail
            eval "$(sed -n '/^assert_dockerfile_cache_contract() {{/,/^}}/p' {SCRIPT!r})"
            assert_dockerfile_cache_contract {component} {src!r}
            """
        )
        return subprocess.run(
            ["bash", "-c", harness], capture_output=True, text=True, timeout=60
        )
    finally:
        shutil.rmtree(src, ignore_errors=True)


class BuildPlatformImagesGate(unittest.TestCase):
    def test_script_exists_and_is_executable_bash(self):
        self.assertTrue(os.path.isfile(SCRIPT), f"{SCRIPT} is missing")
        self.assertTrue(
            os.access(SCRIPT, os.X_OK),
            f"{SCRIPT} is not executable: Publish-GitHubRelease.sh once aborted a whole release "
            "because a committed release script was mode 100644 (installer #113).",
        )
        r = subprocess.run(["bash", "-n", SCRIPT], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_accepts_a_correct_dockerfile(self):
        r = run_gate(GOOD_DOCKERFILE)
        self.assertEqual(r.returncode, 0, f"the gate rejected a correct Dockerfile:\n{r.stderr}")

    def test_rejects_the_shared_cache_mount_id(self):
        planted = GOOD_DOCKERFILE.replace("cg-nuget-api", "cg-nuget")
        r = run_gate(planted)
        self.assertNotEqual(r.returncode, 0, "the shared cg-nuget mount id was not caught")
        self.assertIn("SHARED", r.stderr)

    def test_rejects_a_cache_mount_without_sharing_locked(self):
        planted = GOOD_DOCKERFILE.replace(",sharing=locked", "")
        r = run_gate(planted)
        self.assertNotEqual(r.returncode, 0, "a shared-by-default cache mount was not caught")
        self.assertIn("sharing=locked", r.stderr)

    def test_rejects_publish_no_restore(self):
        planted = GOOD_DOCKERFILE.replace(
            "-p:RestoreLockedMode=true", "--no-restore"
        )
        r = run_gate(planted)
        self.assertNotEqual(r.returncode, 0, "publish --no-restore was not caught")
        self.assertIn("NETSDK1064", r.stderr)

    def test_comments_are_not_read_as_instructions(self):
        # The real Dockerfiles carry a comment explaining why --no-restore and the shared
        # cg-nuget id were removed. A gate that greps the raw file flags its own documentation.
        commented = (
            "# id=cg-nuget was shared between api and relay; publish used --no-restore.\n"
            + GOOD_DOCKERFILE
        )
        r = run_gate(commented)
        self.assertEqual(
            r.returncode, 0, f"the gate flagged its own explanatory comment:\n{r.stderr}"
        )

    def test_ignores_a_dockerfile_with_no_cache_mount(self):
        r = run_gate("FROM scratch\nCOPY . .\n")
        self.assertEqual(r.returncode, 0, r.stderr)


class BuildPlatformImagesCleanSemantics(unittest.TestCase):
    """--clean must prune the cache mounts. --no-cache alone never did."""

    def setUp(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            self.text = fh.read()

    def test_clean_prunes_the_cache_mounts(self):
        self.assertIn(
            "docker builder prune -f --filter type=exec.cachemount",
            self.text,
            "--clean must prune BuildKit cache mounts; --no-cache does not touch them, which is "
            "exactly why the NETSDK1064 failure survived every 'clean' rebuild.",
        )

    def test_clean_also_passes_no_cache(self):
        self.assertIn("NOCACHE=(--no-cache)", self.text)

    def test_clean_refuses_without_a_nuget_token(self):
        # With an empty cache mount and no token the private CloudGrange.* feed is unreachable, so
        # restore fails for a reason that LOOKS like the cache bug. Refuse instead of misleading.
        self.assertIn("refusing --clean without a NuGet token", self.text)

    def test_each_component_logs_separately(self):
        # Parallel builds interleaving on one stream is how the original failure was misread.
        self.assertIn('> "$LOG_DIR/$comp.log" 2>&1', self.text)

    def test_reports_the_source_sha_the_release_requires(self):
        self.assertIn("--source-sha", self.text)


if __name__ == "__main__":
    unittest.main()
