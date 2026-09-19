# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — scripts/Test-SshTransportOptions.py: every ssh/scp call in the installer must go through
# Invoke-CloudGrangeSsh with -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15
# -o ServerAliveCountMax=4 and an overall -TimeoutSeconds. The committed scripts pass; each test plants one
# regression in a temporary copy of the repository and asserts the gate fails.
#   python3 -m unittest discover -s test/appliance -p 'test_ssh_transport.py'
import re
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("CLOUDGRANGE_REPO_UNDER_TEST", os.path.dirname(os.path.dirname(HERE)))
GATE = os.path.join(REPO, "scripts", "Test-SshTransportOptions.py")
SSH_SCRIPTS = [
    "Build-CloudGrangeAppliance.ps1",
    "Install-CloudGrange.ps1",
    "New-SelfSignedCert.ps1",
    "scripts/Deploy-DockerCompose.ps1",
    "scripts/Install-DockerCe.ps1",
]
REQUIRED = ["BatchMode=yes", "ConnectTimeout=15", "ServerAliveInterval=15", "ServerAliveCountMax=4"]
HELPER = "scripts/CloudGrange-Common.ps1"
DEPLOY = "scripts/Deploy-DockerCompose.ps1"


class SshTransportGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "repo")
        shutil.copytree(REPO, self.root, ignore=shutil.ignore_patterns(".git", "archive", "node_modules", "bin", "obj"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def gate(self):
        return subprocess.run(["python3", GATE, self.root], capture_output=True, text=True)

    def read(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            return f.read()

    def write(self, rel, text):
        with open(os.path.join(self.root, rel), "w", encoding="utf-8") as f:
            f.write(text)

    def replace(self, rel, old, new, count=1):
        text = self.read(rel)
        self.assertIn(old, text, "plant anchor missing in %s" % rel)
        self.write(rel, text.replace(old, new, count))

    def append(self, rel, line):
        self.write(rel, self.read(rel) + "\n" + line + "\n")

    def assert_fails(self, *fragments):
        r = self.gate()
        self.assertEqual(r.returncode, 1, "gate did not fail:\n" + r.stdout + r.stderr)
        for fragment in fragments:
            self.assertIn(fragment, r.stderr)

    # --- baseline --------------------------------------------------------------------------------
    def test_committed_scripts_pass_and_every_ssh_script_is_covered(self):
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ssh transport gate passed", r.stdout)
        for rel in SSH_SCRIPTS:
            self.assertRegex(r.stdout, r"(?m)^  %s: [1-9]\d*$" % rel.replace(".", r"\."))

    def test_no_script_keeps_a_hand_built_ssh_option_list(self):
        for rel in SSH_SCRIPTS:
            text = self.read(rel)
            self.assertNotIn("'-o', 'StrictHostKeyChecking=no'", text, rel)
            self.assertNotIn("ssh.exe", text, rel)
            self.assertNotIn("scp.exe", text, rel)

    # --- direct invocations ------------------------------------------------------------------------
    def test_call_operator_ssh_is_caught(self):
        self.append(DEPLOY, "& ssh.exe @sshOpts $sshTarget 'id'")
        self.assert_fails("direct ssh/scp invocation (call operator)", DEPLOY)

    def test_call_operator_scp_with_a_path_is_caught(self):
        self.append("scripts/Install-DockerCe.ps1", "& 'C:\\Windows\\System32\\OpenSSH\\scp.exe' -r a b")
        self.assert_fails("direct ssh/scp invocation (call operator)")

    def test_process_filename_ssh_is_caught(self):
        self.append("New-SelfSignedCert.ps1", "$psi.FileName = 'ssh.exe'")
        self.assert_fails("direct ssh/scp invocation (process FileName)")

    def test_process_start_info_ssh_is_caught(self):
        self.append("Install-CloudGrange.ps1", "$psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')")
        self.assert_fails("direct ssh/scp invocation (ProcessStartInfo)")

    def test_start_process_ssh_is_caught(self):
        self.append("Build-CloudGrangeAppliance.ps1", "Start-Process ssh.exe -ArgumentList '-i k cloudgrange@vm id' -Wait")
        self.assert_fails("direct ssh/scp invocation (launcher)")

    def test_invoke_expression_ssh_is_caught(self):
        self.append(DEPLOY, "Invoke-Expression \"ssh -i $SshKeyPath cloudgrange@$VmIp id\"")
        self.assert_fails("direct ssh/scp invocation (launcher)")

    def test_bare_ssh_in_a_shell_script_is_caught(self):
        self.append("scripts/install-relay.sh", "ssh -i /tmp/key cloudgrange@10.0.0.1 id")
        self.assert_fails("scripts/install-relay.sh", "direct ssh/scp invocation (bare command)")

    def test_printed_ssh_hint_is_not_an_invocation(self):
        self.append(DEPLOY, "Write-Host \"  SSH: ssh -i key cloudgrange@vm\" -ForegroundColor White")
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # --- call sites --------------------------------------------------------------------------------
    def test_call_without_a_timeout_is_caught(self):
        self.append(DEPLOY, "Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @($sshTarget, 'id'))")
        self.assert_fails("without a literal -TimeoutSeconds")

    def test_call_with_hand_built_arguments_is_caught(self):
        self.append(DEPLOY, "Invoke-CloudGrangeSsh -ArgumentList @('-i', $SshKeyPath, $sshTarget, 'id') -TimeoutSeconds 30")
        self.assert_fails("is not built from Get-CloudGrangeSshOptions")

    def test_options_variable_reassigned_by_hand_is_caught(self):
        self.replace(DEPLOY, "$sshTarget = \"cloudgrange@$VmIp\"",
                     "$sshTarget = \"cloudgrange@$VmIp\"\n        $sshOpts = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no')")
        self.assert_fails("is not built from Get-CloudGrangeSshOptions")

    # --- helper ------------------------------------------------------------------------------------
    def test_each_required_option_removed_from_the_helper_is_caught(self):
        original = self.read(HELPER)
        for option in REQUIRED:
            with self.subTest(option=option):
                self.assertIn("'%s'" % option, original)
                self.write(HELPER, original.replace("'%s'" % option, "'LogLevel=ERROR'", 1))
                self.assert_fails("Get-CloudGrangeSshRequiredOptions does not list '%s'" % option)
        self.write(HELPER, original)

    def test_helper_that_stops_refusing_missing_options_is_caught(self):
        self.replace(HELPER, "CG-SSH-ERR-001", "CG-SSH-WARN", count=2)
        self.assert_fails("Invoke-CloudGrangeSsh does not refuse a call without them")

    def test_helper_that_does_not_stop_a_timed_out_process_is_caught(self):
        # AB#9171: both bounded-process paths must stop the tree — the pipe path and the
        # capture-to-file path that every captured ssh call takes. Each is planted on its own,
        # because a plant in one must not be excused by the other still being correct.
        original = self.read(HELPER)
        for function in ("Invoke-CloudGrangeBoundedProcess", "Invoke-CloudGrangeBoundedProcessToFile"):
            with self.subTest(function=function):
                start = re.search(r"(?mi)^function\s+%s\s*\{" % re.escape(function), original)
                self.assertIsNotNone(start, "plant anchor missing: function %s" % function)
                at = original.index(".Kill($true)", start.end())
                self.write(HELPER, original[:at] + ".Refresh()" + original[at + len(".Kill($true)"):])
                self.assert_fails("%s does not stop the process tree on timeout" % function)
        self.write(HELPER, original)

    def test_optional_timeout_is_caught(self):
        self.replace(HELPER, "[Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,\n        [byte[]]$StandardInput,\n        [switch]$CaptureOutput\n    )\n    $required",
                     "[int]$TimeoutSeconds = 0,\n        [byte[]]$StandardInput,\n        [switch]$CaptureOutput\n    )\n    $required")
        self.assert_fails("Invoke-CloudGrangeSsh -TimeoutSeconds must be mandatory and bounded")


if __name__ == "__main__":
    unittest.main()
