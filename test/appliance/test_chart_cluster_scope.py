# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the cluster-scope gate for charts/cloudgrange.
#
# The in-cluster Platform updater is namespace-scoped by design (plan 2026-09-18
# foundation-platform-separation §4). It is therefore UNABLE to apply a chart version that adds,
# changes or removes a cluster-scoped object, and it can never grant itself the right to, because
# granting RBAC requires already holding what you grant. The live failure this guards:
#
#   a bring-your-own-Kubernetes release installed with 2609.0.0-preview.12 (certManager.installOperator
#   defaulted to FALSE, so the release had no cluster-scoped objects and no cluster-scoped rights at
#   all) could not take ANY later in-app update, because the newer chart defaults installOperator to
#   TRUE and rendered a cluster-scoped ClusterIssuer plus the updater's own ClusterRole and
#   ClusterRoleBinding. `helm upgrade` died with "clusterissuers.cert-manager.io is forbidden ... at
#   the cluster scope" after the database backup, and the update auto-rolled back.
#   Reproduced and fixed on kind v1.34.
#
# The invariants below are what keep that from coming back:
#   1. NO profile renders a ClusterIssuer. The self-signed issuer is a namespaced Issuer.
#   2. The bring-your-own-Kubernetes DEFAULTS render nothing cluster-scoped and nothing outside the
#      release namespace at all.
#   3. Cluster-scoped objects appear only with the log shipper (observability.promtail.enabled),
#      which no BYO profile turns on.
#   4. The updater's ClusterRole grants no `create` on clusterissuers: RBAC ignores resourceNames for
#      `create`, so such a grant would be cluster-wide, and the fix is to stay namespaced instead.
#
#   python3 -m unittest discover -s test/appliance -p 'test_chart_cluster_scope.py'
import os
import shutil
import subprocess
import unittest

import gate_requirements as gate

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHART = os.path.join(REPO, "charts", "cloudgrange")

# Every kind this chart has ever rendered outside a namespace.
CLUSTER_SCOPED_KINDS = {"ClusterRole", "ClusterRoleBinding", "ClusterIssuer", "Namespace",
                        "CustomResourceDefinition", "StorageClass", "PriorityClass",
                        "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration"}

# label -> extra `helm template` arguments. The first is what a plain BYO `helm install` does.
PROFILES = {
    "byo defaults": [],
    "byo + installOperator": ["--set", "certManager.installOperator=true"],
    "byo + own issuerRef": ["--set", "certManager.installOperator=true",
                            "--set", "certManager.issuerRef.name=corp-ca"],
    "single-node": ["-f", os.path.join(CHART, "values-single-node.yaml")],
    "multi-node": ["-f", os.path.join(CHART, "values-multi-node.yaml")],
    "azure": ["-f", os.path.join(CHART, "values-azure.yaml"),
              "--set", "global.aks.keyVaultName=kv", "--set", "global.aks.tenantId=t",
              "--set", "global.aks.managedIdentityClientId=c"],
}

BYO_PROFILES = ["byo defaults", "byo + installOperator", "byo + own issuerRef"]


def render(extra):
    """helm template with the cert-manager and Traefik CRDs pretended present, so the
    Capabilities-guarded templates (Certificate/Issuer, TLSStore) actually render."""
    cmd = ["helm", "template", "cg", CHART, "-n", "cloudgrange",
           "--set", "global.hostname=cg.example.com",
           "--api-versions", "cert-manager.io/v1",
           "--api-versions", "cert-manager.io/v1/Certificate",
           "--api-versions", "cert-manager.io/v1/Issuer",
           "--api-versions", "traefik.io/v1alpha1/TLSStore"] + list(extra)
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        raise AssertionError("helm template failed: %s" % (done.stderr.strip()[-800:],))
    return done.stdout


