#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9189 — cloudgrange-updater-k3s: the K3s/Helm counterpart of compose/updater/cloudgrange-updater.py,
# so "Platform administration -> Updates" applies a release in-place on a K3s appliance instead of
# requiring a reinstall. Until this existed, the K3s engine had no updater at all while Compose had a
# 720-line one — the same "Compose got it, K3s never got the equivalent wiring" divergence that already
# produced the realm-admin and RELAY_ENROLLMENT_TOKEN bugs.
#
# Wire-compatible with the Compose updater ON PURPOSE: same request files, same status schema
# (cg-updater-status-v1), same job/history shape. The API side therefore needs no engine-specific code,
# and the portal's Updates page works against either engine unchanged.
#
# Trust boundary (identical reasoning to the Compose updater). The API pod is non-root and can only drop
# requests and uploaded bundles into the shared updates directory (requests/, incoming/). Everything
# there is untrusted: files are opened O_NOFOLLOW, must be regular files, and are copied into root-only
# state (/var/lib/cloudgrange-updater) before use. status/ is root-owned; the API can read it but not
# change it, and a replaced status/ is discarded.
#
# What differs from Compose, and why:
#   - `docker load`            -> `k3s ctr images import` (containerd is K3s's image store)
#   - `docker compose up`      -> `helm upgrade`
#   - backup/restore the stack tree and .env -> Helm's own revision history plus `helm rollback`.
#     Helm already records every revision's full manifest and values, so copying the chart tree aside
#     would be duplicating a guarantee the package manager gives us. The database is still dumped
#     separately, because a Helm rollback restores Kubernetes objects, never PersistentVolume contents.
#
# Bundle signatures are not verified (release signing is still pending, same as Compose): the platform
# administrator who uploads a bundle, or the configured update channel, is the trust decision.
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
import zipfile

UPDATER_VERSION = "1"
STATUS_SCHEMA = "cg-updater-status-v1"
ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$")
SUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  (\S.*)$")
MAX_REQUEST_BYTES = 64 * 1024
MAX_BUNDLE_BYTES = 8 * 1024 ** 3
MAX_EXTRACT_BYTES = 16 * 1024 ** 3
# The K3s bundle's layout (scripts/New-ReleaseBundleK3s.sh). Unlike the Compose bundle there is no
# docker-compose.yml or hardening gate; the chart and the installer are what must be present.
REQUIRED_FILES = ("SHA256SUMS", "charts/cloudgrange/Chart.yaml", "scripts/Install-CloudGrangeK3s.sh")
KEEP_BACKUPS = 2
KEEP_HISTORY = 20
CHUNK = 4 * 1024 * 1024


class UpdateError(Exception):
    pass


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def tail(data, limit=400):
    text = data if isinstance(data, str) else data.decode("utf-8", "replace")
    text = text.strip()
    return text[-limit:] if len(text) > limit else text


