# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — prerequisites for the appliance release-gate tests. A missing prerequisite (root, the docker CLI
# with the compose plugin, PyYAML) FAILS the test run, so a CI or release runner change cannot silently skip
# a gate. A local developer may skip instead by setting CLOUDGRANGE_TEST_ALLOW_SKIP=1 explicitly.
import os
import subprocess
import unittest

ALLOW_SKIP_ENV = "CLOUDGRANGE_TEST_ALLOW_SKIP"


def require(condition, what):
    if condition:
        return
    if os.environ.get(ALLOW_SKIP_ENV) == "1":
        raise unittest.SkipTest("%s not available (skipped because %s=1)" % (what, ALLOW_SKIP_ENV))
    raise AssertionError("%s is required by this release gate test; it FAILS instead of skipping. "
                         "For local development only, set %s=1 to skip." % (what, ALLOW_SKIP_ENV))


def is_root():
    return hasattr(os, "geteuid") and os.geteuid() == 0


def have_compose():
    try:
        return subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


def have_yaml():
    try:
        import yaml  # noqa: F401
        return True
    except ImportError:
        return False


def have_command(name):
    from shutil import which
    return which(name) is not None