def objects(manifest):
    """[(kind, name, namespace)] for a rendered multi-document manifest."""
    import yaml
    out = []
    for doc in yaml.safe_load_all(manifest):
        if not isinstance(doc, dict) or not doc.get("kind"):
            continue
        meta = doc.get("metadata") or {}
        out.append((doc["kind"], meta.get("name"), meta.get("namespace")))
    return out


class ChartClusterScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        gate.require(gate.have_command("helm"), "helm")
        gate.require(gate.have_yaml(), "PyYAML")
        cls.rendered = {label: render(extra) for label, extra in PROFILES.items()}

    def test_no_profile_renders_a_clusterissuer(self):
        """The self-signed issuer must stay namespaced: a ClusterIssuer cannot be created by the
        namespace-scoped updater, and `create` on clusterissuers cannot be granted by name."""
        for label, manifest in self.rendered.items():
            with self.subTest(profile=label):
                names = [n for k, n, _ in objects(manifest) if k == "ClusterIssuer"]
                self.assertEqual([], names,
                                 "%s renders a ClusterIssuer; use a namespaced Issuer instead "
                                 "(AB#9171: it breaks every in-app update on BYO Kubernetes)" % label)

    def test_byo_profiles_render_nothing_outside_the_release_namespace(self):
        for label in BYO_PROFILES:
            with self.subTest(profile=label):
                stray = [(k, n, ns) for k, n, ns in objects(self.rendered[label])
                         if k in CLUSTER_SCOPED_KINDS or (ns not in (None, "", "cloudgrange"))]
                self.assertEqual([], stray,
                                 "%s renders objects the in-cluster updater cannot manage: %s" % (label, stray))

    def test_cluster_scoped_objects_only_come_with_the_log_shipper(self):
        with_promtail = render(["--set", "observability.promtail.enabled=true"])
        kinds = {k for k, _, _ in objects(with_promtail) if k in CLUSTER_SCOPED_KINDS}
        self.assertEqual({"ClusterRole", "ClusterRoleBinding"}, kinds,
                         "promtail should add exactly a ClusterRole and a ClusterRoleBinding")
        self.assertEqual(set(), {k for k, _, _ in objects(self.rendered["byo defaults"])
                                 if k in CLUSTER_SCOPED_KINDS})

    def test_the_updater_clusterrole_cannot_create_clusterissuers(self):
        import yaml
        with_promtail = render(["--set", "observability.promtail.enabled=true"])
        role = next(d for d in yaml.safe_load_all(with_promtail)
                    if isinstance(d, dict) and d.get("kind") == "ClusterRole"
                    and d["metadata"]["name"] == "cg-platform-updater")
        for rule in role["rules"]:
            if "clusterissuers" in rule.get("resources", []):
                self.assertNotIn("create", rule["verbs"],
                                 "RBAC ignores resourceNames for `create`, so this would be a "
                                 "cluster-wide grant; keep the issuer namespaced instead")
                self.assertIn("delete", rule["verbs"],
                              "a release installed before AB#9171 needs `delete` to retire its "
                              "legacy <release>-selfsigned ClusterIssuer")
                break
        else:
            self.fail("the updater ClusterRole no longer mentions clusterissuers; legacy releases "
                      "need `delete` on <release>-selfsigned to migrate to the namespaced Issuer")

    def test_the_updater_uses_reset_then_reuse_values(self):
        """--reuse-values drops every default the new chart adds; that broke the in-app updates to
        2609.0.0-preview.18/.19 with a nil pointer on .Values.airgap."""
        with open(os.path.join(REPO, "images", "platform-updater", "entrypoint.sh"), encoding="utf-8") as f:
            body = f.read()
        self.assertIn("HELM_VALUES_FLAG=--reset-then-reuse-values", body)
        import re
        for line in body.splitlines():
            if line.strip().startswith("#") or "helm upgrade" not in line:
                continue
            self.assertIsNone(re.search(r"(?<!reset-then-)--reuse-values", line),
                              "the updater must not upgrade with --reuse-values: %s" % line.strip())


if __name__ == "__main__":
    unittest.main()
