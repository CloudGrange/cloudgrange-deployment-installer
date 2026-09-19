#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — end-to-end test of the in-cluster Platform updater on a throwaway kind cluster that
# CloudGrange did not provision (the bring-your-own-Kubernetes path, chart defaults).
#
# Update trust is HTTPS + digest pinning, with NO signing key (owner decision 2026-09-18). The
# releases are served by a real https server inside the cluster (nginx, its own CA handed to the
# chart as platformUpdater.trust.caBundle), and the chart's api.updateChannel points at it:
#   1. install the chart at FROM with chart defaults, NO signing key, the locally built updater;
#   2. apply TO — an UNSIGNED manifest whose SHA-256 matches the channel's manifestSha256, chart
#      pinned by SHA-256, images by digest — under <release>-platform-updater: expect
#      state=succeeded and TO running pinned by digest;
#   3. rollback — expect state=rolled-back, FROM running, the database restored, the API back up;
#   4. refusals, each with nothing changed (no new helm revision):
#      a. a manifest altered after the channel pinned it (SHA-256 mismatch);
#      b. a channel whose manifestUrl is http://;
#      c. a manifest with an image not pinned by digest;
#   5. apply TO with an image digest that does not exist — expect the health gate to fail, an
#      automatic helm rollback and DB restore, state=rolled-back, FROM running and healthy.
#
# Needs (run in WSL as root): docker, kind, kubectl, helm, openssl, python3; the api/portal/relay
# images for FROM and TO and nginx:1.27-alpine in the local docker image store; nothing is pushed.
# Creates and deletes ONLY the kind cluster named $CLUSTER. Leaves it up for inspection unless KEEP=0.
# Usage: test/e2e/platform-updater-kind.sh [FROM] [TO]
set -uo pipefail
FROM=${1:-2609.0.0-rc.90}
TO=${2:-2609.0.0-rc.91}
UPDATER_TAG=${UPDATER_TAG:-2609.0.0-trust-local}
CLUSTER=${CLUSTER:-cg-e1-updater}
NS=cloudgrange
REL=cg
KEEP=${KEEP:-1}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d /tmp/cg-updater-e2e.XXXX)
REG=ghcr.io/cloudgrange
NGINX_IMAGE=${NGINX_IMAGE:-nginx:1.27-alpine}
RNS=cg-e2e-release
RHOST=cg-release.$RNS.svc
BASE=https://$RHOST
PASS=0 FAIL=0
log() { echo "[e2e $(date -u +%H:%M:%S)] $*"; }
ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
status_of() { kubectl -n $NS get configmap cloudgrange-platform-update-status -o jsonpath="{.data.$1}" 2>/dev/null; }
api_image() { kubectl -n $NS get deploy $REL-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
psql_q() { kubectl -n $NS exec $REL-postgres-0 -- psql -U cloudgrange -d cloudgrange -qAt -c "$1"; }
revisions() { helm -n $NS history $REL -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }

log "workdir $W"
# A private kubeconfig: never touch the default context other clusters on this host use.
export KUBECONFIG="$W/kubeconfig"
bash "$ROOT/images/platform-updater/build.sh" "$UPDATER_TAG" > "$W/updater-build.log" 2>&1 || { log "updater build failed ($W/updater-build.log)"; exit 1; }

log "cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
[ "$KEEP" = 1 ] || trap 'kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1' EXIT
kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 180s > "$W/kind.log" 2>&1 || { cat "$W/kind.log"; exit 1; }
kubectl version -o json | python3 -c 'import json,sys; print("server", json.load(sys.stdin)["serverVersion"]["gitVersion"])'
for v in "$FROM" "$TO"; do for c in api portal relay; do
    docker image inspect "$REG/cloudgrange-$c:$v" >/dev/null 2>&1 || { log "missing local image $REG/cloudgrange-$c:$v"; exit 1; }
    kind load docker-image --name "$CLUSTER" "$REG/cloudgrange-$c:$v" >/dev/null 2>&1
done; done
kind load docker-image --name "$CLUSTER" "$REG/cloudgrange-platform-updater:$UPDATER_TAG" >/dev/null
# Rebuilt as a single-platform local image: `kind load` of a multi-platform pull fails on missing digests.
echo "FROM $NGINX_IMAGE" | docker build -q -t cg-e2e-release-nginx:local - >/dev/null || { log "cannot build from $NGINX_IMAGE"; exit 1; }
kind load docker-image --name "$CLUSTER" cg-e2e-release-nginx:local >/dev/null || { log "cannot load the release server image"; exit 1; }
# `kind load` imports by tag only. containerd resolves a repo:tag@sha256 reference only against an
# image NAMED repo@sha256 (the same reason the air-gap bundle adds those names,
# scripts/release/Add-DigestImageNames.py), so name the TO images by their node digest.
for c in api portal relay; do
    d=$(docker exec "$CLUSTER-control-plane" ctr -n k8s.io images ls 2>/dev/null | awk -v n="$REG/cloudgrange-$c:$TO" '$1 == n {print $3}')
    [ -n "$d" ] && docker exec "$CLUSTER-control-plane" ctr -n k8s.io images tag "$REG/cloudgrange-$c:$TO" "$REG/cloudgrange-$c@$d" >/dev/null 2>&1
done

log "release server: https://$RHOST (own CA), plus plain http on :80 so an http refusal is policy, not a dead port"
mkdir -p "$W/tls" "$W/site"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=cg-e2e-release-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$W/tls/ca.key" -out "$W/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=$RHOST" -keyout "$W/tls/tls.key" -out "$W/tls/tls.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s,DNS:%s.cluster.local\nextendedKeyUsage=serverAuth\n' "$RHOST" "$RHOST" > "$W/tls/ext"
openssl x509 -req -in "$W/tls/tls.csr" -CA "$W/tls/ca.crt" -CAkey "$W/tls/ca.key" -CAcreateserial -days 2 \
    -extfile "$W/tls/ext" -out "$W/tls/tls.crt" >/dev/null 2>&1
kubectl create namespace $RNS >/dev/null
kubectl -n $RNS create secret tls release-tls --cert "$W/tls/tls.crt" --key "$W/tls/tls.key" >/dev/null
cat > "$W/default.conf" <<'EOF'
server {
    listen 443 ssl;
    listen 80;
    ssl_certificate /tls/tls.crt;
    ssl_certificate_key /tls/tls.key;
    root /usr/share/nginx/html;
}
EOF
kubectl -n $RNS create configmap release-nginx --from-file=default.conf="$W/default.conf" >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: cg-release, namespace: $RNS, labels: { app: cg-release } }
spec:
  containers:
    - name: nginx
      image: cg-e2e-release-nginx:local
      imagePullPolicy: IfNotPresent
      ports: [ { containerPort: 443 }, { containerPort: 80 } ]
      volumeMounts:
        - { name: tls, mountPath: /tls }
        - { name: conf, mountPath: /etc/nginx/conf.d }
  volumes:
    - { name: tls, secret: { secretName: release-tls } }
    - { name: conf, configMap: { name: release-nginx } }
