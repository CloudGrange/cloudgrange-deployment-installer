# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — Install-CloudGrange-Linux.sh preflight (owner decision 2026-09-18, plan §5): the Linux-script
# path is a MANAGED foundation, so the host must be a dedicated, fresh Ubuntu 24.04 used only for
# CloudGrange. The preflight refuses an unsupported OS, anyone else's container runtime or Kubernetes
# (K3s included), busy ports and an undersized machine -- before anything on the host changes -- and
# allows a re-run on a host this installer already set up.
#
# Drives the REAL script with --preflight-only and a PATH that contains only the tools it needs plus stubs,
# so whatever happens to be installed on the machine running the tests (docker, k3s, ...) cannot leak in.
#   sudo python3 -m unittest discover -s test/appliance -p 'test_linux_preflight.py'
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "Install-CloudGrange-Linux.sh")
REAL_TOOLS = ("awk", "sed", "sort", "grep", "id", "dirname", "cat", "head", "tr", "cut")


class LinuxPreflightTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.fail("the Linux installer refuses to run unless it is root; run these tests as root")
        self.tmp = tempfile.mkdtemp(prefix="cg-preflight-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.root, "var", "lib"))
        for tool in REAL_TOOLS:
            path = shutil.which(tool)
            self.assertIsNotNone(path, tool)
            os.symlink(path, os.path.join(self.bin, tool))
        self.stub("nproc", "echo 4")
        self.stub("df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/sda1 100000000 1000 %s 1%% /"' % (60 * 1024 * 1024))
        self.stub("ss", 'cat "$FAKE/ss" 2>/dev/null; exit 0')
        self.stub("systemctl", 'for u in "$@"; do [ -f "$FAKE/active-$u" ] && exit 0; done; exit 3')
        self.os_release = os.path.join(self.tmp, "os-release")
        self.write(self.os_release, 'ID=ubuntu\nVERSION_ID="24.04"\n')
        self.meminfo = os.path.join(self.tmp, "meminfo")
        self.write(self.meminfo, "MemTotal:        8123456 kB\n")

    @staticmethod
    def write(path, body):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(body)

    def stub(self, name, body):
        path = os.path.join(self.bin, name)
        self.write(path, "#!/bin/bash\n" + body + "\n")
        os.chmod(path, 0o755)

    def run_preflight(self):
        env = {"PATH": self.bin, "FAKE": self.tmp, "CLOUDGRANGE_OS_RELEASE_FILE": self.os_release,
               "CLOUDGRANGE_MEMINFO_FILE": self.meminfo, "CLOUDGRANGE_PREFLIGHT_ROOT": self.root}
        return subprocess.run(["/bin/bash", SCRIPT, "--hostname", "cg.test", "--preflight-only"],
                               env=env, capture_output=True, text=True, timeout=60)

    def assert_refused(self, proc, *reasons):
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("preflight failed. Nothing on this host was changed", proc.stderr)
        for reason in reasons:
            self.assertIn(reason, proc.stderr)
        self.assertNotIn("Preflight passed", proc.stdout)

    def test_a_dedicated_fresh_ubuntu_passes(self):
        proc = self.run_preflight()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Preflight passed", proc.stdout)

    def test_unsupported_os_is_refused(self):
        self.write(self.os_release, 'ID=ubuntu\nVERSION_ID="22.04"\n')
        self.assert_refused(self.run_preflight(), "Ubuntu 24.04 is required")
        self.write(self.os_release, 'ID=debian\nVERSION_ID="12"\n')
        self.assert_refused(self.run_preflight(), "unsupported OS 'debian 12'")

    def test_an_existing_docker_or_containerd_is_refused(self):
        self.stub("docker", "exit 0")
        self.assert_refused(self.run_preflight(), "'docker' is installed")
        os.remove(os.path.join(self.bin, "docker"))
        os.makedirs(os.path.join(self.root, "var", "lib", "containerd"))
        self.assert_refused(self.run_preflight(), "/var/lib/containerd exists")

    def test_a_running_kubelet_is_refused(self):
        open(os.path.join(self.tmp, "active-kubelet.service"), "w").close()
        self.assert_refused(self.run_preflight(), "kubelet.service is running")

    def test_someone_elses_k3s_is_refused_but_our_own_install_may_rerun(self):
        self.stub("k3s", "exit 0")
        os.makedirs(os.path.join(self.root, "var", "lib", "rancher", "k3s"))
        self.write(os.path.join(self.tmp, "ss"), "LISTEN 0 4096 *:6443 *:*\nLISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n")
        self.assert_refused(self.run_preflight(), "K3s is already installed, and not by this installer",
                            "TCP port 6443 is already in use", "TCP port 443 is already in use")
        self.write(os.path.join(self.root, "opt", "cloudgrange", ".install-state.json"), '{"stages":{}}')
        proc = self.run_preflight()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("re-run/resume allowed", proc.stdout)

    def test_busy_ports_are_refused_on_a_fresh_host(self):
        self.write(os.path.join(self.tmp, "ss"), "LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\nLISTEN 0 511 [::]:8443 [::]:*\n")
        self.assert_refused(self.run_preflight(), "TCP port 80 is already in use", "TCP port 8443 is already in use")

    def test_an_undersized_machine_is_refused_with_every_reason_at_once(self):
        self.stub("nproc", "echo 2")
        self.write(self.meminfo, "MemTotal:        4000000 kB\n")
        self.stub("df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/sda1 1 1 1048576 1% /"')
        self.assert_refused(self.run_preflight(), "2 CPUs: at least 4", "MiB RAM: at least", "1 GiB free under /var/lib")

    def test_the_k3s_installer_is_never_reached_when_preflight_fails(self):
        self.write(self.os_release, 'ID=fedora\nVERSION_ID="40"\n')
        env_marker = os.path.join(self.tmp, "installer-ran")
        # Without --preflight-only the script would exec Install-CloudGrangeK3s.sh next; a failure must stop first.
        proc = subprocess.run(["/bin/bash", SCRIPT, "--hostname", "cg.test"],
                              env={"PATH": self.bin, "FAKE": self.tmp, "CLOUDGRANGE_OS_RELEASE_FILE": self.os_release,
                                   "CLOUDGRANGE_MEMINFO_FILE": self.meminfo, "CLOUDGRANGE_PREFLIGHT_ROOT": self.root,
                                   "CLOUDGRANGE_INSTALL_STATE": env_marker},
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertFalse(os.path.exists(env_marker), "the K3s installer ran despite a failed preflight")


if __name__ == "__main__":
    unittest.main()
