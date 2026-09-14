#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — cloudgrange-updater: root host service that installs CloudGrange release bundles on an on-prem
# appliance, so an update is applied from Platform administration -> Updates instead of a reinstall.
#
# Trust boundary. The API container (non-root) can only drop requests and uploaded bundles into the
# cloudgrange_platform_updates volume (requests/, incoming/). Everything in that volume is untrusted: files are
# opened with O_NOFOLLOW, must be regular files, and are copied into root-only state (/var/lib/cloudgrange-updater)
# before use. Status goes to status/ in the same volume, a directory owned by root that the API can read but not
# change; if the API replaces it, the updater discards the replacement.
#
# apply    receive the bundle (upload or HTTPS download, SHA-256 checked) -> verify it (zip layout, SHA256SUMS,
#          image digest pins, compose hardening gate) -> back up the running release (compose tree, .env and a
#          pg_dump of the platform database) -> docker load -> switch /opt/cloudgrange -> compose up -> health gate
#          -> on failure restore the previous release and database automatically.
# rollback restore the most recent backup on request.
# Bundle signatures are not verified yet (release signing is pending): a platform administrator uploading a
# bundle, or the configured update channel, is the trust decision.
import hashlib
import json
import os
import re
import shutil
import ssl
import stat
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import zipfile

UPDATER_VERSION = "1"
STATUS_SCHEMA = "cg-updater-status-v1"
ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$")
PG_NAME_RE = re.compile(r"^[A-Za-z0-9_]{1,63}$")
API_IMAGE_RE = re.compile(r"^ghcr\.io/cloudgrange/cloudgrange-api:([^@\s]+)@sha256:[0-9a-f]{64}$")
SUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  (\S.*)$")
MAX_REQUEST_BYTES = 64 * 1024
MAX_BUNDLE_BYTES = 8 * 1024 ** 3
MAX_EXTRACT_BYTES = 16 * 1024 ** 3
REQUIRED_FILES = ("SHA256SUMS", "images.txt", "cloudgrange-images.tar", "compose/docker-compose.yml",
                  "scripts/Test-ComposeImagePins.sh", "scripts/Test-ComposeHardening.py")
KEEP_BACKUPS = 2
KEEP_HISTORY = 20
UNITS = ("cloudgrange.service", "cloudgrange-realm-admin.service", "cloudgrange-updater.service")
CHUNK = 4 * 1024 * 1024


class UpdateError(Exception):
    def __init__(self, step, message):
        super().__init__(message)
        self.step = step


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def tail(data, limit=400):
    text = data.decode("utf-8", "replace") if isinstance(data, bytes) else (data or "")
    text = text.strip()
    return text[-limit:]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def parse_env(path):
    values = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    values[k.strip()] = v
    except FileNotFoundError:
        pass
    return values


