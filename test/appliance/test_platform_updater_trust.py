# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the in-cluster Platform updater's trust checks (images/platform-updater/entrypoint.sh),
# owner decision 2026-09-18: HTTPS + digest pinning, NO signing key required.
#
# Drives the shipped entrypoint's `verify` subcommand (the same resolve_release/check_manifest code
# `apply` runs, without a cluster) against a real local https server with its own CA:
#   - an UNSIGNED manifest whose SHA-256 matches the channel's latest.manifestSha256 is accepted;
#   - a manifest SHA-256 mismatch, a channel with no manifestSha256, an http:// channel, manifest or
#     chart, a manifest on another host, an unpinned image and a chart SHA-256 mismatch are refused;
#   - a signature is optional: a placeholder key is "no key"; a real key makes it mandatory.
# The full apply/rollback path, in a cluster, is test/e2e/platform-updater-kind.sh.
# Needs bash, curl, jq, sha256sum, openssl.
#   python3 -m unittest discover -s test/appliance -p 'test_platform_updater_trust.py'
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest

from test_foundation_updater import LocalHttpsServer

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENTRYPOINT = os.path.join(REPO, "images", "platform-updater", "entrypoint.sh")
V = "2609.0.0-rc.91"
DIGEST = "sha256:" + "a" * 64


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl") and shutil.which("openssl"), "needs jq, curl, openssl")
class PlatformUpdaterTrustTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cg-platform-trust-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.www = os.path.join(self.tmp, "www")
        os.makedirs(os.path.join(self.www, "releases"))
        self.server = LocalHttpsServer(self.www, self.tmp)
        self.addCleanup(self.server.close)

    def put(self, name, data):
        path = os.path.join(self.www, name)
        with open(path, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())
        return hashlib.sha256(open(path, "rb").read()).hexdigest()

    def publish(self, images=None, chart_url=None, chart_sha=None, manifest_url=None, manifest_sha=None,
                with_manifest_sha=True):
        """Publish a chart, a release manifest and an https channel; returns the channel URL."""
        real_chart_sha = self.put("releases/cloudgrange-%s.tgz" % V, b"not really a chart, only its bytes matter here")
        comps = images or {c: "ghcr.io/cloudgrange/cloudgrange-%s:%s@%s" % (c, V, DIGEST) for c in ("api", "portal", "relay")}
        manifest = {"schema": "cg-release-manifest-v1", "platform": V, "channel": "rc", "upgradeFrom": ">=2609.0.0-0",
                    "chart": {"url": chart_url or "%s/releases/cloudgrange-%s.tgz" % (self.server.base, V),
                              "sha256": chart_sha or real_chart_sha},
                    "components": {"cloudgrange-" + c: {"version": V, "image": i} for c, i in comps.items()}}
        sha = self.put("releases/manifest.json", json.dumps(manifest, indent=2))
        latest = {"version": V, "bundleUrl": self.server.base + "/b.zip", "sha256": "b" * 64,
                  "manifestUrl": manifest_url or self.server.base + "/releases/manifest.json"}
        if with_manifest_sha:
            latest["manifestSha256"] = manifest_sha or sha
        self.put("channel.json", json.dumps({"schema": "cg-onprem-channel-v1", "latest": latest}))
        return self.server.base + "/channel.json"

    def verify(self, channel_url, manifest_url=None, **env_extra):
        env = dict(os.environ, KUBECONFIG="/nonexistent", CLOUDGRANGE_UPDATE_CHANNEL_URL=channel_url,
                   CLOUDGRANGE_UPDATE_CA_FILE=self.server.ca, CLOUDGRANGE_SIGNING_KEY_FILE="/nonexistent",
                   CLOUDGRANGE_UPDATE_ALLOWED_HOSTS="", CLOUDGRANGE_RELEASE_NAME="cg", CLOUDGRANGE_NAMESPACE="cg")
        env.update(env_extra)
        args = ["bash", ENTRYPOINT, "verify", "--version", V]
        if manifest_url:
            args += ["--manifest-url", manifest_url]
        proc = subprocess.run(args, env=env, capture_output=True, text=True, timeout=120)
        return proc.returncode, proc.stdout + proc.stderr

    def assertAccepted(self, result):
        rc, out = result
        self.assertEqual(rc, 0, out)
        self.assertIn("VERIFIED: " + V, out)

    def assertRefused(self, result, why):
        rc, out = result
        self.assertNotEqual(rc, 0, out)
        self.assertIn("REFUSED", out)
        self.assertIn(why, out)

    # ---- accepted -------------------------------------------------------------------------------
    def test_unsigned_manifest_with_matching_sha256_is_accepted_without_a_key(self):
        rc, out = self.verify(self.publish())
        self.assertAccepted((rc, out))
        self.assertIn("no release signing key configured", out)

    def test_the_manifest_url_the_api_passes_is_accepted_when_it_is_the_channels(self):
        self.assertAccepted(self.verify(self.publish(), manifest_url=self.server.base + "/releases/manifest.json"))

    def test_the_channel_passed_as_manifest_url_works_without_configured_channel(self):
        ch = self.publish()
        self.assertAccepted(self.verify("", manifest_url=ch, CLOUDGRANGE_UPDATE_CHANNEL_URL=""))

    def test_placeholder_key_is_no_key(self):
        self.assertAccepted(self.verify(self.publish(), CLOUDGRANGE_SIGNING_KEY_FILE=os.path.join(REPO, "cloudgrange-signing-key.pub")))

    # ---- refused --------------------------------------------------------------------------------
    def test_manifest_sha256_mismatch_is_refused(self):
        self.assertRefused(self.verify(self.publish(manifest_sha="c" * 64)), "does not match the channel")

    def test_channel_without_manifest_sha256_is_refused(self):
        self.assertRefused(self.verify(self.publish(with_manifest_sha=False)), "latest.manifestSha256")

    def test_http_channel_is_refused(self):
        self.publish()
        self.assertRefused(self.verify(self.server.http_base + "/channel.json"), "must be https://")

    def test_http_manifest_is_refused(self):
        ch = self.publish(manifest_url=self.server.http_base + "/releases/manifest.json")
        self.assertRefused(self.verify(ch), "over https://")

    def test_http_chart_is_refused(self):
        ch = self.publish(chart_url="%s/releases/cloudgrange-%s.tgz" % (self.server.http_base, V))
        self.assertRefused(self.verify(ch), "the chart must be downloaded over https://")

    def test_manifest_on_another_host_is_refused_unless_allowed(self):
        other = self.server.other_host_base + "/releases/manifest.json"
        self.assertRefused(self.verify(self.publish(manifest_url=other)), "neither the update channel host")
        self.assertAccepted(self.verify(self.publish(manifest_url=other),
                                        CLOUDGRANGE_UPDATE_ALLOWED_HOSTS=other.split("/")[2]))

    def test_a_manifest_url_the_channel_does_not_list_is_refused(self):
        self.assertRefused(self.verify(self.publish(), manifest_url=self.server.base + "/elsewhere/manifest.json"),
                           "is not the one the channel lists")

    def test_unpinned_image_is_refused(self):
        images = {"api": "ghcr.io/cloudgrange/cloudgrange-api:%s" % V,
                  "portal": "ghcr.io/cloudgrange/cloudgrange-portal:%s@%s" % (V, DIGEST),
                  "relay": "ghcr.io/cloudgrange/cloudgrange-relay:%s@%s" % (V, DIGEST)}
        self.assertRefused(self.verify(self.publish(images=images)), "not pinned by @sha256 digest: cloudgrange-api")

    def test_chart_sha256_mismatch_is_refused(self):
        self.assertRefused(self.verify(self.publish(chart_sha="d" * 64)), "chart SHA-256 does not match")

    def test_untrusted_certificate_is_refused(self):
        self.assertRefused(self.verify(self.publish(), CLOUDGRANGE_UPDATE_CA_FILE="/nonexistent"),
                           "could not download the update channel")

    def test_a_real_key_makes_the_signature_mandatory(self):
        key, pub = os.path.join(self.tmp, "k.key"), os.path.join(self.tmp, "k.pub")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key], check=True)
        subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
        self.assertRefused(self.verify(self.publish(), CLOUDGRANGE_SIGNING_KEY_FILE=pub), "has no signature")


if __name__ == "__main__":
    unittest.main()
