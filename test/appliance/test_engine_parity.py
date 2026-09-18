# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9170 — install-mode parity.
#
# This exists because the same bug keeps recurring in the same shape: a capability is added to the
# Compose engine and the K3s engine never gets the equivalent, silently. Real examples already
# shipped that way -- the realm-admin bootstrap, the RELAY_ENROLLMENT_TOKEN env var, and the
# in-app updater, which K3s simply did not have at all while Compose had a 720-line one.
#
# A one-off manual review does not stop that: the next capability added to Compose reopens the
# gap. So parity is asserted here, and anything genuinely engine-specific has to be declared in
# EXPECTED_COMPOSE_ONLY with a reason, which forces the question to be answered rather than
# overlooked.
#
#   python3 -m unittest discover -s test/appliance -p 'test_engine_parity.py'
import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Compose units with no K3s systemd counterpart BY DESIGN, and why. Anything not listed here that
# exists only for Compose is treated as a parity gap.
EXPECTED_COMPOSE_ONLY = {
    "cloudgrange.service":
        "Compose needs a unit to bring the stack up at boot; under K3s the kubelet starts the "
        "workloads from the Helm release, so a host unit would be a second, competing owner.",
    "cloudgrange-realm-admin.service":
        "Ported to the chart as a Job (realm-admin-job.yaml) rather than a host unit, so it runs "
        "once per release like the other bootstrap Jobs.",
}


def read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8", errors="replace") as f:
        return f.read()


def units_in(directory, pattern):
    if not os.path.isdir(os.path.join(REPO, directory)):
        return set()
    return {
        name for name in os.listdir(os.path.join(REPO, directory))
        if name.endswith(".service") and re.search(pattern, name)
    }


class SystemdUnitParityTests(unittest.TestCase):
    def test_every_compose_unit_has_a_k3s_counterpart_or_a_declared_reason(self):
        compose_units = units_in("compose/systemd", r".")
        self.assertTrue(compose_units, "no Compose units found — has the layout moved?")

        k3s_units = units_in("appliance", r"k3s")
        # cloudgrange-updater.service -> cloudgrange-updater-k3s.service
        k3s_stems = {u.replace("-k3s.service", "") for u in k3s_units}

        gaps = []
        for unit in sorted(compose_units):
            stem = unit.replace(".service", "")
            if stem in k3s_stems:
                continue
            if unit in EXPECTED_COMPOSE_ONLY:
                continue
            gaps.append(unit)

        self.assertEqual(gaps, [],
                         "these Compose units have no K3s counterpart and no declared reason; "
                         "either port them or add them to EXPECTED_COMPOSE_ONLY with a reason:\n"
                         + "\n".join(gaps))

    def test_declared_exceptions_are_still_real(self):
        """Stops EXPECTED_COMPOSE_ONLY rotting into a list of units that no longer exist."""
        compose_units = units_in("compose/systemd", r".")
        stale = [u for u in EXPECTED_COMPOSE_ONLY if u not in compose_units]
        self.assertEqual(stale, [],
                         "EXPECTED_COMPOSE_ONLY lists units that no longer exist: " + ", ".join(stale))