---
apiVersion: v1
kind: Service
metadata: { name: cg-release, namespace: $RNS }
spec:
  selector: { app: cg-release }
  ports: [ { name: https, port: 443 }, { name: http, port: 80 } ]
EOF
kubectl -n $RNS wait --for=condition=Ready pod/cg-release --timeout=180s >/dev/null || { log "release server did not start"; exit 1; }

log "charts"
for v in "$FROM" "$TO"; do
    cp -r "$ROOT/charts/cloudgrange" "$W/chart-$v"; rm -f "$W/chart-$v/Chart.lock"
    bash "$ROOT/scripts/release/Set-ChartVersion.sh" "$W/chart-$v" "$v" >/dev/null
done
helm package "$W/chart-$TO" -d "$W/rel" >/dev/null

# The digest the kind node knows each TO image by (what `kind load` imported).
node=$CLUSTER-control-plane
digest_of() { # <image ref> -> sha256:… as the node's containerd sees it, else the registry digest
    local d
    d=$(docker exec "$node" crictl inspecti -o json "$1" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["status"]["repoDigests"]; print(d[0].split("@")[1] if d else "")' 2>/dev/null)
    [ -n "$d" ] || d=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" | head -1 | cut -d@ -f2)
    echo "$d"
}
# make_release <case> [api digest override] [mode]: an UNSIGNED release under $BASE/<case>/ —
# chart, manifest.json and a channel.json whose latest.manifestSha256 pins the manifest.
# mode: tamper (manifest changed after the channel pinned it) | http (manifestUrl is http://) |
#       unpinned (api image without a digest)
make_release() {
    local c=$1 override=${2:-} mode=${3:-} out="$W/site/$1"
    mkdir -p "$out"; cp "$W/rel/cloudgrange-$TO.tgz" "$out/"
    python3 - "$out" "$TO" "$(sha256sum "$out/cloudgrange-$TO.tgz" | cut -d' ' -f1)" "$REG" "$override" "$mode" "$BASE/$c" \
        "$(digest_of $REG/cloudgrange-api:$TO)" "$(digest_of $REG/cloudgrange-portal:$TO)" "$(digest_of $REG/cloudgrange-relay:$TO)" <<'PY'
import hashlib, json, sys
out, v, sha, reg, override, mode, base, api, portal, relay = sys.argv[1:11]
comps = {}
for name, d in (("api", override or api), ("portal", portal), ("relay", relay)):
    assert d.startswith("sha256:"), f"no digest for {name}"
    image = f"{reg}/cloudgrange-{name}:{v}@{d}"
    if mode == "unpinned" and name == "api":
        image = f"{reg}/cloudgrange-{name}:{v}"
    comps[f"cloudgrange-{name}"] = {"version": v, "image": image, "digest": d}
manifest = json.dumps({"schema": "cg-release-manifest-v1", "platform": v, "channel": "rc", "released": "2026-09-18",
                       "upgradeFrom": ">=2609.0.0-0", "kubeVersion": "",
                       "chart": {"url": f"{base}/cloudgrange-{v}.tgz", "sha256": sha}, "components": comps}, indent=2)
open(f"{out}/manifest.json", "w").write(manifest)
manifest_sha = hashlib.sha256(manifest.encode()).hexdigest()
if mode == "tamper":
    open(f"{out}/manifest.json", "w").write(manifest.replace('"channel": "rc"', '"channel": "stable"'))
manifest_url = f"{base}/manifest.json"
if mode == "http":
    manifest_url = manifest_url.replace("https://", "http://", 1)
json.dump({"schema": "cg-onprem-channel-v1", "updatedAt": "2026-09-18T00:00:00Z",
           "latest": {"version": v, "bundleUrl": f"{base}/bundle.zip", "sha256": "0" * 64, "severity": "recommended",
                      "summary": "e2e", "manifestUrl": manifest_url, "manifestSha256": manifest_sha}},
          open(f"{out}/channel.json", "w"), indent=2)
PY
}
publish_site() { kubectl -n $RNS cp "$W/site/." cg-release:/usr/share/nginx/html/ >/dev/null; }

run_job() { # <name> <channel URL override or ""> <timeout> <args...>
    local name=$1 channel=$2 health=$3; shift 3
    local args; args=$(printf '"%s",' "$@"); args="[${args%,}]"
    local chenv=''
    [ -n "$channel" ] && chenv="- { name: CLOUDGRANGE_UPDATE_CHANNEL_URL, value: \"$channel\" }"
    kubectl -n $NS delete job "$name" --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $name, namespace: $NS }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: $REL-platform-updater
      securityContext: { runAsNonRoot: true, runAsUser: 10001, fsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: platform-updater
          image: $REG/cloudgrange-platform-updater:$UPDATER_TAG
          imagePullPolicy: IfNotPresent
          args: $args
          env:
            - { name: CLOUDGRANGE_RELEASE_NAME, value: "$REL" }
            - { name: CLOUDGRANGE_NAMESPACE, value: "$NS" }
            - { name: CLOUDGRANGE_HEALTH_TIMEOUT, value: "$health" }
            $chenv
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
          volumeMounts:
            - { name: backups, mountPath: /backups }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: backups, persistentVolumeClaim: { claimName: $REL-platform-updater-backups } }
        - { name: tmp, emptyDir: {} }
EOF
    local i s f
    for i in $(seq 1 540); do
        s=$(kubectl -n $NS get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null)
        f=$(kubectl -n $NS get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null)
        [ "${s:-0}" -ge 1 ] || [ "${f:-0}" -ge 1 ] && break
        sleep 5
    done
    kubectl -n $NS logs "job/$name" > "$W/$name.log" 2>&1
    log "job $name -> state=$(status_of state) message=$(status_of message)"
}

