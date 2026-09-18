# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9182 — the two qualification gates the restructure plan requires of the K3s installer that
# were never actually built: "interrupt at every checkpoint and resume" and "uninstall/retention".
#
# These drive the REAL scripts/Install-CloudGrangeK3s.sh, not a reimplementation of its state
# machine. Every external command it shells out to (k3s, helm, curl, systemctl, ...) is replaced
# by a stub on PATH that records its invocation, so the test exercises the script's actual stage
# ordering, checkpoint writes and resume logic without needing a cluster. A test that reimplemented
# the state machine would pass while the shipped script was broken, which is the failure mode this
# whole gate exists to prevent.
#
#   python3 -m unittest discover -s test/appliance -p 'test_install_qualification.py'
import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
INSTALLER = os.path.join(REPO, "scripts", "Install-CloudGrangeK3s.sh")

# The ordered stage contract the installer promises. The plan's gate is specifically that an
# interruption at ANY of these resumes correctly, so the test is parameterised over all of them.
STAGES = ["prereqs-checked", "k3s-installed", "certmanager-installed", "chart-installed", "ready"]

# Commands the installer invokes that must not touch the host running the test.
STUBBED = ["k3s", "helm", "curl", "systemctl", "kubectl", "sha256sum", "pg_dumpall"]


class Harness:
    """A throwaway root-ish sandbox: stub binaries on PATH plus a redirected state file."""

    def __init__(self, tmp):
        self.tmp = tmp
        self.bin = os.path.join(tmp, "bin")
        self.log = os.path.join(tmp, "calls.log")
        self.state = os.path.join(tmp, "state.json")
        self.charts = os.path.join(tmp, "charts")
        self.updates = os.path.join(tmp, "updates")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.charts, "vendor"))
        # do_prereqs_checked hard-fails without the vendored cert-manager chart; that check is
        # real behaviour we want to keep exercising, so satisfy it with a placeholder file.
        open(os.path.join(self.charts, "vendor", "cert-manager-v1.21.2.tgz"), "wb").close()
        self._write_stubs()

    def _write_stubs(self, fail_on=None):
        for name in STUBBED:
            path = os.path.join(self.bin, name)
            # `helm` is asked for a version and for `get pods`-style output by different stages;
            # echoing nothing and exiting 0 is enough for every call the installer makes, except
            # the pod listing, which must look like a healthy cluster for do_ready to pass.
            body = textwrap.dedent(
                """\
                #!/bin/bash
                echo "%s $*" >> "$CG_CALL_LOG"
                if [ -n "$CG_FAIL_ON" ] && [[ "%s $*" == *"$CG_FAIL_ON"* ]]; then
                  echo "stub forced failure" >&2
                  exit 1
                fi
                if [ "%s" = "k3s" ] && [ "$1" = "kubectl" ]; then
                  case "$2" in
                    get)
                      case "$3" in
                        ingress) exit 0 ;;
                        pods)
                          # one healthy pod and one completed Job: the shape do_ready accepts
                          if [[ "$*" == *"--no-headers"* ]]; then
                            echo "cloudgrange-api-1 1/1 Running 0 1m"
                            echo "cloudgrange-secrets-bootstrap 0/1 Completed 0 1m"
                          fi
                          exit 0 ;;
                      esac ;;
                  esac
                  exit 0
                fi
                exit 0
                """
                % (name, name, name)
            )
            with open(path, "w", newline="\n") as f:
                f.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def env(self, fail_on=None):
        env = dict(os.environ)
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["CG_CALL_LOG"] = self.log
        env["CG_FAIL_ON"] = fail_on or ""
        env["CLOUDGRANGE_INSTALL_STATE"] = self.state
        env["CLOUDGRANGE_UPDATES_SHARED"] = self.updates
        return env

    def run(self, fail_on=None):
        return subprocess.run(["bash", INSTALLER, "--hostname", "cg.test"],
                              capture_output=True, text=True, env=self.env(fail_on), timeout=300)

    def stages(self):
        try:
            with open(self.state) as f:
                return json.load(f).get("stages", {})
        except (OSError, ValueError):
            return {}


