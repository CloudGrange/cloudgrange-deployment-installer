#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (E3) — cloudgrange-updater-k3s: the FOUNDATION updater of a managed K3s foundation.
#
# Owner decisions, 2026-09-18 (cloudgrange-internal/pmo/plans/2026-09-18-foundation-platform-separation.md §3):
#   1. An admin always clicks. Nothing here runs on its own: this service acts ONLY on a request the API
#      wrote after an administrator pressed a button. There is no timer, no periodic check and no
#      "apply security patches automatically". unattended-upgrades is disabled by the installers.
#   2. Foundation and Platform are separate. This service no longer touches the Platform at all — no
#      helm, no image import, no database dump. Platform updates run IN the cluster (the chart's
#      platform-updater Job), so they work on BYO Kubernetes and AKS too. A Platform request
#      ("apply"/"rollback") sent by an older API is refused with an explicit message.
#   3. The host service stays, for Foundation updates only: Ubuntu packages, the pinned K3s version and
#      CloudGrange's own host files.
#
# Interface (binding, plan §4 "Host service <-> API"):
#   requests/<uuid>.json   written by the API, {"action": "<type>", ...}
#       foundation-check     refresh apt lists, count upgradable/security packages, read reboot-required
#                            and the running K3s version, and read the Foundation channel if configured.
#       foundation-apply     {"version", "confirmReboot", optional "bundleId"+"sha256" (an uploaded,
#                            air-gapped Foundation bundle in incoming/<bundleId>.zip), optional
#                            "supportedKubeRange" (the installed chart's kubeVersion)}
#       foundation-rollback  K3s back to the previous pinned version + restore replaced host files.
#   status/foundation.json written here only:
#       {installedVersion, availableVersion, k3sVersion, targetK3sVersion, osUpdatesAvailable,
#        rebootRequired, state, message, updatedAt}
#       osUpdatesAvailable is an INTEGER (number of upgradable OS packages; the security subset is in
#       message). state is one of idle|running|succeeded|failed|rolled-back.
#
# A Foundation release is a zip holding foundation-release.json, its signature
# foundation-release.json.sig, and the files the manifest names (the K3s binary, K3s's own install.sh,
# optionally the K3s air-gap image tarball, and host files). The manifest is signed with the release
# key (ECDSA/RSA, verified with `openssl dgst -sha256 -verify`, which also accepts a base64 cosign
# sign-blob signature) and pins the SHA-256 of every other file, so the signature covers the whole
# release. With no usable public key installed the apply is REFUSED — never "unsigned is fine".
#
# Trust boundary (unchanged from the Compose-era updater). The API pod is non-root and can only drop
# requests and uploaded bundles into the shared updates directory (requests/, incoming/). Everything
# there is untrusted: files are opened O_NOFOLLOW, must be regular files, and are copied into root-only
# state (/var/lib/cloudgrange-updater) before use. status/ is root-owned; the API can read it but not
# change it, and a status/ the API replaced is moved aside and recreated.
import base64
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
import uuid
import zipfile

UPDATER_VERSION = "2"
MANIFEST_SCHEMA = "cg-foundation-release-v1"
MANIFEST_NAME = "foundation-release.json"
SIGNATURE_NAME = "foundation-release.json.sig"
STATUS_NAME = "foundation.json"
PACKAGES_NAME = "foundation-packages.json"
STATUS_KEYS = ("installedVersion", "availableVersion", "k3sVersion", "targetK3sVersion",
               "osUpdatesAvailable", "rebootRequired", "state", "message", "updatedAt")
STATES = ("idle", "running", "succeeded", "failed", "rolled-back")
ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$")
K3S_VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+\+k3s\d+$")
APT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]{0,127}$")
APT_VERSION_RE = re.compile(r"^[0-9A-Za-z.+~:-]{1,128}$")
MAX_REQUEST_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_BUNDLE_BYTES = 8 * 1024 ** 3
MAX_EXTRACT_BYTES = 16 * 1024 ** 3
KEEP_HISTORY = 20
CHUNK = 4 * 1024 * 1024
LEGACY_PLATFORM_ACTIONS = ("apply", "rollback")
# Packages whose upgrade Ubuntu itself flags as needing a reboot (update-notifier's own triggers).
REBOOT_PACKAGE_RE = re.compile(r"^(linux-(image|modules|generic|virtual|kvm|azure|hwe|firmware)|libc6$|dbus)")
# Host files a Foundation release may write. A signed manifest is still limited to CloudGrange's own
# files: it can never rewrite, say, /etc/sudoers or /etc/ssh.
HOST_FILE_PREFIXES = ("/etc/cloudgrange/", "/usr/local/sbin/cloudgrange-", "/usr/local/lib/cloudgrange/",
                      "/etc/systemd/system/cloudgrange-", "/etc/rancher/k3s/config.yaml.d/",
                      "/etc/apt/apt.conf.d/99cloudgrange")
SELF_PATH = "/usr/local/sbin/cloudgrange-updater-k3s.py"


class UpdateError(Exception):
    pass


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def tail(data, limit=400):
    text = data if isinstance(data, str) else (data or b"").decode("utf-8", "replace")
    text = text.strip()
    return text[-limit:] if len(text) > limit else text


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