def set_env_value(path, key, value):
    lines = []
    with open(path) as f:
        lines = [l for l in f.read().splitlines() if not l.startswith(key + "=")]
    lines.append("%s=%s" % (key, value))
    tmp = path + ".updater-tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def open_untrusted_file(dir_fd, name, limit):
    """Open a file from the API-writable volume: no symlinks, no FIFOs/devices, bounded size."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError as err:
        raise UpdateError("receiving", "cannot open %s safely (%s)" % (name, err.strerror))
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        raise UpdateError("receiving", "%s is not a regular file" % name)
    if st.st_size > limit:
        os.close(fd)
        raise UpdateError("receiving", "%s is larger than %d bytes" % (name, limit))
    return fd


def open_untrusted_dir(parent_fd, name):
    try:
        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError:
        return None


class Updater:
    def __init__(self):
        e = os.environ.get
        self.stack = e("CLOUDGRANGE_STACK_DIR", "/opt/cloudgrange")
        self.state_dir = e("CLOUDGRANGE_UPDATER_STATE", "/var/lib/cloudgrange-updater")
        self.systemd_dir = e("CLOUDGRANGE_SYSTEMD_DIR", "/etc/systemd/system")
        self.updater_bin = e("CLOUDGRANGE_UPDATER_BIN", "/usr/local/sbin/cloudgrange-updater")
        self.volume = e("CLOUDGRANGE_UPDATES_VOLUME", "cloudgrange_platform_updates")
        self.shared_override = e("CLOUDGRANGE_UPDATES_SHARED", "")
        self.health_timeout = float(e("CLOUDGRANGE_UPDATE_HEALTH_TIMEOUT", "300"))
        self.health_interval = float(e("CLOUDGRANGE_UPDATE_HEALTH_INTERVAL", "5"))
        self.poll = float(e("CLOUDGRANGE_UPDATER_POLL", "3"))
        # End-to-end probes through nginx TLS after the containers report healthy (portal, then the API behind it).
        self.probe_urls = e("CLOUDGRANGE_UPDATE_PROBE_URLS",
                            "https://127.0.0.1/health/ready https://127.0.0.1/api/v1/setup/status").split()
        self.lock = threading.Lock()
        self.step = "idle"
        os.makedirs(self.state_dir, 0o700, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.state = self._load_state()

    # ---- state and status -------------------------------------------------------------------------------
    def _state_path(self):
        return os.path.join(self.state_dir, "state.json")

    def _load_state(self):
        try:
            with open(self._state_path()) as f:
                state = json.load(f)
        except (FileNotFoundError, ValueError):
            state = {}
        state.setdefault("history", [])
        state.setdefault("job", None)
        state.setdefault("backups", [])
        job = state.get("job")
        if job and job.get("state") == "running":
            job.update(state="failed", finishedAt=now(),
                       message="The updater restarted during this job. If the platform is unhealthy, use Roll back.")
            self._archive(state, job)
        return state

    @staticmethod
    def _archive(state, job):
        state["history"] = ([dict(job)] + [h for h in state["history"] if h.get("id") != job.get("id")])[:KEEP_HISTORY]

    def current_version(self):
        return parse_env(os.path.join(self.stack, ".env")).get("CLOUDGRANGE_VERSION") or "unknown"

    def snapshot(self):
        backups = self.state.get("backups") or []
        return {
            "schema": STATUS_SCHEMA,
            "updaterVersion": UPDATER_VERSION,
            "heartbeatAt": now(),
            "currentVersion": self.current_version(),
            "job": self.state.get("job"),
            "rollbackAvailable": ({"version": backups[0]["version"], "createdAt": backups[0]["createdAt"]}
                                  if backups else None),
            "history": self.state.get("history", []),
        }

    def save(self):
        with self.lock:
            tmp = self._state_path() + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(self.state, f, indent=2)
            os.replace(tmp, self._state_path())
            self.publish()

    def shared_dir(self):
        if self.shared_override:
            return self.shared_override if os.path.isdir(self.shared_override) else None
        p = subprocess.run(["docker", "volume", "inspect", "-f", "{{.Mountpoint}}", self.volume],
                           capture_output=True, text=True)
        path = p.stdout.strip()
        return path if p.returncode == 0 and path and os.path.isdir(path) else None

    def _status_dir_fd(self, shared):
        root_fd = os.open(shared, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                st = os.stat("status", dir_fd=root_fd, follow_symlinks=False)
                if not stat.S_ISDIR(st.st_mode):
                    os.unlink("status", dir_fd=root_fd)
                elif st.st_uid != 0:
                    os.rename("status", "status.rejected-" + uuid.uuid4().hex, src_dir_fd=root_fd, dst_dir_fd=root_fd)
            except FileNotFoundError:
                pass
            try:
                os.mkdir("status", 0o755, dir_fd=root_fd)
            except FileExistsError:
                pass
            fd = os.open("status", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            st = os.fstat(fd)
            if st.st_uid != 0:
                os.close(fd)
                raise OSError("status directory is not root-owned")
            os.fchmod(fd, 0o755)
            return fd
        finally:
            os.close(root_fd)

    def publish(self):
        """Write the status document the API reads. Never raises: status is best effort."""
        shared = self.shared_dir()
        if not shared:
            return
        try:
            dir_fd = self._status_dir_fd(shared)
        except OSError:
            return
        try:
            tmp = ".updater.%s.tmp" % uuid.uuid4().hex
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
            with os.fdopen(fd, "w") as f:
                json.dump(self.snapshot(), f, indent=2)
            os.rename(tmp, "updater.json", src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except OSError:
            pass
        finally:
            os.close(dir_fd)

    def set_step(self, step, message=None):
        self.step = step
        job = self.state.get("job")
        if job:
            job["step"] = step
            if message is not None:
                job["message"] = message
        self.save()

    # ---- commands ---------------------------------------------------------------------------------------
    def run(self, args, cwd=None, stdin=None, stdout=None, timeout=3600, check=True):
        p = subprocess.run(args, cwd=cwd, stdin=stdin, stdout=stdout if stdout is not None else subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
        if check and p.returncode != 0:
            raise UpdateError(self.step, "%s failed (exit %d): %s" % (" ".join(args[:4]), p.returncode, tail(p.stderr)))
        return p

    def compose(self, args, **kw):
        return self.run(["docker", "compose", "--env-file", os.path.join(self.stack, ".env")] + args, cwd=self.stack, **kw)

    def pg_names(self):
        env = parse_env(os.path.join(self.stack, ".env"))
        user, db = env.get("POSTGRES_USER", "cloudgrange"), env.get("POSTGRES_DB", "cloudgrange")
        if not PG_NAME_RE.match(user) or not PG_NAME_RE.match(db):
            raise UpdateError(self.step, "unexpected POSTGRES_USER or POSTGRES_DB in .env")
        return user, db

    # ---- requests ---------------------------------------------------------------------------------------
    def take_requests(self):
        shared = self.shared_dir()
        if not shared:
            return []
        root_fd = os.open(shared, os.O_RDONLY | os.O_DIRECTORY)
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
        job = {"id": job_id, "action": "unknown", "state": "failed", "step": "queued", "startedAt": now(),
               "finishedAt": now(), "message": message, "targetVersion": None, "previousVersion": self.current_version()}
        self._archive(self.state, job)
        self.save()

    def handle(self, req):
        action = req.get("action")
        requested_by = str(req.get("requestedBy") or "")[:200]
        job = {"id": req["id"], "action": action, "state": "running", "step": "queued", "startedAt": now(),
               "finishedAt": None, "message": None, "targetVersion": None, "previousVersion": self.current_version(),
               "requestedBy": requested_by}
        busy = self.state.get("job")
        if busy and busy.get("state") == "running":
            job.update(state="failed", finishedAt=now(), message="another update job is running")
            self._archive(self.state, job)
            self.save()
            return
        self.state["job"] = job
        self.save()
        try:
            if action == "apply":
                self.apply(req, job)
            elif action == "rollback":
                self.manual_rollback(job)
            else:
                raise UpdateError("queued", "unknown action %r" % action)
        except UpdateError as err:
            if job["state"] == "running":
                job.update(state="failed", message=str(err))
        except Exception as err:  # noqa: BLE001 - never leave a job running
            job.update(state="failed", message="unexpected error: %s" % err)
        finally:
            job["finishedAt"] = now()
            self._archive(self.state, job)
            self.save()
            work = os.path.join(self.state_dir, "work", job["id"])
            shutil.rmtree(work, ignore_errors=True)
        if job["state"] == "succeeded" and getattr(self, "restart_self", False):
            subprocess.run(["systemd-run", "--on-active=5", "systemctl", "restart", "cloudgrange-updater.service"],
                           capture_output=True)

    # ---- apply ------------------------------------------------------------------------------------------
    def apply(self, req, job):
        work = os.path.join(self.state_dir, "work", job["id"])
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, 0o700)
        zpath = os.path.join(work, "bundle.zip")

        self.set_step("receiving")
        if req.get("source") == "url":
            self.download(req, zpath)
        else:
            self.receive_upload(req, zpath)

        self.set_step("verifying")
        bundle = os.path.join(work, "bundle")
        self.extract(zpath, bundle)
        os.unlink(zpath)
        version = self.verify(bundle)
        job["targetVersion"] = version
        current = self.current_version()
        if version == current:
            raise UpdateError("verifying", "version %s is already installed" % version)
        self.run(["bash", "scripts/Test-ComposeImagePins.sh", "compose"], cwd=bundle, timeout=600)
        self.run(["python3", "scripts/Test-ComposeHardening.py", "compose"], cwd=bundle, timeout=600)

        self.set_step("backing-up")
        backup = self.backup(current)

        try:
            self.set_step("loading-images")
            self.run(["docker", "load", "-i", os.path.join(bundle, "cloudgrange-images.tar")], timeout=3600)
            self.set_step("switching")
            self.switch(os.path.join(bundle, "compose"), version)
            self.set_step("starting")
            self.start_stack()
            self.set_step("health-check")
            self.health_gate()
        except UpdateError as err:
            failure = "%s failed: %s" % (err.step, err)
            try:
                self.restore(backup)
            except UpdateError as rerr:
                job.update(state="failed", message="%s. Automatic rollback also failed (%s): %s" % (failure, rerr.step, rerr))
                return
            # The restored backup is the running release again: it is not a rollback target any more.
            self.state["backups"] = [b for b in self.state.get("backups") or [] if b.get("path") != backup["path"]]
            shutil.rmtree(backup["path"], ignore_errors=True)
            job.update(state="rolled-back", message="%s. Restored %s and its database." % (failure, backup["version"]))
            return

        self.set_step("finalizing")
        self.install_host_files()
        job.update(state="succeeded", message="Updated from %s to %s." % (current, version))

    def receive_upload(self, req, zpath):
        bundle_id = str(req.get("bundleId") or "")
        if not ID_RE.match(bundle_id):
            raise UpdateError("receiving", "bundleId is missing or invalid")
        expected = str(req.get("sha256") or "").lower()
        shared = self.shared_dir()
        if not shared:
            raise UpdateError("receiving", "the updates volume is not available")
        root_fd = os.open(shared, os.O_RDONLY | os.O_DIRECTORY)
        try:
            inc_fd = open_untrusted_dir(root_fd, "incoming")
            if inc_fd is None:
                raise UpdateError("receiving", "no uploaded bundle found")
            try:
                name = bundle_id + ".zip"
                src_fd = open_untrusted_file(inc_fd, name, MAX_BUNDLE_BYTES)
                h = hashlib.sha256()
                with os.fdopen(src_fd, "rb") as src, open(zpath, "wb") as dst:
                    for block in iter(lambda: src.read(CHUNK), b""):
                        h.update(block)
                        dst.write(block)
                try:
                    os.unlink(name, dir_fd=inc_fd)
                except OSError:
                    pass
            finally:
                os.close(inc_fd)
        finally:
            os.close(root_fd)
        if expected and h.hexdigest() != expected:
            raise UpdateError("receiving", "uploaded bundle SHA-256 does not match the upload record")

    def download(self, req, zpath):
        url = str(req.get("url") or "")
        expected = str(req.get("sha256") or "").lower()
        if not url.startswith("https://"):
            raise UpdateError("receiving", "only https:// bundle URLs are accepted")
        if not SHA_RE.match(expected):
            raise UpdateError("receiving", "a SHA-256 is required for a downloaded bundle")
        h = hashlib.sha256()
        total = 0
        try:
            with urllib.request.urlopen(url, timeout=60) as resp, open(zpath, "wb") as dst:
                for block in iter(lambda: resp.read(CHUNK), b""):
                    total += len(block)
                    if total > MAX_BUNDLE_BYTES:
                        raise UpdateError("receiving", "download exceeds %d bytes" % MAX_BUNDLE_BYTES)
                    h.update(block)
                    dst.write(block)
        except OSError as err:
            raise UpdateError("receiving", "download failed: %s" % err)
        if h.hexdigest() != expected:
            raise UpdateError("receiving", "downloaded bundle SHA-256 does not match the release channel")

    def extract(self, zpath, dest):
        try:
            z = zipfile.ZipFile(zpath)
        except zipfile.BadZipFile:
            raise UpdateError("verifying", "the bundle is not a zip archive")
        with z:
            total = 0
            for info in z.infolist():
                parts = info.filename.split("/")
                if info.filename.startswith("/") or "\\" in info.filename or ".." in parts or ":" in parts[0]:
                    raise UpdateError("verifying", "unsafe path in bundle: %r" % info.filename)
                kind = (info.external_attr >> 16) & 0o170000
                if kind and not (stat.S_ISREG(kind) or stat.S_ISDIR(kind)):
                    raise UpdateError("verifying", "links and special files are not allowed in a bundle: %r" % info.filename)
                total += info.file_size
                if total > MAX_EXTRACT_BYTES:
                    raise UpdateError("verifying", "bundle expands beyond %d bytes" % MAX_EXTRACT_BYTES)
            os.makedirs(dest, 0o700)
            for info in z.infolist():
                target = os.path.join(dest, *[p for p in info.filename.split("/") if p not in ("", ".")])
                if info.is_dir():
                    os.makedirs(target, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with z.open(info) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst, CHUNK)

    def verify(self, bundle):
        for rel in REQUIRED_FILES:
            if not os.path.isfile(os.path.join(bundle, rel)):
                raise UpdateError("verifying", "bundle is missing %s" % rel)
        sums = {}
        with open(os.path.join(bundle, "SHA256SUMS")) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                m = SUM_LINE_RE.match(line)
                if not m:
                    raise UpdateError("verifying", "malformed SHA256SUMS line")
                sums[m.group(2)] = m.group(1)
        files = set()
        for root, _dirs, names in os.walk(bundle):
            for n in names:
                rel = os.path.relpath(os.path.join(root, n), bundle).replace(os.sep, "/")
                if rel != "SHA256SUMS":
                    files.add(rel)
        if set(sums) != files:
            diff = sorted(set(sums) ^ files)[:5]
            raise UpdateError("verifying", "SHA256SUMS does not list exactly the bundle files: %s" % ", ".join(diff))
        for rel, digest in sorted(sums.items()):
            if sha256_file(os.path.join(bundle, rel)) != digest:
                raise UpdateError("verifying", "SHA-256 mismatch for %s" % rel)
        version = None
        with open(os.path.join(bundle, "images.txt")) as f:
            for line in f:
                m = API_IMAGE_RE.match(line.strip())
                if m:
                    version = m.group(1)
        if not version or not VERSION_RE.match(version):
            raise UpdateError("verifying", "images.txt has no digest-pinned cloudgrange-api image with a valid version")
        return version

    # ---- backup, switch, health, restore ----------------------------------------------------------------
    def backup(self, version):
        user, db = self.pg_names()
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        path = os.path.join(self.state_dir, "backups", "%s-%s" % (stamp, uuid.uuid4().hex[:8]))
        os.makedirs(path, 0o700)
        shutil.copytree(self.stack, os.path.join(path, "stack"), symlinks=True)
        dump = os.path.join(path, "database.dump")
        fd = os.open(dump, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            self.compose(["exec", "-T", "postgres", "pg_dump", "-U", user, "-d", db, "-Fc"], stdout=f, timeout=3600)
        if os.path.getsize(dump) == 0:
            raise UpdateError("backing-up", "the database backup is empty")
        record = {"version": version, "createdAt": now(), "path": path}
        self.state["backups"] = [record] + (self.state.get("backups") or [])
        for old in self.state["backups"][KEEP_BACKUPS:]:
            shutil.rmtree(old.get("path", ""), ignore_errors=True)
        self.state["backups"] = self.state["backups"][:KEEP_BACKUPS]
        self.save()
        return record

    def _replace_stack(self, source, keep=(".env", ".env.appliance")):
        for entry in os.listdir(self.stack):
            if entry in keep:
                continue
            p = os.path.join(self.stack, entry)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.unlink(p)
        for entry in os.listdir(source):
            if entry in keep:
                continue
            s, d = os.path.join(source, entry), os.path.join(self.stack, entry)
            if os.path.isdir(s) and not os.path.islink(s):
                shutil.copytree(s, d, symlinks=True)
            else:
                shutil.copy2(s, d, follow_symlinks=False)
        for root, dirs, names in os.walk(self.stack):
            for n in dirs + names:
                p = os.path.join(root, n)
                os.lchown(p, 0, 0)
                if not os.path.islink(p):
                    os.chmod(p, os.stat(p).st_mode & ~0o022)

    def switch(self, compose_dir, version):
        self._replace_stack(compose_dir)
        set_env_value(os.path.join(self.stack, ".env"), "CLOUDGRANGE_VERSION", version)

    def _ps(self):
        out = self.compose(["ps", "-a", "--format", "json"], check=False, timeout=120).stdout.decode("utf-8", "replace").strip()
        if not out:
            return []
        if out.startswith("["):
            return json.loads(out)
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def start_stack(self):
        self.compose(["up", "-d", "--remove-orphans"], timeout=1800)
        # nginx resolves the portal upstream once at start; recreate it so it never proxies to a replaced container.
        self.compose(["up", "-d", "--no-deps", "--force-recreate", "nginx"], timeout=600)

    def probe(self, url):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # the appliance's own certificate on 127.0.0.1
        try:
            with urllib.request.urlopen(url, timeout=10, context=ctx) as resp:
                return resp.status == 200
        except (OSError, ValueError):
            return False

    def health_gate(self):
        services = [s for s in self.compose(["config", "--services"], timeout=120).stdout.decode().split() if s]
        deadline = time.monotonic() + self.health_timeout
        while True:
            pending = ["%s (not answering 200)" % u for u in self.probe_urls if not self.probe(u)]
            try:
                containers = {c.get("Service"): c for c in self._ps()}
            except ValueError:
                containers = {}
            for svc in services:
                c = containers.get(svc)
                if c is None:
                    pending.append("%s (no container)" % svc)
                elif svc == "healthcheck-tools":
                    if not (c.get("State") == "exited" and int(c.get("ExitCode", 1)) == 0):
                        pending.append("%s (%s)" % (svc, c.get("State")))
                elif c.get("State") != "running" or c.get("Health") != "healthy":
                    pending.append("%s (%s/%s)" % (svc, c.get("State"), c.get("Health") or "no health"))
            if not pending:
                return
            if time.monotonic() > deadline:
                raise UpdateError("health-check", "not healthy after %ds: %s" % (self.health_timeout, ", ".join(pending)))
            time.sleep(self.health_interval)

    def restore(self, backup):
        self.set_step("rolling-back")
        path = backup["path"]
        if not os.path.isdir(os.path.join(path, "stack")) or not os.path.isfile(os.path.join(path, "database.dump")):
            raise UpdateError("rolling-back", "backup %s is incomplete" % path)
        self.compose(["stop", "cloudgrange-api", "cloudgrange-relay", "keycloak"], check=False, timeout=600)
        self._replace_stack(os.path.join(path, "stack"), keep=())
        user, db = self.pg_names()
        self.compose(["up", "-d", "postgres"], timeout=600)
        deadline = time.monotonic() + 120
        while self.compose(["exec", "-T", "postgres", "pg_isready", "-U", user, "-d", "postgres"], check=False, timeout=60).returncode != 0:
            if time.monotonic() > deadline:
                raise UpdateError("rolling-back", "PostgreSQL did not become ready")
            time.sleep(2)
        self.compose(["exec", "-T", "postgres", "dropdb", "-U", user, "--force", "--if-exists", db], timeout=600)
        self.compose(["exec", "-T", "postgres", "createdb", "-U", user, db], timeout=600)
        with open(os.path.join(path, "database.dump"), "rb") as f:
            self.compose(["exec", "-T", "postgres", "pg_restore", "-U", user, "-d", db, "--no-owner", "--exit-on-error"],
                         stdin=f, timeout=3600)
        self.start_stack()
        self.set_step("health-check")
        self.health_gate()
        self.install_host_files()

    def manual_rollback(self, job):
        backups = self.state.get("backups") or []
        if not backups:
            raise UpdateError("rolling-back", "no backup is available to roll back to")
        backup = backups[0]
        job["targetVersion"] = backup["version"]
        current = self.current_version()
        self.restore(backup)
        self.state["backups"] = backups[1:]
        shutil.rmtree(backup["path"], ignore_errors=True)
        job.update(state="succeeded", message="Rolled back from %s to %s." % (current, backup["version"]))

    def install_host_files(self):
        """Refresh the systemd units and this updater from the installed release (self-update on next restart)."""
        changed = False
        for unit in UNITS:
            src = os.path.join(self.stack, "systemd", unit)
            if os.path.isfile(src):
                dst = os.path.join(self.systemd_dir, unit)
                if not os.path.isfile(dst) or sha256_file(src) != sha256_file(dst):
                    shutil.copyfile(src, dst)
                    os.chmod(dst, 0o644)
                    changed = True
        if changed:
            self.run(["systemctl", "daemon-reload"], check=False, timeout=120)
        src = os.path.join(self.stack, "updater", "cloudgrange-updater.py")
        if os.path.isfile(src) and (not os.path.isfile(self.updater_bin) or sha256_file(src) != sha256_file(self.updater_bin)):
            shutil.copyfile(src, self.updater_bin)
            os.chmod(self.updater_bin, 0o755)
            self.restart_self = True

    # ---- loop -------------------------------------------------------------------------------------------
    def process_once(self):
        for req in self.take_requests():
            self.handle(req)
        self.publish()

    def heartbeat(self, stop):
        while not stop.wait(5):
            with self.lock:
                self.publish()

    def serve(self):
        self.save()
        stop = threading.Event()
        threading.Thread(target=self.heartbeat, args=(stop,), daemon=True).start()
        while True:
            try:
                for req in self.take_requests():
                    self.handle(req)
            except OSError as err:
                print("[cloudgrange-updater] %s" % err, file=sys.stderr)
            time.sleep(self.poll)


def main(argv):
    os.umask(0o022)
    updater = Updater()
    if "--once" in argv:
        updater.process_once()
        return 0
    updater.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