log "install $FROM with chart defaults (BYO), NO signing key, in a Pod Security restricted namespace"
kubectl create namespace $NS >/dev/null
# The chart must run under Pod Security "restricted" with its defaults.
kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null
helm install $REL "$W/chart-$FROM" -n $NS \
    --set api.updateChannel.url="$BASE/good/channel.json" \
    --set-file platformUpdater.trust.caBundle="$W/tls/ca.crt" \
    --set platformUpdater.image.tag="$UPDATER_TAG" --wait --timeout 25m > "$W/install.log" 2>&1 \
    || { log "install did not become ready"; kubectl -n $NS get pods; tail -5 "$W/install.log"; }
kubectl -n $NS get pods -o wide
if helm test $REL -n $NS --timeout 5m > "$W/helm-test.log" 2>&1; then ok "helm test passed on the fresh install"; else bad "helm test failed ($W/helm-test.log)"; fi
kubectl -n $NS get events --field-selector reason=FailedCreate -o custom-columns=MSG:.message --no-headers 2>/dev/null | grep -i "violates PodSecurity" | sort -u | sed 's/^/  PSA: /'
kubectl get clusterrole -o name | grep -c "$REL-" | xargs -I{} log "cluster-scoped ClusterRoles owned by the release: {}"
[ "$(status_of state)" = idle ] && ok "status ConfigMap created idle at install" || bad "status ConfigMap not idle: $(status_of state)"
kubectl -n $NS get configmap $REL-platform-updater-signing >/dev/null 2>&1 && bad "a signing ConfigMap exists; this test must run without a key" || ok "no signing key configured"
[ "$(kubectl -n $NS get configmap $REL-platform-updater-trust -o jsonpath='{.data.channelUrl}')" = "$BASE/good/channel.json" ] \
    && ok "trust ConfigMap carries the channel URL" || bad "trust ConfigMap channelUrl: $(kubectl -n $NS get configmap $REL-platform-updater-trust -o jsonpath='{.data.channelUrl}')"