class UpdaterParityTests(unittest.TestCase):
    """The updater was the largest parity gap: Compose had one, K3s had none (AB#9189)."""

    def test_both_engines_ship_an_updater(self):
        self.assertTrue(os.path.isfile(os.path.join(REPO, "compose/updater/cloudgrange-updater.py")))
        self.assertTrue(os.path.isfile(os.path.join(REPO, "scripts/cloudgrange-updater-k3s.py")),
                        "the K3s engine has no updater; an appliance without an in-app update path "
                        "means a customer has to reinstall to take a release")

    def test_the_k3s_updater_is_installed_by_every_path_that_produces_a_running_system(self):
        # Shipping the file is not enough -- it has to be installed and enabled, by BOTH the
        # appliance image build and a plain Linux install.
        generalize = read("appliance", "cloudgrange-generalize-k3s.sh")
        self.assertIn("cloudgrange-updater-k3s.service", generalize)
        self.assertIn("systemctl enable cloudgrange-updater-k3s", generalize)

        installer = read("scripts", "Install-CloudGrangeK3s.sh")
        self.assertIn("cloudgrange-updater-k3s.py", installer)
        # Defining install_updater is not enough — it has to be CALLED. Checking only that the
        # name appears passes while the call site is gone, because the definition still contains
        # it; that exact weakness let a deliberately-mutated installer through this gate once.
        call_sites = [
            line.strip() for line in installer.splitlines()
            if re.match(r"^\s*install_updater\s*$", line)
        ]
        self.assertTrue(call_sites,
                        "install_updater is defined but never called — a K3s install would come "
                        "up with no in-app updater and no error")

    def test_the_k3s_updater_is_shipped_inside_the_bundle(self):
        # The installer installs it FROM the bundle, so a bundle without it produces an install
        # with no updater and no error.
        bundler = read("scripts", "New-ReleaseBundleK3s.sh")
        self.assertIn("cloudgrange-updater-k3s.py", bundler)
        self.assertIn("cloudgrange-updater-k3s.service", bundler)

    def test_both_updaters_speak_the_same_status_schema(self):
        # The API and portal read one schema; if the engines diverge here the Updates page works
        # on one engine and silently shows nothing on the other.
        compose = read("compose", "updater", "cloudgrange-updater.py")
        k3s     = read("scripts", "cloudgrange-updater-k3s.py")
        self.assertIn('STATUS_SCHEMA = "cg-updater-status-v1"', compose)
        self.assertIn('STATUS_SCHEMA = "cg-updater-status-v1"', k3s)


class ApplianceStagingTests(unittest.TestCase):
    """AB#9189 — the appliance builder stages an EXPLICIT list of files onto the VM.

    A file the generalize script installs but nobody staged fails the whole appliance build at
    that step with "install: cannot stat ...". That happened for real: the updater was added to
    the generalize script and its two files were not added to these lists, so the build died after
    generalizing the VM (which is not repeatable — the VM's SSH keys are gone by then).
    """

    def setUp(self):
        self.builder = read("Build-CloudGrangeApplianceK3s.ps1")
        self.generalize = read("appliance", "cloudgrange-generalize-k3s.sh")

    def test_every_staged_file_the_generalize_script_installs_is_actually_staged(self):
        # Files the generalize script pulls out of the staging directory, by basename.
        referenced = set(re.findall(r'\$STAGE_DIR/(?:\.\./)?(?:appliance/|scripts/)?([\w.-]+\.(?:sh|py|service))',
                                    self.generalize))
        missing = sorted(name for name in referenced if name not in self.builder)
        self.assertEqual(missing, [],
                         "the generalize script installs these from the staging directory but "
                         "Build-CloudGrangeApplianceK3s.ps1 never uploads them, so the appliance "
                         "build dies after the VM is already generalized:\n" + "\n".join(missing))


class ChartWiringParityTests(unittest.TestCase):
    """Bugs in this class were all 'Compose set the env var, the chart never did'."""

    def test_api_deployment_sets_the_env_vars_the_compose_engine_sets(self):
        deployment = read("charts", "cloudgrange", "charts", "api", "templates", "deployment.yaml")
        # Each of these was a real, separately-diagnosed bug caused by the chart not setting it.
        for env in ("RELAY_ENROLLMENT_TOKEN", "CLOUDGRANGE_VERSION"):
            self.assertIn(env, deployment,
                          f"{env} is not set on the API pod; the Compose engine sets it, and the "
                          f"code that reads it silently no-ops when it is missing")

    def test_the_updates_directory_is_reachable_by_the_host_updater(self):
        # AB#9189: this was a PVC, which the host-side updater cannot read, so update requests
        # went somewhere nothing could see them.
        deployment = read("charts", "cloudgrange", "charts", "api", "templates", "deployment.yaml")
        self.assertIn("hostPath", deployment,
                      "the updates directory must be a hostPath on the appliance path — a PVC is "
                      "invisible to the updater service, which runs on the host")


if __name__ == "__main__":
    unittest.main()