# ---- version ranges --------------------------------------------------------------------------------
# Enough of Helm's semver constraint syntax to evaluate a chart's kubeVersion (">=1.30.0-0 <1.37.0-0",
# "~1.34", "1.34.x", "^1.30", alternatives joined with ||). Anything else is refused, not guessed.
_CMP_RE = re.compile(r"^(>=|<=|>|<|=|!=|~|\^)?v?(\d+)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")


def parse_version(text):
    m = re.match(r"^v?(\d+)\.(\d+)(?:\.(\d+))?", str(text or "").strip())
    if not m:
        raise UpdateError("cannot parse version %r" % tail(str(text), 40))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))


def _comparator(token):
    m = _CMP_RE.match(token)
    if not m:
        raise UpdateError("cannot evaluate version constraint %r" % token)
    op, major = m.group(1) or "", int(m.group(2))
    minor, patch = m.group(3), m.group(4)
    wild_minor = minor is None or minor in ("x", "X", "*")
    wild_patch = wild_minor or patch is None or patch in ("x", "X", "*")
    lo = (major, 0 if wild_minor else int(minor), 0 if wild_patch else int(patch))
    if op == "~" or (op in ("", "=") and (wild_minor or wild_patch)):
        hi = (major + 1, 0, 0) if wild_minor else (major, lo[1] + 1, 0)
        if op == "~" and not wild_patch:
            hi = (major, lo[1] + 1, 0)
        return lambda v: lo <= v < hi
    if op == "^":
        hi = (major + 1, 0, 0) if major > 0 else (0, lo[1] + 1, 0)
        return lambda v: lo <= v < hi
    return {
        "": lambda v: v == lo, "=": lambda v: v == lo, "!=": lambda v: v != lo,
        ">=": lambda v: v >= lo, "<=": lambda v: v <= lo, ">": lambda v: v > lo, "<": lambda v: v < lo,
    }[op]


def version_satisfies(version, constraint):
    v = parse_version(version)
    alternatives = [a.strip() for a in str(constraint).split("||") if a.strip()]
    if not alternatives:
        raise UpdateError("empty version constraint")
    for alt in alternatives:
        tokens = [t for t in re.split(r"[\s,]+", alt) if t]
        # "<= 1.2" style with a space after the operator.
        joined, i = [], 0
        while i < len(tokens):
            if tokens[i] in (">=", "<=", ">", "<", "=", "!=", "~", "^") and i + 1 < len(tokens):
                joined.append(tokens[i] + tokens[i + 1])
                i += 2
            else:
                joined.append(tokens[i])
                i += 1
        if all(_comparator(t)(v) for t in joined):
            return True
    return False