class InterruptAndResumeTests(unittest.TestCase):
    """The plan's 'interrupt at every checkpoint, then resume' qualification gate."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.h = Harness(self.tmp)

    def test_a_clean_run_completes_every_stage_in_order(self):
        proc = self.h.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        done = self.h.stages()
        for stage in STAGES:
            self.assertTrue(done.get(stage), "stage %s was never checkpointed: %s" % (stage, done))
        # Checkpoints must be recorded in the documented order, not just all present.
        order = [e["stage"] for e in json.load(open(self.h.state)).get("history", [])]
        self.assertEqual(order, STAGES, "stages ran out of order: %s" % order)

    def test_an_interrupted_stage_is_never_marked_complete(self):
        # helm is what certmanager-installed shells out to; forcing it to fail interrupts
        # precisely there, after two stages have already been checkpointed.
        proc = self.h.run(fail_on="upgrade --install cert-manager")
        self.assertNotEqual(proc.returncode, 0, "installer reported success despite a failed stage")
        done = self.h.stages()
        self.assertTrue(done.get("prereqs-checked"))
        self.assertTrue(done.get("k3s-installed"))
        self.assertFalse(done.get("certmanager-installed"),
                         "a stage that failed was still checkpointed — resume would skip it")
        self.assertFalse(done.get("chart-installed"))
        self.assertFalse(done.get("ready"))

    def test_resume_skips_completed_stages_and_finishes_the_rest(self):
        self.h.run(fail_on="upgrade --install cert-manager")
        open(self.h.log, "w").close()  # only look at what the SECOND run does
        proc = self.h.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("stage 'prereqs-checked' already complete", proc.stdout)
        self.assertIn("stage 'k3s-installed' already complete", proc.stdout)
        self.assertIn("install complete", proc.stdout)
        for stage in STAGES:
            self.assertTrue(self.h.stages().get(stage), "resume did not finish %s" % stage)

    def test_interrupting_at_every_checkpoint_still_converges(self):
        """The gate in full: interrupt after each stage in turn, resume, and still end complete."""
        for stage in STAGES[:-1]:
            with self.subTest(interrupted_after=stage):
                tmp = tempfile.mkdtemp()
                self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
                h = Harness(tmp)
                # Pre-seed the state file as though the run died right after `stage`.
                completed = STAGES[: STAGES.index(stage) + 1]
                with open(h.state, "w") as f:
                    json.dump({"stages": {s: True for s in completed},
                               "history": [{"stage": s, "at": "2026-01-01T00:00:00Z"} for s in completed]}, f)
                proc = h.run()
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                for s in completed:
                    self.assertIn("stage '%s' already complete" % s, proc.stdout)
                for s in STAGES:
                    self.assertTrue(h.stages().get(s), "%s missing after resume" % s)

    def test_a_corrupt_state_file_does_not_wedge_the_installer(self):
        with open(self.h.state, "w") as f:
            f.write("{ this is not json")
        proc = self.h.run()
        # Either it recovers and completes, or it fails loudly. What it must never do is treat
        # unreadable state as "everything already done" and silently skip the whole install.
        if proc.returncode == 0:
            for stage in STAGES:
                self.assertTrue(self.h.stages().get(stage))
        else:
            self.assertNotIn("install complete", proc.stdout)


class UninstallRetentionTests(unittest.TestCase):
    """The plan's uninstall/retention contract gate.

    The contract (documented in the installer header and charts/cloudgrange/README.md) is that
    PVCs SURVIVE `helm uninstall` and that purging data is a separate, explicit step. Kubernetes
    gives that for free — PVCs are not owned by the Helm release — so what actually has to be
    guaranteed is that nothing in this repo quietly deletes them as part of an uninstall.
    """

    def _text(self, *parts):
        with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
            return f.read()

    def test_no_script_deletes_pvcs_as_part_of_an_uninstall(self):
        offenders = []
        for root, dirs, files in os.walk(REPO):
            dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__", "test")]
            for name in files:
                if not name.endswith((".sh", ".ps1", ".py")):
                    continue
                path = os.path.join(root, name)
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                for line in text.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("#"):
                        continue
                    low = stripped.lower()
                    if "delete" in low and ("pvc" in low or "persistentvolumeclaim" in low):
                        offenders.append("%s: %s" % (os.path.relpath(path, REPO), stripped[:120]))
        self.assertEqual(offenders, [],
                         "these delete PVCs; data retention on uninstall is a documented contract:\n"
                         + "\n".join(offenders))

    def test_the_retention_contract_is_documented_where_operators_look(self):
        installer = self._text("scripts", "Install-CloudGrangeK3s.sh")
        self.assertIn("Uninstall/retention contract", installer,
                      "the installer no longer states its retention contract")
        self.assertIn("survive", installer.lower())
        readme = self._text("charts", "cloudgrange", "README.md")
        self.assertTrue(
            "uninstall" in readme.lower(),
            "charts/cloudgrange/README.md must document the uninstall/purge procedure the "
            "installer header points operators to")

    def test_purging_data_is_explicit_and_never_implied_by_uninstall(self):
        readme = self._text("charts", "cloudgrange", "README.md").lower()
        # The README must not tell an operator that `helm uninstall` alone removes their data,
        # and must describe the separate deliberate step if it documents purging at all.
        self.assertNotIn("helm uninstall removes all data", readme)
        if "purge" in readme or "delete pvc" in readme:
            self.assertTrue("kubectl delete pvc" in readme or "explicit" in readme,
                            "purging must be documented as an explicit, separate operator step")


class GeneralizeSecretWipeOrderingTests(unittest.TestCase):
    """AB#9186 — the SSH-key residue was an ORDERING bug, so the ordering is what must be pinned.

    Four appliance builds shipped a working free-space wipe that still leaked, because writes
    happened after it: journald is restarted by the shutdown transaction and flushes its runtime
    journal (holding sshd's accepted-publickey records) to disk. These tests fail if the ordering
    or the journald guard regresses.
    """

    def setUp(self):
        with open(os.path.join(REPO, "appliance", "cloudgrange-generalize-k3s.sh"), encoding="utf-8") as f:
            self.lines = f.read().splitlines()
        self.text = "\n".join(self.lines)

    def _line_of(self, needle):
        for i, line in enumerate(self.lines):
            if needle in line and not line.strip().startswith("#"):
                return i
        self.fail("generalize script no longer contains %r" % needle)

    def test_journald_is_made_volatile_before_the_free_space_wipe(self):
        volatile = self._line_of("Storage=volatile")
        wipe = self._line_of("of=/var/cloudgrange-zerofill")
        self.assertLess(volatile, wipe,
                        "journald must be volatile before the wipe, or the shutdown-time journal "
                        "flush writes install-time secrets into blocks the wipe already passed")

    def test_the_staged_upload_is_removed_before_the_wipe_not_after(self):
        remove = self._line_of('rm -rf "$STAGE_DIR"')
        wipe = self._line_of("of=/var/cloudgrange-zerofill")
        self.assertLess(remove, wipe,
                        "deleting the staged upload after the wipe leaves its contents in freed "
                        "blocks the wipe already went over")

    def test_nothing_writes_to_disk_between_the_wipe_and_poweroff(self):
        fstrim = self._line_of("fstrim -av")
        poweroff = self._line_of("systemctl poweroff")
        between = [l.strip() for l in self.lines[fstrim + 1:poweroff]
                   if l.strip() and not l.strip().startswith("#")]
        # Only these are allowed after the wipe: they touch no file content.
        allowed = ("sync", "echo ", "cd /", "rmdir ")
        offenders = [l for l in between if not l.startswith(allowed)]
        self.assertEqual(offenders, [],
                         "these run after the free-space wipe and may write to disk:\n" + "\n".join(offenders))

    def test_firstboot_restores_persistent_logging(self):
        with open(os.path.join(REPO, "appliance", "cloudgrange-firstboot-k3s.sh"), encoding="utf-8") as f:
            firstboot = f.read()
        self.assertIn("00-cloudgrange-generalize.conf", firstboot,
                      "generalize makes journald volatile; firstboot must undo it or the shipped "
                      "appliance silently loses logs across reboots")


if __name__ == "__main__":
    unittest.main()
