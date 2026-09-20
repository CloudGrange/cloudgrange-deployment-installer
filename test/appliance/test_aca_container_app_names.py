# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (E9) — an Azure Container App name must end in an alphanumeric character.
#
# The bug: iac/resources.bicep clamped the CAF-pattern app names to Azure's 32-character limit
# with a bare substring. Whether the 32nd character is a hyphen depends on how long the region
# code is, so the identical template deployed in one region and was refused in another:
#
#   eastus  regionCode 'eus'  ca-cloudgrange-portal-prod-eus-001 (34) -> ...-prod-eus-0   accepted
#   westus3 regionCode 'wus3' ca-cloudgrange-portal-test-wus3-001 (35) -> ...-test-wus3-  REFUSED
#
# The refusal is ContainerAppInvalidName, and it arrives at the very end of a ~15 minute
# deployment, after the PostgreSQL server, the Key Vault and the environment are all built. It
# cannot be caught earlier: the provider validates the name only on create, so `az deployment sub
# what-if` passes clean. That is why this is a static gate over the naming rule and not a
# deployment-time check.
#
# What this holds:
#   1. every Container App name in the template goes through trimTrailingHyphens after its clamp;
#   2. the rule itself is right — modelled here and checked against Azure's documented name regex
#      for a matrix of real region codes, environments and instances, including the exact
#      combination that failed;
#   3. a name that already fits is returned unchanged, so applying this does not rename an app in
#      an existing deployment.
#
# Runs with the rest of the suite: sudo python3 -m unittest discover -s test/appliance
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESOURCES = os.path.join(REPO, "iac", "resources.bicep")

# https://learn.microsoft.com/azure/container-apps — lower-case alphanumeric or '-', starts with a
# letter, ends alphanumeric, no '--', 2..32 characters.
ACA_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}[a-z0-9]$")


def caf_with_role(abbr, workload, role, env, region, instance):
    return f"{abbr}-{workload}-{role}-{env}-{region}-{instance}"


def effective_app_name(raw):
    """The rule iac/resources.bicep implements: clamp to 32, then drop trailing hyphens."""
    name = raw[:32] if len(raw) > 32 else raw
    return name.rstrip("-")


class ContainerAppNamesAreValidInEveryRegion(unittest.TestCase):
    def setUp(self):
        with open(RESOURCES, encoding="utf-8") as fh:
            self.bicep = fh.read()

    def test_every_container_app_name_is_trimmed_after_the_clamp(self):
        for var in ("portalAppNameEffective", "keycloakAppNameEffective", "relayAppNameEffective"):
            line = [l for l in self.bicep.splitlines() if l.startswith(f"var {var} ")]
            self.assertEqual(1, len(line), f"{var} not found exactly once")
            self.assertIn(
                "trimTrailingHyphens", line[0],
                f"{var} clamps to 32 without trimming trailing hyphens, so it produces a name "
                f"Azure refuses with ContainerAppInvalidName in any region whose code makes the "
                f"32nd character a hyphen")

    def test_the_helper_exists_and_handles_two_trailing_hyphens(self):
        self.assertIn("func trimTrailingHyphens(value string) string", self.bicep)
        # The bicep drops at most two; the model must not claim more than the template does.
        self.assertEqual("ca-cloudgrange-portal-test", effective_app_name("ca-cloudgrange-portal-test--"))

    def test_the_rule_produces_a_valid_name_for_every_realistic_deployment(self):
        bad = []
        for workload in ("cloudgrange", "cg"):
            for role in ("api", "portal", "kc", "relay"):
                for env in ("dev", "test", "stage", "prod"):
                    for region in ("eus", "eus2", "wus", "wus2", "wus3", "cus", "weu", "neu", "sea"):
                        for instance in ("001", "002", "1"):
                            raw = caf_with_role("ca", workload, role, env, region, instance)
                            name = effective_app_name(raw)
                            if not ACA_NAME.match(name) or "--" in name:
                                bad.append(f"{raw} -> {name}")
        self.assertEqual([], bad, "invalid Container App names:\n" + "\n".join(bad[:20]))

    def test_the_exact_combination_that_failed_is_now_valid(self):
        raw = caf_with_role("ca", "cloudgrange", "portal", "test", "wus3", "001")
        self.assertEqual("ca-cloudgrange-portal-test-wus3-", raw[:32],
                         "the pre-fix clamp no longer reproduces; this test has drifted")
        name = effective_app_name(raw)
        self.assertEqual("ca-cloudgrange-portal-test-wus3", name)
        self.assertRegex(name, ACA_NAME)

    def test_a_name_that_already_fits_is_unchanged(self):
        raw = caf_with_role("ca", "cloudgrange", "api", "test", "wus3", "001")
        self.assertLessEqual(len(raw), 32)
        self.assertEqual(raw, effective_app_name(raw))

    # Compilation is not asserted here: the only `az` reachable from WSL is the Windows binary,
    # which cannot read a /mnt path, so the check would be a coin flip rather than a gate. The
    # template's build is covered by the repo's Bicep lint workflow and was run by hand for this
    # change (`az bicep build --file iac/resources.bicep`, exit 0).


if __name__ == "__main__":
    unittest.main()