psql_q "CREATE TABLE IF NOT EXISTS e2e_marker(v text); DELETE FROM e2e_marker; INSERT INTO e2e_marker VALUES ('before-$FROM');" \
    && ok "marker row written" || bad "could not write marker row"

make_release good
make_release tampered "" tamper
make_release http "" http
make_release unpinned "" unpinned
make_release broken "sha256:$(printf 'e%.0s' $(seq 64))"
publish_site

log "=== 2. apply $TO (unsigned, SHA-256 pinned by the channel from the chart's trust ConfigMap)"
run_job e2e-apply "" 10m apply --version "$TO" --manifest-url "$BASE/good/manifest.json"
[ "$(status_of state)" = succeeded ] && ok "unsigned apply succeeded without a signing key" || bad "apply state $(status_of state); see $W/e2e-apply.log"
grep -q "no release signing key configured" "$W/e2e-apply.log" && ok "updater used HTTPS + digest pinning (no key)" || bad "updater log does not show the no-key trust path"
[[ "$(api_image)" == *":$TO@sha256:"* ]] && ok "api runs $TO pinned by digest ($(api_image))" || bad "api image after apply: $(api_image)"
psql_q "UPDATE e2e_marker SET v='after-$TO';" >/dev/null

log "=== 3. rollback"
run_job e2e-rollback "" 10m rollback
[ "$(status_of state)" = rolled-back ] && ok "rollback state rolled-back" || bad "rollback state $(status_of state); see $W/e2e-rollback.log"
[[ "$(api_image)" == *":$FROM"* ]] && ok "api back on $FROM" || bad "api image after rollback: $(api_image)"
[ "$(psql_q 'SELECT v FROM e2e_marker')" = "before-$FROM" ] && ok "database restored to the pre-update backup" || bad "marker after rollback: $(psql_q 'SELECT v FROM e2e_marker')"
[ "$(kubectl -n $NS get deploy $REL-api -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "api ready after rollback" || bad "api not ready after rollback"

refused() { # <case> <expected message fragment> <label>
    # --manifest-url is the channel document itself (the form an API without a manifest URL passes), so
    # the refusal comes from what the channel lists, not from a mismatch with a URL we made up.
    local before after
    before=$(revisions)
    run_job "e2e-$1" "$BASE/$1/channel.json" 10m apply --version "$TO" --manifest-url "$BASE/$1/channel.json"
    [ "$(status_of state)" = failed ] && [[ "$(status_of message)" == *"$2"* ]] && ok "$3 refused: $(status_of message)" || bad "$3: $(status_of state) $(status_of message)"
    after=$(revisions)
    [ "$before" = "$after" ] && ok "no helm revision created by the refused $3" || bad "helm revisions $before -> $after after $3"
    [[ "$(api_image)" == *":$FROM"* ]] || bad "api image changed by the refused $3: $(api_image)"
}
log "=== 4. refusals"
refused tampered "does not match the channel" "manifest altered after the channel pinned it"
refused http "over https://" "http:// manifest"
refused unpinned "not pinned by @sha256 digest" "unpinned image"

log "=== 5. apply with a nonexistent image digest (automatic rollback)"
psql_q "UPDATE e2e_marker SET v='before-broken';" >/dev/null
run_job e2e-broken "$BASE/broken/channel.json" 4m apply --version "$TO" --manifest-url "$BASE/broken/manifest.json"
[ "$(status_of state)" = rolled-back ] && ok "failed update rolled itself back" || bad "broken apply state $(status_of state); see $W/e2e-broken.log"
[[ "$(api_image)" == *":$FROM"* ]] && ok "api on $FROM after the automatic rollback" || bad "api image after automatic rollback: $(api_image)"
[ "$(psql_q 'SELECT v FROM e2e_marker')" = "before-broken" ] && ok "database intact after the automatic rollback" || bad "marker: $(psql_q 'SELECT v FROM e2e_marker')"
[ "$(kubectl -n $NS get deploy $REL-api -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "api ready after the automatic rollback" || bad "api not ready after automatic rollback"

helm -n $NS history $REL
log "RESULT: $PASS passed, $FAIL failed (logs in $W)"
[ "$KEEP" = 1 ] || kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
[ "$FAIL" = 0 ]