def open_untrusted_file(dir_fd, name, limit):
    """Open a file supplied by the non-root API: never follow a symlink, never accept a special file."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise UpdateError("%s is not a regular file" % name)
        if st.st_size > limit:
            raise UpdateError("%s is larger than %d bytes" % (name, limit))
    except Exception:
        os.close(fd)
        raise
    return fd


def open_untrusted_dir(parent_fd, name):
    try:
        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError:
        return None


class K3sUpdater:
    def __init__(self):
        e = os.environ.get
        self.state_dir = e("CLOUDGRANGE_UPDATER_STATE", "/var/lib/cloudgrange-updater")
        self.shared = e("CLOUDGRANGE_UPDATES_SHARED", "/var/lib/cloudgrange/updates")
        self.charts_dir = e("CLOUDGRANGE_CHARTS_DIR", "/opt/cloudgrange-k3s-installer/charts")
        self.release = e("CLOUDGRANGE_HELM_RELEASE", "cloudgrange")
        self.namespace = e("CLOUDGRANGE_NAMESPACE", "default")
        self.kubeconfig = e("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
        self.helm = e("CLOUDGRANGE_HELM_BIN", "helm")
        self.health_timeout = float(e("CLOUDGRANGE_UPDATE_HEALTH_TIMEOUT", "600"))
        self.health_interval = float(e("CLOUDGRANGE_UPDATE_HEALTH_INTERVAL", "5"))
        self.poll = float(e("CLOUDGRANGE_UPDATER_POLL", "3"))
        self.step = "idle"
        os.makedirs(self.state_dir, 0o700, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.state = self._load_state()

    # ---- process helpers --------------------------------------------------------------------------
    def _env(self):
        env = dict(os.environ)
        env["KUBECONFIG"] = self.kubeconfig
        return env

    def run(self, args, timeout=900, check=True):
        proc = subprocess.run(args, capture_output=True, env=self._env(), timeout=timeout)
        if check and proc.returncode != 0:
            raise UpdateError("%s failed: %s" % (args[0], tail(proc.stderr or proc.stdout)))
        return proc

    # ---- state ------------------------------------------------------------------------------------
    def _state_path(self):
        return os.path.join(self.state_dir, "state.json")

    def _load_state(self):
        try:
            with open(self._state_path(), "rb") as f:
                state = json.loads(f.read().decode("utf-8"))
            if isinstance(state, dict):
                state.setdefault("history", [])
                return state
        except (OSError, ValueError):
            pass
        return {"job": None, "history": []}

    def save(self):
        tmp = self._state_path() + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self._state_path())
        self.write_status()

    def _archive(self, state, job):
        state["job"] = job
        history = state.setdefault("history", [])
        history.insert(0, job)
        del history[KEEP_HISTORY:]

    def current_version(self):
        """The image tag Helm currently has deployed — the honest answer to 'what is running'."""
        try:
            proc = self.run([self.helm, "get", "values", self.release, "-n", self.namespace, "-o", "json"],
                            timeout=60, check=False)
            if proc.returncode == 0:
                values = json.loads(proc.stdout.decode("utf-8") or "{}")
                tag = (values.get("global") or {}).get("image", {}).get("tag")
                if tag:
                    return str(tag)
        except (UpdateError, ValueError, OSError, subprocess.SubprocessError):
            pass
        return None

    # ---- status -----------------------------------------------------------------------------------
    def _status_dir_fd(self):
        """status/ must be a root-owned real directory. If the API replaced it, move it aside."""
        root_fd = os.open(self.shared, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                st = os.stat("status", dir_fd=root_fd, follow_symlinks=False)
                if not stat.S_ISDIR(st.st_mode):
                    os.unlink("status", dir_fd=root_fd)
                    raise FileNotFoundError
                if st.st_uid != 0:
                    os.rename("status", "status.rejected-" + uuid.uuid4().hex,
                              src_dir_fd=root_fd, dst_dir_fd=root_fd)
                    raise FileNotFoundError
            except FileNotFoundError:
                os.mkdir("status", 0o755, dir_fd=root_fd)
            fd = os.open("status", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            if os.fstat(fd).st_uid != 0:
                os.close(fd)
                raise UpdateError("status directory is not root-owned")
            return fd
        finally:
            os.close(root_fd)

    def write_status(self):
        """Write the document the API reads. Best effort — never raises into the job path."""
        doc = {
            "schema": STATUS_SCHEMA,
            "updaterVersion": UPDATER_VERSION,
            "engine": "k3s",
            "updatedAt": now(),
            "currentVersion": self.current_version(),
            "step": self.step,
            "job": self.state.get("job"),
            "history": self.state.get("history", []),
        }
        try:
            dir_fd = self._status_dir_fd()
        except (OSError, UpdateError):
            return
        try:
            body = json.dumps(doc, indent=2, sort_keys=True).encode("utf-8")
            tmp = "status.json.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
            with os.fdopen(fd, "wb") as f:
                f.write(body)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp, "status.json", src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except OSError:
            pass
        finally:
            os.close(dir_fd)

    def set_step(self, step):
        self.step = step
        job = self.state.get("job")
        if job:
            job["step"] = step
        self.save()

    # ---- requests ---------------------------------------------------------------------------------
    def take_requests(self):
        if not os.path.isdir(self.shared):
            return []
        root_fd = os.open(self.shared, os.O_RDONLY | os.O_DIRECTORY)
        try:
            req_fd = open_untrusted_dir(root_fd, "requests")
            if req_fd is None:
                return []
            try:
                taken = []
                for name in sorted(os.listdir(req_fd)):
                    if not name.endswith(".json") or not ID_RE.match(name[:-5]):
                        continue
                    try:
                        fd = open_untrusted_file(req_fd, name, MAX_REQUEST_BYTES)
                        with os.fdopen(fd, "rb") as f:
                            body = f.read(MAX_REQUEST_BYTES + 1)
                        os.unlink(name, dir_fd=req_fd)
                        req = json.loads(body.decode("utf-8"))
                        if not isinstance(req, dict):
                            raise ValueError("request is not an object")
                        req["id"] = name[:-5]
                        taken.append(req)
                    except (UpdateError, ValueError, OSError) as err:
                        try:
                            os.unlink(name, dir_fd=req_fd)
                        except OSError:
                            pass
                        self._reject(name[:-5], "invalid request: %s" % err)
                return taken
            finally:
                os.close(req_fd)
        finally:
            os.close(root_fd)

    def _reject(self, job_id, message):
        job = {"id": job_id, "action": "unknown", "state": "failed", "step": "queued",
               "startedAt": now(), "finishedAt": now(), "message": message,
               "targetVersion": None, "previousVersion": self.current_version()}
        self._archive(self.state, job)
        self.save()

    # ---- bundle handling --------------------------------------------------------------------------
    def stage_bundle(self, req):
        """Copy the untrusted upload into root-only state and verify its checksum before touching it."""
        name = str(req.get("bundle") or "")
        if not name or "/" in name or name in (".", ".."):
            raise UpdateError("request does not name a bundle in incoming/")
        expected = str(req.get("sha256") or "").lower()
        if not SHA_RE.match(expected):
            raise UpdateError("request does not carry a valid sha256")

        staged = os.path.join(self.state_dir, "staged.zip")
        root_fd = os.open(self.shared, os.O_RDONLY | os.O_DIRECTORY)
        try:
            inc_fd = open_untrusted_dir(root_fd, "incoming")
            if inc_fd is None:
                raise UpdateError("no incoming/ directory")
            try:
                fd = open_untrusted_file(inc_fd, name, MAX_BUNDLE_BYTES)
                digest = hashlib.sha256()
                with os.fdopen(fd, "rb") as src, open(staged, "wb") as dst:
                    while True:
                        chunk = src.read(CHUNK)
                        if not chunk:
                            break
                        digest.update(chunk)
                        dst.write(chunk)
                try:
                    os.unlink(name, dir_fd=inc_fd)
                except OSError:
                    pass
            finally:
                os.close(inc_fd)
        finally:
            os.close(root_fd)

        actual = digest.hexdigest()
        if actual != expected:
            os.unlink(staged)
            raise UpdateError("bundle sha256 mismatch: expected %s, got %s" % (expected, actual))
        return staged

    def extract_and_verify(self, staged):
        work = os.path.join(self.state_dir, "work")
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, 0o700)
        total = 0
        with zipfile.ZipFile(staged) as z:
            for info in z.infolist():
                # Reject absolute paths and traversal before writing anything.
                if info.filename.startswith("/") or ".." in info.filename.split("/"):
                    raise UpdateError("bundle contains an unsafe path: %s" % info.filename)
                total += info.file_size
                if total > MAX_EXTRACT_BYTES:
                    raise UpdateError("bundle expands beyond %d bytes" % MAX_EXTRACT_BYTES)
            z.extractall(work)

        for rel in REQUIRED_FILES:
            if not os.path.isfile(os.path.join(work, rel)):
                raise UpdateError("bundle is missing %s" % rel)

        # SHA256SUMS covers every other file in the bundle; a mismatch means the zip was tampered
        # with after it was built, so refuse the whole thing rather than install part of it.
        sums = os.path.join(work, "SHA256SUMS")
        with open(sums, "r", encoding="utf-8") as f:
            lines = [ln.rstrip("\n") for ln in f if ln.strip()]
        if not lines:
            raise UpdateError("SHA256SUMS is empty")
        for line in lines:
            m = SUM_LINE_RE.match(line)
            if not m:
                raise UpdateError("malformed SHA256SUMS line: %s" % tail(line, 80))
            want, rel = m.group(1), m.group(2)
            path = os.path.join(work, rel)
            if not os.path.isfile(path):
                raise UpdateError("SHA256SUMS lists a missing file: %s" % rel)
            digest = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(CHUNK), b""):
                    digest.update(chunk)
            if digest.hexdigest() != want:
                raise UpdateError("checksum mismatch for %s" % rel)
        return work

    def bundle_version(self, work):
        """The version the bundle will deploy: the chart values' stamped image tag."""
        values = os.path.join(work, "charts", "cloudgrange", "values.yaml")
        try:
            with open(values, "r", encoding="utf-8") as f:
                for line in f:
                    m = re.match(r"^\s+tag:\s*(\S+)\s*$", line)
                    if m:
                        tag = m.group(1).strip("\"'")
                        if VERSION_RE.match(tag):
                            return tag
        except OSError:
            pass
        raise UpdateError("could not read the bundle's image tag from charts/cloudgrange/values.yaml")

    # ---- database ---------------------------------------------------------------------------------
    def _postgres_pod(self):
        proc = self.run(["k3s", "kubectl", "get", "pods", "-n", self.namespace,
                         "-l", "app.kubernetes.io/name=postgres",
                         "-o", "jsonpath={.items[0].metadata.name}"], timeout=60, check=False)
        name = (proc.stdout or b"").decode("utf-8").strip()
        return name or None

    def backup_database(self):
        """Helm rollback restores Kubernetes objects, never volume contents — so dump the DB separately."""
        pod = self._postgres_pod()
        if not pod:
            raise UpdateError("no postgres pod found to back up")
        backups = os.path.join(self.state_dir, "backups")
        os.makedirs(backups, 0o700, exist_ok=True)
        path = os.path.join(backups, "db-%s.sql" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
        proc = subprocess.run(["k3s", "kubectl", "exec", "-n", self.namespace, pod, "--",
                               "pg_dumpall", "-U", "postgres"],
                              capture_output=True, env=self._env(), timeout=1800)
        if proc.returncode != 0:
            raise UpdateError("pg_dumpall failed: %s" % tail(proc.stderr))
        with open(path, "wb") as f:
            f.write(proc.stdout)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(path, 0o600)
        # Keep only the most recent dumps; these are full database copies and will fill the disk.
        dumps = sorted(p for p in os.listdir(backups) if p.startswith("db-"))
        for old in dumps[:-KEEP_BACKUPS]:
            try:
                os.unlink(os.path.join(backups, old))
            except OSError:
                pass
        return path

    # ---- helm -------------------------------------------------------------------------------------
    def helm_revision(self):
        proc = self.run([self.helm, "history", self.release, "-n", self.namespace, "-o", "json"],
                        timeout=120, check=False)
        if proc.returncode != 0:
            return None
        try:
            entries = json.loads(proc.stdout.decode("utf-8") or "[]")
            return max(int(e["revision"]) for e in entries) if entries else None
        except (ValueError, KeyError):
            return None

    def import_images(self, work):
        """Offline bundles carry the images; import them so the upgrade does not need the network."""
        tar = os.path.join(work, "airgap", "cloudgrange-images-amd64.tar")
        if not os.path.isfile(tar):
            return False
        self.run(["k3s", "ctr", "images", "import", tar], timeout=3600)
        return True

    def helm_upgrade(self, work):
        chart = os.path.join(work, "charts", "cloudgrange")
        values = os.path.join(chart, "values-single-node.yaml")
        args = [self.helm, "upgrade", self.release, chart, "-n", self.namespace,
                "--wait", "--timeout", "%ds" % int(self.health_timeout)]
        if os.path.isfile(values):
            args += ["-f", values]
        # Carry the live release's own values forward so an update never silently drops settings the
        # operator chose at install time (hostname, storage class, profile overrides).
        args.append("--reuse-values")
        self.run(args, timeout=int(self.health_timeout) + 300)

    def helm_rollback(self, revision):
        if revision is None:
            raise UpdateError("no previous Helm revision to roll back to")
        self.run([self.helm, "rollback", self.release, str(revision), "-n", self.namespace,
                  "--wait", "--timeout", "%ds" % int(self.health_timeout)],
                 timeout=int(self.health_timeout) + 300)

    def wait_healthy(self):
        """Trust the cluster's own readiness, then probe the API the way a user reaches it."""
        deadline = time.time() + self.health_timeout
        last = "no pods reported"
        while time.time() < deadline:
            proc = self.run(["k3s", "kubectl", "get", "pods", "-n", self.namespace,
                             "-o", "jsonpath={range .items[*]}{.metadata.name}{\" \"}"
                             "{.status.phase}{\" \"}{.status.containerStatuses[*].ready}{\"\\n\"}{end}"],
                            timeout=60, check=False)
            lines = [ln for ln in (proc.stdout or b"").decode("utf-8").splitlines() if ln.strip()]
            bad = []
            for ln in lines:
                parts = ln.split()
                if len(parts) < 2:
                    continue
                name, phase, ready = parts[0], parts[1], " ".join(parts[2:])
                if phase == "Succeeded":
                    continue  # completed Jobs (secrets-bootstrap, realm-admin)
                if phase != "Running" or "false" in ready.lower():
                    bad.append("%s=%s" % (name, phase))
            if lines and not bad:
                return
            last = ", ".join(bad) or last
            time.sleep(self.health_interval)
        raise UpdateError("pods did not become healthy within %ds: %s" % (self.health_timeout, last))

    # ---- actions ----------------------------------------------------------------------------------
    # AB#9148 — an update writes a full database dump and imports a set of container images.
    # Starting one on a nearly-full disk is how you end up with a half-applied update AND no room
    # to roll it back, so refuse up front instead of failing somewhere in the middle.
    UPDATE_HEADROOM_BYTES = 5 * 1024 ** 3

    def check_free_space(self):
        st = os.statvfs(self.state_dir)
        free = st.f_bavail * st.f_frsize
        if free < self.UPDATE_HEADROOM_BYTES:
            raise UpdateError(
                "not enough free disk space to apply an update: %d MB free, %d GB required"
                % (free // (1024 ** 2), self.UPDATE_HEADROOM_BYTES // (1024 ** 3)))

    def do_apply(self, req, job):
        self.set_step("preflight")
        self.check_free_space()
        self.set_step("staging")
        staged = self.stage_bundle(req)
        self.set_step("verifying")
        work = self.extract_and_verify(staged)
        job["targetVersion"] = self.bundle_version(work)
        self.save()

        self.set_step("backing-up")
        previous_revision = self.helm_revision()
        db_backup = self.backup_database()

        try:
            self.set_step("loading-images")
            self.import_images(work)
            self.set_step("upgrading")
            self.helm_upgrade(work)
            self.set_step("health-check")
            self.wait_healthy()
        except (UpdateError, subprocess.SubprocessError, OSError) as err:
            # Put the cluster back the way it was before reporting failure. A failed update that
            # leaves a half-upgraded stack running is worse than no update at all.
            self.set_step("rolling-back")
            detail = str(err)
            try:
                self.helm_rollback(previous_revision)
                self.wait_healthy()
                detail += " (rolled back to revision %s; database dump kept at %s)" % (
                    previous_revision, db_backup)
            except (UpdateError, subprocess.SubprocessError, OSError) as rb:
                detail += " (ROLLBACK ALSO FAILED: %s; database dump kept at %s)" % (rb, db_backup)
            raise UpdateError(detail)
        finally:
            shutil.rmtree(work, ignore_errors=True)
            try:
                os.unlink(staged)
            except OSError:
                pass

    def do_rollback(self, req, job):
        self.set_step("rolling-back")
        current = self.helm_revision()
        if current is None or current < 2:
            raise UpdateError("no previous release to roll back to")
        target = current - 1
        job["targetVersion"] = None
        self.helm_rollback(target)
        self.set_step("health-check")
        self.wait_healthy()

    # ---- job loop ---------------------------------------------------------------------------------
    def handle(self, req):
        action = req.get("action")
        requested_by = str(req.get("requestedBy") or "")[:200]
        job = {"id": req["id"], "action": action, "state": "running", "step": "queued",
               "startedAt": now(), "finishedAt": None, "message": None, "targetVersion": None,
               "previousVersion": self.current_version(), "requestedBy": requested_by}
        busy = self.state.get("job")
        if busy and busy.get("state") == "running":
            job.update(state="failed", finishedAt=now(), message="another update job is running")
            self._archive(self.state, job)
            self.save()
            return
        self._archive(self.state, job)
        self.save()
        try:
            if action == "apply":
                self.do_apply(req, job)
            elif action == "rollback":
                self.do_rollback(req, job)
            else:
                raise UpdateError("unknown action: %s" % tail(str(action), 40))
            job.update(state="succeeded", message=None)
        except (UpdateError, subprocess.SubprocessError, OSError, ValueError, zipfile.BadZipFile) as err:
            job.update(state="failed", message=tail(str(err)))
        finally:
            job["finishedAt"] = now()
            self.step = "idle"
            self.save()

    def process_once(self):
        for req in self.take_requests():
            self.handle(req)
        self.write_status()

    def serve(self):
        self.write_status()
        while True:
            try:
                self.process_once()
            except Exception as err:  # never let one bad request kill the service
                sys.stderr.write("updater loop error: %s\n" % err)
            time.sleep(self.poll)


def main(argv):
    os.umask(0o022)
    updater = K3sUpdater()
    if "--once" in argv:
        updater.process_once()
        return 0
    updater.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