class FoundationUpdater:
    def __init__(self):
        e = os.environ.get
        self.state_dir = e("CLOUDGRANGE_UPDATER_STATE", "/var/lib/cloudgrange-updater")
        self.shared = e("CLOUDGRANGE_UPDATES_SHARED", "/var/lib/cloudgrange/updates")
        self.kubeconfig = e("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
        self.pubkey = e("CLOUDGRANGE_FOUNDATION_PUBKEY", "/etc/cloudgrange/foundation-signing-key.pub")
        self.version_file = e("CLOUDGRANGE_FOUNDATION_VERSION_FILE", "/etc/cloudgrange/foundation-version")
        self.channel_file = e("CLOUDGRANGE_FOUNDATION_CHANNEL_FILE", "/etc/cloudgrange/foundation-channel-url")
        self.channel_url = e("CLOUDGRANGE_FOUNDATION_CHANNEL_URL", "")
        self.reboot_file = e("CLOUDGRANGE_REBOOT_REQUIRED_FILE", "/var/run/reboot-required")
        # Tests point this at a scratch directory; on a host it is "/".
        self.host_root = e("CLOUDGRANGE_HOST_ROOT", "/")
        self.k3s_bin = e("CLOUDGRANGE_K3S_BIN", "/usr/local/bin/k3s")
        self.k3s_images_dir = e("CLOUDGRANGE_K3S_IMAGES_DIR", "/var/lib/rancher/k3s/agent/images")
        self.health_timeout = float(e("CLOUDGRANGE_UPDATE_HEALTH_TIMEOUT", "600"))
        self.health_interval = float(e("CLOUDGRANGE_UPDATE_HEALTH_INTERVAL", "5"))
        self.reboot_delay = int(e("CLOUDGRANGE_FOUNDATION_REBOOT_DELAY", "60"))
        self.poll = float(e("CLOUDGRANGE_UPDATER_POLL", "3"))
        self.headroom = int(e("CLOUDGRANGE_FOUNDATION_HEADROOM_BYTES", str(2 * 1024 ** 3)))
        os.makedirs(self.state_dir, 0o700, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.state = self._load_state()

    # ---- process helpers ------------------------------------------------------------------------
    def _env(self, extra=None):
        env = dict(os.environ)
        env["KUBECONFIG"] = self.kubeconfig
        env["DEBIAN_FRONTEND"] = "noninteractive"
        env.update(extra or {})
        return env

    def run(self, args, timeout=900, check=True, extra_env=None):
        proc = subprocess.run(args, capture_output=True, env=self._env(extra_env), timeout=timeout)
        if check and proc.returncode != 0:
            raise UpdateError("%s failed: %s" % (" ".join(args[:2]), tail(proc.stderr or proc.stdout)))
        return proc

    def host_path(self, absolute):
        return os.path.join(self.host_root, absolute.lstrip("/"))

    # ---- state ----------------------------------------------------------------------------------
    def _state_path(self):
        return os.path.join(self.state_dir, "state.json")

    def _load_state(self):
        try:
            with open(self._state_path(), "rb") as f:
                state = json.loads(f.read().decode("utf-8"))
            if isinstance(state, dict):
                state.setdefault("history", [])
                state.setdefault("facts", {})
                return state
        except (OSError, ValueError):
            pass
        return {"job": None, "history": [], "facts": {}, "rollback": None}

    def save(self):
        tmp = self._state_path() + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self._state_path())
        self.write_status()

    def facts(self):
        return self.state.setdefault("facts", {})

    def set_message(self, state, message):
        facts = self.facts()
        facts["state"] = state
        facts["message"] = message
        self.save()

    # ---- facts about the host -------------------------------------------------------------------
    def installed_version(self):
        try:
            with open(self.version_file, "r", encoding="utf-8") as f:
                value = f.read().strip()
            return value if VERSION_RE.match(value) else None
        except OSError:
            return None

    def k3s_version(self):
        try:
            proc = self.run(["k3s", "--version"], timeout=60, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        m = re.search(r"k3s version (v\S+)", (proc.stdout or b"").decode("utf-8", "replace"))
        return m.group(1) if m else None

    def reboot_required(self):
        return os.path.exists(self.reboot_file)

    # ---- status ---------------------------------------------------------------------------------
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

    def status_document(self):
        facts = self.facts()
        state = facts.get("state") or "idle"
        return {
            "installedVersion": self.installed_version(),
            "availableVersion": facts.get("availableVersion"),
            "k3sVersion": self.k3s_version(),
            "targetK3sVersion": facts.get("targetK3sVersion"),
            "osUpdatesAvailable": facts.get("osUpdatesAvailable"),
            "rebootRequired": self.reboot_required(),
            "state": state if state in STATES else "idle",
            "message": facts.get("message"),
            "updatedAt": now(),
        }

    def write_status(self):
        """Write status/foundation.json (the §4 contract) and status/foundation-packages.json (the exact
        OS packages the last check found, so the Foundation card can list them before an admin confirms,
        plan §5). Best effort; never raises into the job path."""
        doc = self.status_document()
        packages = {"updatedAt": doc["updatedAt"], "checkedAt": self.facts().get("checkedAt"),
                    "packages": self.facts().get("packages") or []}
        try:
            dir_fd = self._status_dir_fd()
        except (OSError, UpdateError):
            return
        try:
            for name, content in ((PACKAGES_NAME, packages), (STATUS_NAME, doc)):
                body = json.dumps(content, indent=2, sort_keys=True).encode("utf-8")
                tmp = name + ".tmp"
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
                with os.fdopen(fd, "wb") as f:
                    f.write(body)
                    f.flush()
                    os.fsync(f.fileno())
                os.rename(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            # The Platform-era status document is no longer maintained; leaving a stale one would let an
            # older API show Platform update progress that nothing will ever advance.
            for stale in ("status.json", "updater.json"):
                try:
                    os.unlink(stale, dir_fd=dir_fd)
                except OSError:
                    pass
        except OSError:
            pass
        finally:
            os.close(dir_fd)

    # ---- requests -------------------------------------------------------------------------------
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
                        self._finish(self._new_job(name[:-5], "unknown", ""), "failed", "invalid request: %s" % err)
                return taken
            finally:
                os.close(req_fd)
        finally:
            os.close(root_fd)

    # ---- channel --------------------------------------------------------------------------------
    def channel(self):
        url = self.channel_url
        if not url:
            try:
                with open(self.channel_file, "r", encoding="utf-8") as f:
                    url = f.read().strip()
            except OSError:
                url = ""
        if not url:
            return None
        if not url.startswith("https://") and not url.startswith("file://"):
            raise UpdateError("the Foundation channel URL must be https://")
        with urllib.request.urlopen(url, timeout=30) as resp:
            body = resp.read(MAX_MANIFEST_BYTES + 1)
        if len(body) > MAX_MANIFEST_BYTES:
            raise UpdateError("the Foundation channel document is too large")
        doc = json.loads(body.decode("utf-8"))
        releases = doc.get("releases") if isinstance(doc, dict) else None
        if not isinstance(releases, list):
            raise UpdateError("the Foundation channel document has no releases list")
        good = [r for r in releases if isinstance(r, dict) and VERSION_RE.match(str(r.get("version") or ""))]
        return good

    @staticmethod
    def _version_key(version):
        return tuple(int(n) for n in re.findall(r"\d+", str(version)))

    def latest_release(self, releases):
        if not releases:
            return None
        return max(releases, key=lambda r: self._version_key(r["version"]))

    # ---- apt ------------------------------------------------------------------------------------
    def apt_refresh(self):
        proc = self.run(["apt-get", "update", "-qq"], timeout=900, check=False)
        return proc.returncode == 0

    def apt_upgradable(self):
        """[(name, candidate_version, is_security)] from `apt list --upgradable`."""
        proc = self.run(["apt", "list", "--upgradable"], timeout=300, check=False)
        result = []
        for line in (proc.stdout or b"").decode("utf-8", "replace").splitlines():
            # openssl/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]
            m = re.match(r"^([^/\s]+)/(\S+)\s+(\S+)\s", line)
            if not m:
                continue
            result.append((m.group(1), m.group(3), "-security" in m.group(2)))
        return result

    # ---- actions --------------------------------------------------------------------------------
    def do_check(self, req, job):
        refreshed = self.apt_refresh()
        packages = self.apt_upgradable()
        security = sum(1 for p in packages if p[2])
        facts = self.facts()
        facts["osUpdatesAvailable"] = len(packages)
        facts["osSecurityUpdatesAvailable"] = security
        facts["packages"] = [{"name": n, "version": v, "security": sec} for n, v, sec in packages]
        facts["checkedAt"] = now()
        notes = ["%d OS package update(s) available, %d of them security" % (len(packages), security)]
        if not refreshed:
            notes.append("package lists could not be refreshed (no network?) — counts are from the last refresh")
        try:
            latest = self.latest_release(self.channel())
        except (UpdateError, OSError, ValueError) as err:
            latest = None
            notes.append("Foundation channel unavailable: %s" % tail(str(err), 160))
        if latest:
            facts["availableVersion"] = latest["version"]
            k3s = str(latest.get("k3sVersion") or "")
            facts["targetK3sVersion"] = k3s if K3S_VERSION_RE.match(k3s) else None
        if self.reboot_required():
            notes.append("a reboot is already pending on this host")
        job["checkedAt"] = now()
        return "idle", "; ".join(notes)

    # -- staging a release --
    def stage_upload(self, req):
        bundle_id = str(req.get("bundleId") or "")
        if not ID_RE.match(bundle_id):
            raise UpdateError("request does not name an uploaded bundle (bundleId)")
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
                name = bundle_id + ".zip"
                try:
                    fd = open_untrusted_file(inc_fd, name, MAX_BUNDLE_BYTES)
                except OSError as err:
                    raise UpdateError("cannot open the uploaded bundle: %s" % err.strerror)
                digest = hashlib.sha256()
                with os.fdopen(fd, "rb") as src, open(staged, "wb") as dst:
                    for chunk in iter(lambda: src.read(CHUNK), b""):
                        digest.update(chunk)
                        dst.write(chunk)
                for leftover in (name, bundle_id + ".json"):
                    try:
                        os.unlink(leftover, dir_fd=inc_fd)
                    except OSError:
                        pass
            finally:
                os.close(inc_fd)
        finally:
            os.close(root_fd)
        if digest.hexdigest() != expected:
            os.unlink(staged)
            raise UpdateError("bundle sha256 mismatch: expected %s, got %s" % (expected, digest.hexdigest()))
        return staged

    def stage_download(self, version):
        releases = self.channel()
        if releases is None:
            raise UpdateError("no Foundation release was uploaded and no Foundation channel is configured")
        entry = next((r for r in releases if r["version"] == version), None)
        if entry is None:
            raise UpdateError("Foundation release %s is not in the channel" % version)
        url, expected = str(entry.get("bundleUrl") or ""), str(entry.get("sha256") or "").lower()
        if not url.startswith("https://") and not url.startswith("file://"):
            raise UpdateError("the Foundation release URL must be https://")
        if not SHA_RE.match(expected):
            raise UpdateError("the channel entry for %s has no valid sha256" % version)
        staged = os.path.join(self.state_dir, "staged.zip")
        digest, total = hashlib.sha256(), 0
        with urllib.request.urlopen(url, timeout=60) as resp, open(staged, "wb") as dst:
            for chunk in iter(lambda: resp.read(CHUNK), b""):
                total += len(chunk)
                if total > MAX_BUNDLE_BYTES:
                    raise UpdateError("the Foundation release download is larger than allowed")
                digest.update(chunk)
                dst.write(chunk)
        if digest.hexdigest() != expected:
            os.unlink(staged)
            raise UpdateError("downloaded Foundation release sha256 mismatch")
        return staged

    def extract(self, staged):
        work = os.path.join(self.state_dir, "work")
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, 0o700)
        total = 0
        with zipfile.ZipFile(staged) as z:
            for info in z.infolist():
                # Reject absolute paths and traversal before writing anything.
                if info.filename.startswith("/") or ".." in info.filename.split("/") or "\\" in info.filename:
                    raise UpdateError("bundle contains an unsafe path: %s" % info.filename)
                if (info.external_attr >> 16) and stat.S_ISLNK(info.external_attr >> 16):
                    raise UpdateError("bundle contains a symlink: %s" % info.filename)
                total += info.file_size
                if total > MAX_EXTRACT_BYTES:
                    raise UpdateError("bundle expands beyond %d bytes" % MAX_EXTRACT_BYTES)
            z.extractall(work)
        return work

    def verify_signature(self, work):
        manifest = os.path.join(work, MANIFEST_NAME)
        signature = os.path.join(work, SIGNATURE_NAME)
        if not os.path.isfile(manifest) or not os.path.isfile(signature):
            raise UpdateError("bundle is not a signed Foundation release (%s and %s required)" % (MANIFEST_NAME, SIGNATURE_NAME))
        try:
            with open(self.pubkey, "rb") as f:
                key = f.read()
        except OSError:
            raise UpdateError("no Foundation release signing key installed at %s — refusing an unverifiable release" % self.pubkey)
        if b"PLACEHOLDER" in key or b"-----BEGIN PUBLIC KEY-----" not in key:
            raise UpdateError("the Foundation release signing key at %s is a placeholder — refusing an unverifiable release" % self.pubkey)
        with open(signature, "rb") as f:
            sig = f.read()
        # cosign sign-blob writes base64; openssl wants the raw DER. Accept both.
        der = os.path.join(work, ".sig.der")
        stripped = sig.strip()
        if re.match(rb"^[A-Za-z0-9+/=\r\n]+$", stripped):
            try:
                sig = base64.b64decode(stripped, validate=False)
            except ValueError:
                pass
        with open(der, "wb") as f:
            f.write(sig)
        proc = self.run(["openssl", "dgst", "-sha256", "-verify", self.pubkey, "-signature", der, manifest],
                        timeout=60, check=False)
        os.unlink(der)
        if proc.returncode != 0 or b"Verified OK" not in (proc.stdout or b""):
            raise UpdateError("Foundation release signature verification FAILED — the release was not applied")

    def load_manifest(self, work):
        with open(os.path.join(work, MANIFEST_NAME), "rb") as f:
            body = f.read(MAX_MANIFEST_BYTES + 1)
        if len(body) > MAX_MANIFEST_BYTES:
            raise UpdateError("manifest too large")
        m = json.loads(body.decode("utf-8"))
        if not isinstance(m, dict) or m.get("schema") != MANIFEST_SCHEMA:
            raise UpdateError("manifest schema is not %s" % MANIFEST_SCHEMA)
        if not VERSION_RE.match(str(m.get("version") or "")):
            raise UpdateError("manifest has no valid version")
        files = m.get("files") or {}
        if not isinstance(files, dict):
            raise UpdateError("manifest files must be an object")
        # The signature covers the manifest; the manifest pins every other file. Any file present but
        # not pinned, or pinned but different, means the zip was altered after it was signed.
        present = set()
        for root, _dirs, names in os.walk(work):
            for name in names:
                rel = os.path.relpath(os.path.join(root, name), work).replace(os.sep, "/")
                if rel not in (MANIFEST_NAME, SIGNATURE_NAME):
                    present.add(rel)
        unpinned = sorted(present - set(files))
        if unpinned:
            raise UpdateError("bundle carries files the signed manifest does not pin: %s" % ", ".join(unpinned[:5]))
        for rel, want in files.items():
            path = os.path.join(work, rel)
            if not SHA_RE.match(str(want)) or not os.path.isfile(path):
                raise UpdateError("manifest pins a missing or invalid file: %s" % rel)
            if sha256_file(path) != want:
                raise UpdateError("checksum mismatch for %s" % rel)
        k3s = m.get("k3s")
        if k3s is not None:
            if not isinstance(k3s, dict) or not K3S_VERSION_RE.match(str(k3s.get("version") or "")):
                raise UpdateError("manifest k3s.version must look like v1.36.4+k3s1")
            for key in ("binary", "installScript"):
                if str(k3s.get(key) or "") not in files:
                    raise UpdateError("manifest k3s.%s must name a pinned file in the bundle" % key)
            if k3s.get("airgapImages") and str(k3s["airgapImages"]) not in files:
                raise UpdateError("manifest k3s.airgapImages must name a pinned file in the bundle")
        apt = m.get("apt") or {}
        if not isinstance(apt, dict):
            raise UpdateError("manifest apt must be an object")
        for name, ver in (apt.get("packages") or {}).items():
            if not APT_NAME_RE.match(str(name)) or not APT_VERSION_RE.match(str(ver)):
                raise UpdateError("manifest names an invalid apt package pin: %s" % tail(str(name), 60))
        for hf in m.get("hostFiles") or []:
            dest = str(hf.get("destination") or "")
            if (not dest.startswith("/") or ".." in dest.split("/")
                    or not any(dest.startswith(p) for p in HOST_FILE_PREFIXES)):
                raise UpdateError("host file destination is outside CloudGrange's own files: %s" % dest)
            if str(hf.get("source") or "") not in files:
                raise UpdateError("host file source must be a pinned file in the bundle: %s" % dest)
            if not re.match(r"^0?[0-7]{3}$", str(hf.get("mode") or "0644")):
                raise UpdateError("host file mode is invalid for %s" % dest)
        return m

    # -- gates --
    def compatibility_gate(self, req, manifest):
        k3s = manifest.get("k3s")
        target = (k3s or {}).get("version") or self.k3s_version()
        kube_range = str(req.get("supportedKubeRange") or "").strip()
        if kube_range and target and not version_satisfies(target, kube_range):
            raise UpdateError("Foundation %s would run Kubernetes %s, outside the installed Platform's supported range %s"
                              % (manifest["version"], target, kube_range))
        platform_range = str(manifest.get("supportedPlatformVersions") or "").strip()
        platform_version = str(req.get("platformVersion") or "").strip()
        if platform_range and platform_version and not version_satisfies(platform_version, platform_range):
            raise UpdateError("Foundation %s supports Platform %s; the installed Platform is %s"
                              % (manifest["version"], platform_range, platform_version))

    def planned_packages(self, manifest):
        apt = manifest.get("apt") or {}
        pins = dict(apt.get("packages") or {})
        security = []
        if apt.get("securityUpdates"):
            self.apt_refresh()
            security = [(name, ver) for name, ver, sec in self.apt_upgradable() if sec and name not in pins]
        return pins, security

    def reboot_needed(self, manifest, pins, security):
        if manifest.get("requiresReboot") or self.reboot_required():
            return True
        names = list(pins) + [name for name, _ in security]
        return any(REBOOT_PACKAGE_RE.match(n) for n in names)

    def check_free_space(self):
        st = os.statvfs(self.state_dir)
        free = st.f_bavail * st.f_frsize
        if free < self.headroom:
            raise UpdateError("not enough free disk space for a Foundation update: %d MB free, %d MB required"
                              % (free // 1024 ** 2, self.headroom // 1024 ** 2))

    # -- k3s --
    def install_k3s(self, binary, install_script, version, airgap_images=None):
        """K3s's own documented in-place upgrade: put the pinned binary in place, rerun its installer."""
        if airgap_images:
            os.makedirs(self.k3s_images_dir, 0o755, exist_ok=True)
            shutil.copyfile(airgap_images, os.path.join(self.k3s_images_dir, os.path.basename(airgap_images)))
        tmp = self.k3s_bin + ".cloudgrange-new"
        shutil.copyfile(binary, tmp)
        os.chmod(tmp, 0o755)
        os.replace(tmp, self.k3s_bin)
        self.run(["sh", install_script], timeout=1800,
                 extra_env={"INSTALL_K3S_SKIP_DOWNLOAD": "true", "INSTALL_K3S_VERSION": version})

    def wait_healthy(self):
        """Every node Ready and every pod Running or Completed, as K3s itself reports it."""
        deadline = time.time() + self.health_timeout
        last = "the cluster did not answer"
        while time.time() < deadline:
            nodes = self.run(["k3s", "kubectl", "get", "nodes", "--no-headers"], timeout=60, check=False)
            node_lines = [l for l in (nodes.stdout or b"").decode("utf-8", "replace").splitlines() if l.strip()]
            not_ready = [l.split()[0] for l in node_lines if len(l.split()) < 2 or l.split()[1] != "Ready"]
            pods = self.run(["k3s", "kubectl", "get", "pods", "-A", "--no-headers"], timeout=60, check=False)
            bad = []
            for line in (pods.stdout or b"").decode("utf-8", "replace").splitlines():
                parts = line.split()
                if len(parts) < 4:
                    continue
                ready, phase = parts[2], parts[3]
                if phase == "Completed":
                    continue
                done, _, want = ready.partition("/")
                if phase != "Running" or done != want:
                    bad.append("%s/%s=%s" % (parts[0], parts[1], phase))
            if node_lines and not not_ready and pods.returncode == 0 and not bad:
                return
            last = ", ".join(["node %s not Ready" % n for n in not_ready] + bad[:8]) or last
            time.sleep(self.health_interval)
        raise UpdateError("the cluster did not become healthy within %ds: %s" % (self.health_timeout, last))

    # -- host files --
    def install_host_files(self, work, manifest, rollback_dir):
        saved, reload_units, replaced_self = [], False, False
        os.makedirs(os.path.join(rollback_dir, "hostfiles"), 0o700, exist_ok=True)
        for index, hf in enumerate(manifest.get("hostFiles") or []):
            dest = str(hf["destination"])
            target = self.host_path(dest)
            backup = None
            if os.path.lexists(target):
                backup = os.path.join(rollback_dir, "hostfiles", "%03d" % index)
                shutil.copy2(target, backup, follow_symlinks=False)
            saved.append({"destination": dest, "backup": backup})
            os.makedirs(os.path.dirname(target), 0o755, exist_ok=True)
            tmp = target + ".cloudgrange-new"
            shutil.copyfile(os.path.join(work, hf["source"]), tmp)
            os.chmod(tmp, int(str(hf.get("mode") or "0644"), 8))
            os.replace(tmp, target)
            reload_units = reload_units or dest.startswith("/etc/systemd/system/")
            replaced_self = replaced_self or dest == SELF_PATH
        return saved, reload_units, replaced_self

    def restore_host_files(self, saved):
        reload_units = False
        for entry in reversed(saved or []):
            target = self.host_path(entry["destination"])
            if entry.get("backup") and os.path.exists(entry["backup"]):
                shutil.copy2(entry["backup"], target)
            else:
                try:
                    os.unlink(target)
                except OSError:
                    pass
            reload_units = reload_units or entry["destination"].startswith("/etc/systemd/system/")
        if reload_units:
            self.run(["systemctl", "daemon-reload"], timeout=120, check=False)

    def write_installed_version(self, version):
        os.makedirs(os.path.dirname(self.version_file), 0o755, exist_ok=True)
        tmp = self.version_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(version + "\n")
        os.replace(tmp, self.version_file)

    def do_apply(self, req, job):
        version = str(req.get("version") or "")
        if version and not VERSION_RE.match(version):
            raise UpdateError("invalid Foundation version in request")
        job["step"] = "preflight"
        self.check_free_space()
        job["step"] = "staging"
        self.set_message("running", "Staging Foundation release %s" % (version or "(uploaded)"))
        staged = self.stage_upload(req) if req.get("bundleId") else self.stage_download(version)
        work = None
        try:
            job["step"] = "verifying"
            work = self.extract(staged)
            self.verify_signature(work)
            manifest = self.load_manifest(work)
            if version and manifest["version"] != version:
                raise UpdateError("the release is %s, not the requested %s" % (manifest["version"], version))
            job["targetVersion"] = manifest["version"]
            k3s = manifest.get("k3s")
            self.facts()["targetK3sVersion"] = (k3s or {}).get("version")
            self.compatibility_gate(req, manifest)

            pins, security = self.planned_packages(manifest)
            needs_reboot = self.reboot_needed(manifest, pins, security)
            if needs_reboot and req.get("confirmReboot") is not True:
                raise UpdateError("Foundation %s needs the host to reboot; nothing was changed. Confirm the reboot "
                                  "and start the update again." % manifest["version"])

            # Rollback point: the running K3s binary and version, and every host file about to change.
            job["step"] = "backing-up"
            rollback_dir = os.path.join(self.state_dir, "rollback-" + job["id"])
            os.makedirs(rollback_dir, 0o700, exist_ok=True)
            previous_k3s = self.k3s_version()
            point = {"jobId": job["id"], "foundationVersion": self.installed_version(), "k3sVersion": previous_k3s,
                     "k3sBinary": None, "installScript": None, "hostFiles": [], "dir": rollback_dir}
            changing_k3s = bool(k3s) and k3s["version"] != previous_k3s
            if changing_k3s and os.path.isfile(self.k3s_bin):
                point["k3sBinary"] = os.path.join(rollback_dir, "k3s")
                shutil.copy2(self.k3s_bin, point["k3sBinary"])
                point["installScript"] = os.path.join(rollback_dir, "install.sh")
                shutil.copyfile(os.path.join(work, k3s["installScript"]), point["installScript"])

            applied = []
            job["step"] = "os-packages"
            if pins or security:
                self.set_message("running", "Installing %d OS package update(s)" % (len(pins) + len(security)))
                args = ["apt-get", "install", "-y", "-q", "--only-upgrade",
                        "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"]
                args += ["%s=%s" % (n, v) for n, v in sorted(pins.items())]
                args += [n for n, _ in security]
                if pins:
                    self.apt_refresh()
                self.run(args, timeout=3600)
                applied.append("%d OS package(s)" % (len(pins) + len(security)))

            if changing_k3s:
                job["step"] = "k3s"
                self.set_message("running", "Upgrading K3s %s -> %s" % (previous_k3s, k3s["version"]))
                airgap = os.path.join(work, k3s["airgapImages"]) if k3s.get("airgapImages") else None
                try:
                    self.install_k3s(os.path.join(work, k3s["binary"]), os.path.join(work, k3s["installScript"]),
                                     k3s["version"], airgap)
                    job["step"] = "health-check"
                    self.wait_healthy()
                except (UpdateError, OSError, subprocess.SubprocessError) as err:
                    if not point["k3sBinary"]:
                        raise
                    job["step"] = "rolling-back"
                    detail = "K3s %s failed: %s" % (k3s["version"], err)
                    try:
                        self.install_k3s(point["k3sBinary"], point["installScript"], previous_k3s)
                        self.wait_healthy()
                    except (UpdateError, OSError, subprocess.SubprocessError) as rb:
                        raise UpdateError(detail + " (K3S ROLLBACK ALSO FAILED: %s)" % rb)
                    raise RolledBack(detail + "; K3s was put back to %s. OS packages already installed stay "
                                     "installed (apt cannot be rolled back)." % previous_k3s)
                applied.append("K3s %s" % k3s["version"])

            if manifest.get("hostFiles"):
                job["step"] = "host-files"
                saved, reload_units, replaced_self = self.install_host_files(work, manifest, rollback_dir)
                point["hostFiles"] = saved
                if reload_units:
                    self.run(["systemctl", "daemon-reload"], timeout=120, check=False)
                job["restartSelf"] = replaced_self
                applied.append("%d host file(s)" % len(saved))

            self.state["rollback"] = point
            self.write_installed_version(manifest["version"])
            self.facts()["availableVersion"] = self.facts().get("availableVersion") or manifest["version"]
            message = "Foundation %s applied: %s" % (manifest["version"], ", ".join(applied) or "nothing to change")
            if (needs_reboot or self.reboot_required()) and req.get("confirmReboot") is True:
                job["reboot"] = True
                message += "; the host reboots in %d seconds as confirmed" % self.reboot_delay
            elif self.reboot_required():
                # Only reachable when the prediction above missed a package: never reboot unconfirmed.
                message += "; the host now needs a reboot, which was NOT confirmed; reboot it from the console"
            return "succeeded", message
        finally:
            if work:
                shutil.rmtree(work, ignore_errors=True)
            try:
                os.unlink(staged)
            except OSError:
                pass

    def do_rollback(self, req, job):
        point = self.state.get("rollback")
        if not point:
            raise UpdateError("there is no previous Foundation to roll back to")
        current = self.k3s_version()
        notes = []
        if point.get("k3sBinary") and point.get("k3sVersion") and current and point["k3sVersion"] != current:
            prev, cur = parse_version(point["k3sVersion"]), parse_version(current)
            if prev[:2] != cur[:2]:
                raise UpdateError("K3s cannot be rolled back from %s to %s: Kubernetes does not support downgrading "
                                  "across minor versions (the datastore has already been migrated). Nothing was changed."
                                  % (current, point["k3sVersion"]))
            job["step"] = "k3s"
            self.set_message("running", "Rolling K3s back %s -> %s" % (current, point["k3sVersion"]))
            self.install_k3s(point["k3sBinary"], point["installScript"], point["k3sVersion"])
            job["step"] = "health-check"
            self.wait_healthy()
            notes.append("K3s back to %s" % point["k3sVersion"])
        if point.get("hostFiles"):
            job["step"] = "host-files"
            self.restore_host_files(point["hostFiles"])
            notes.append("%d host file(s) restored" % len(point["hostFiles"]))
        if point.get("foundationVersion"):
            self.write_installed_version(point["foundationVersion"])
        self.state["rollback"] = None
        shutil.rmtree(point.get("dir") or "", ignore_errors=True)
        return "rolled-back", ("Foundation rolled back to %s: %s. OS packages are NOT rolled back — apt has no "
                               "transactional downgrade, so package updates stay installed."
                               % (point.get("foundationVersion") or "the previous release", ", ".join(notes) or "nothing to restore"))

    # ---- job loop -------------------------------------------------------------------------------
    def _new_job(self, job_id, action, requested_by):
        return {"id": job_id, "action": action, "state": "running", "step": "queued", "startedAt": now(),
                "finishedAt": None, "message": None, "targetVersion": None,
                "previousVersion": self.installed_version(), "requestedBy": requested_by}

    def _finish(self, job, state, message):
        job.update(state=state, message=message, finishedAt=now())
        history = self.state.setdefault("history", [])
        if not history or history[0].get("id") != job["id"]:
            history.insert(0, job)
        del history[KEEP_HISTORY:]
        self.state["job"] = job
        self.set_message(state, message)

    def handle(self, req):
        action = str(req.get("action") or req.get("type") or "")
        job = self._new_job(req["id"], action[:40], str(req.get("requestedBy") or "")[:200])
        busy = self.state.get("job")
        if busy and busy.get("state") == "running":
            self._finish(job, "failed", "another Foundation job is running")
            return
        if action in LEGACY_PLATFORM_ACTIONS:
            # Keep the Foundation status the portal is showing; only record the refusal.
            job.update(state="failed", finishedAt=now(),
                       message="Platform updates are applied in-cluster (Platform -> Updates -> Platform); this host "
                               "service handles Foundation updates only. Nothing was changed.")
            self.state.setdefault("history", []).insert(0, job)
            del self.state["history"][KEEP_HISTORY:]
            self.save()
            return
        self.state["job"] = job
        self.state.setdefault("history", []).insert(0, job)
        del self.state["history"][KEEP_HISTORY:]
        self.set_message("running", "Foundation %s started" % action)
        try:
            if action == "foundation-check":
                state, message = self.do_check(req, job)
            elif action == "foundation-apply":
                state, message = self.do_apply(req, job)
            elif action == "foundation-rollback":
                state, message = self.do_rollback(req, job)
            else:
                raise UpdateError("unknown request type: %s" % tail(action, 40))
        except RolledBack as rb:
            state, message = "rolled-back", tail(str(rb), 600)
        except (UpdateError, subprocess.SubprocessError, OSError, ValueError, zipfile.BadZipFile) as err:
            state, message = "failed", tail(str(err), 600)
        self._finish(job, state, message)
        if job.get("reboot"):
            self.run(["systemd-run", "--on-active=%d" % self.reboot_delay, "systemctl", "reboot"], timeout=60, check=False)
        elif job.get("restartSelf"):
            self.run(["systemd-run", "--on-active=5", "systemctl", "restart", "cloudgrange-updater-k3s.service"],
                     timeout=60, check=False)

    def recover(self):
        """A job left 'running' by a crash or power loss is reported, never silently resumed."""
        job = self.state.get("job")
        if job and job.get("state") == "running":
            self._finish(job, "failed", "the Foundation updater stopped while this job was running (step %s); "
                                        "check the host before retrying" % job.get("step"))

    def process_once(self):
        for req in self.take_requests():
            self.handle(req)
        self.write_status()

    def serve(self):
        self.recover()
        self.write_status()
        while True:
            try:
                self.process_once()
            except Exception as err:  # never let one bad request kill the service
                sys.stderr.write("foundation updater loop error: %s\n" % err)
            time.sleep(self.poll)


class RolledBack(Exception):
    pass


def main(argv):
    os.umask(0o022)
    updater = FoundationUpdater()
    if "--once" in argv:
        updater.recover()
        updater.process_once()
        return 0
    updater.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
