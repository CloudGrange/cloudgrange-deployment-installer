#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — end-to-end test of the in-cluster Platform updater on a throwaway kind cluster that
# CloudGrange did not provision (the bring-your-own-Kubernetes path, chart defaults).
#
#   1. install the chart at FROM (e.g. 2609.0.0-preview.3) with chart defaults, a test cosign key
#      and the locally built updater image;
#   2. apply TO (signed manifest, chart pinned by SHA-256, images pinned by digest) with the
#      updater Job running under <release>-platform-updater — expect state=succeeded, TO running;
#   3. rollback — expect state=rolled-back, FROM running, the database restored, the API back up;
#   4. apply TO with a tampered manifest — expect a signature refusal and nothing changed;
#   5. apply TO with an image digest that does not exist — expect the health gate to fail, an
#      automatic helm rollback and DB restore, state=rolled-back, FROM running and healthy.
#
# Needs (run in WSL as root): docker, kind, kubectl, helm, python3; the api/portal/relay images for
# FROM and TO present in the local docker image store; nothing is pushed. Leaves the cluster up
# for inspection unless KEEP=0.
# Usage: test/e2e/platform-updater-kind.sh [FROM] [TO]
set -uo pipefail
FROM=${1:-2609.0.0-preview.4}
TO=${2:-2609.0.0-preview.5}
UPDATER_TAG=${UPDATER_TAG:-2609.0.0-local}
CLUSTER=${CLUSTER:-cg-e1-updater}
NS=cloudgrange
REL=cg
KEEP=${KEEP:-1}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d /tmp/cg-updater-e2e.XXXX)
REG=ghcr.io/cloudgrange
PASS=0 FAIL=0
log() { echo "[e2e $(date -u +%H:%M:%S)] $*"; }
ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
status_of() { kubectl -n $NS get configmap cloudgrange-platform-update-status -o jsonpath="{.data.$1}" 2>/dev/null; }
api_image() { kubectl -n $NS get deploy $REL-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
psql_q() { kubectl -n $NS exec $REL-postgres-0 -- psql -U cloudgrange -d cloudgrange -qAt -c "$1"; }

log "workdir $W"
[ "$(docker images -q ghcr.io/cloudgrange/cloudgrange-platform-updater:$UPDATER_TAG)" ] \
    || { bash "$ROOT/images/platform-updater/build.sh" "$UPDATER_TAG" > "$W/updater-build.log" 2>&1 || { log "updater build failed"; exit 1; }; }

log "cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
kind create cluster --name "$CLUSTER" --wait 180s > "$W/kind.log" 2>&1 || { cat "$W/kind.log"; exit 1; }
kubectl version -o json | python3 -c 'import json,sys; print("server", json.load(sys.stdin)["serverVersion"]["gitVersion"])'
for v in "$FROM" "$TO"; do for c in api portal relay; do
    docker image inspect "$REG/cloudgrange-$c:$v" >/dev/null 2>&1 || { log "missing local image $REG/cloudgrange-$c:$v"; exit 1; }
    kind load docker-image --name "$CLUSTER" "$REG/cloudgrange-$c:$v" >/dev/null 2>&1
done; done
kind load docker-image --name "$CLUSTER" "$REG/cloudgrange-platform-updater:$UPDATER_TAG" >/dev/null
# `kind load` imports by tag only. containerd resolves a repo:tag@sha256 reference only against an
# image NAMED repo@sha256 (the same reason the air-gap bundle adds those names,
# scripts/release/Add-DigestImageNames.py), so name the TO images by their node digest.
for c in api portal relay; do
    d=$(docker exec "$CLUSTER-control-plane" ctr -n k8s.io images ls 2>/dev/null | awk -v n="$REG/cloudgrange-$c:$TO" '$1 == n {print $3}')
    [ -n "$d" ] && docker exec "$CLUSTER-control-plane" ctr -n k8s.io images tag "$REG/cloudgrange-$c:$TO" "$REG/cloudgrange-$c@$d" >/dev/null 2>&1
done

log "charts and signing key"
for v in "$FROM" "$TO"; do
    cp -r "$ROOT/charts/cloudgrange" "$W/chart-$v"; rm -f "$W/chart-$v/Chart.lock"
    bash "$ROOT/scripts/release/Set-ChartVersion.sh" "$W/chart-$v" "$v" >/dev/null
done
helm package "$W/chart-$TO" -d "$W/rel" >/dev/null
mkdir -p "$W/keys"
docker run --rm -e COSIGN_PASSWORD= -v "$W/keys:/k" -w /k --user 0 --entrypoint cosign \
    "$REG/cloudgrange-platform-updater:$UPDATER_TAG" generate-key-pair >/dev/null 2>&1

# The digest the kind node knows each TO image by (what `kind load` imported).
node=$CLUSTER-control-plane
digest_of() { # <image ref> -> sha256:… as the node's containerd sees it, else the registry digest
    local d
    d=$(docker exec "$node" crictl inspecti -o json "$1" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["status"]["repoDigests"]; print(d[0].split("@")[1] if d else "")' 2>/dev/null)
    [ -n "$d" ] || d=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" | head -1 | cut -d@ -f2)
    echo "$d"
}
make_manifest() { # <out dir> <api digest override or "">
    local out=$1 override=$2
    mkdir -p "$out"; cp "$W/rel/cloudgrange-$TO.tgz" "$out/"
    python3 - "$out/manifest.json" "$TO" "$(sha256sum "$out/cloudgrange-$TO.tgz" | cut -d' ' -f1)" \
        "$REG" "$override" "$(digest_of $REG/cloudgrange-api:$TO)" "$(digest_of $REG/cloudgrange-portal:$TO)" \
        "$(digest_of $REG/cloudgrange-relay:$TO)" <<'PY'
import json, sys
out, v, sha, reg, override, api, portal, relay = sys.argv[1:9]
comps = {}
for name, d in (("api", override or api), ("portal", portal), ("relay", relay)):
    assert d.startswith("sha256:"), f"no digest for {name}"
    comps[f"cloudgrange-{name}"] = {"version": v, "image": f"{reg}/cloudgrange-{name}:{v}@{d}", "digest": d}
json.dump({"schema": "cg-release-manifest-v1", "platform": v, "channel": "preview", "released": "2026-09-18",
           "upgradeFrom": ">=2609.0.0-0", "kubeVersion": "", "chart": {"url": f"file:///release/cloudgrange-{v}.tgz", "sha256": sha},
           "components": comps}, open(out, "w"), indent=2)
PY
    docker run --rm -e COSIGN_PASSWORD= -v "$W/keys:/k" -v "$out:/o" --user 0 --entrypoint cosign \
        "$REG/cloudgrange-platform-updater:$UPDATER_TAG" sign-blob --yes --key /k/cosign.key \
        --new-bundle-format=false --use-signing-config=false --tlog-upload=false \
        --output-signature /o/manifest.json.sig /o/manifest.json >/dev/null 2>&1
}

run_job() { # <name> <release configmap or ""> <timeout> <args...>
    local name=$1 cm=$2 health=$3; shift 3
    local args; args=$(printf '"%s",' "$@"); args="[${args%,}]"
    local vol='' mnt=''
    [ -n "$cm" ] && { vol="- { name: release, configMap: { name: $cm } }"; mnt="- { name: release, mountPath: /release }"; }
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
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
          volumeMounts:
            - { name: backups, mountPath: /backups }
            - { name: tmp, mountPath: /tmp }
            $mnt
      volumes:
        - { name: backups, persistentVolumeClaim: { claimName: $REL-platform-updater-backups } }
        - { name: tmp, emptyDir: {} }
        $vol
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

log "install $FROM with chart defaults (BYO) in a Pod Security restricted namespace"
kubectl create namespace $NS >/dev/null
# The chart must run under Pod Security "restricted" with its defaults.
kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null
helm install $REL "$W/chart-$FROM" -n $NS \
    --set-file platformUpdater.signing.publicKey="$W/keys/cosign.pub" \
    --set platformUpdater.image.tag="$UPDATER_TAG" --wait --timeout 25m > "$W/install.log" 2>&1 \
    || { log "install did not become ready"; kubectl -n $NS get pods; tail -5 "$W/install.log"; }
kubectl -n $NS get pods -o wide
if helm test $REL -n $NS --timeout 5m > "$W/helm-test.log" 2>&1; then ok "helm test passed on the fresh install"; else bad "helm test failed ($W/helm-test.log)"; fi
kubectl -n $NS get events --field-selector reason=FailedCreate -o custom-columns=MSG:.message --no-headers 2>/dev/null | grep -i "violates PodSecurity" | sort -u | sed 's/^/  PSA: /'
kubectl get clusterrole -o name | grep -c "$REL-" | xargs -I{} log "cluster-scoped ClusterRoles owned by the release: {}"
[ "$(status_of state)" = idle ] && ok "status ConfigMap created idle at install" || bad "status ConfigMap not idle: $(status_of state)"
psql_q "CREATE TABLE IF NOT EXISTS e2e_marker(v text); DELETE FROM e2e_marker; INSERT INTO e2e_marker VALUES ('before-$FROM');" \
    && ok "marker row written" || bad "could not write marker row"

log "=== 2. apply $TO"
make_manifest "$W/good" ""
kubectl -n $NS create configmap e2e-release-good --from-file="$W/good" >/dev/null
run_job e2e-apply e2e-release-good 10m apply --version "$TO" --manifest-url file:///release/manifest.json
[ "$(status_of state)" = succeeded ] && ok "apply succeeded" || bad "apply state $(status_of state); see $W/e2e-apply.log"
[[ "$(api_image)" == *":$TO@sha256:"* ]] && ok "api runs $TO pinned by digest ($(api_image))" || bad "api image after apply: $(api_image)"
psql_q "UPDATE e2e_marker SET v='after-$TO';" >/dev/null

log "=== 3. rollback"
run_job e2e-rollback "" 10m rollback
[ "$(status_of state)" = rolled-back ] && ok "rollback state rolled-back" || bad "rollback state $(status_of state); see $W/e2e-rollback.log"
[[ "$(api_image)" == *":$FROM"* ]] && ok "api back on $FROM" || bad "api image after rollback: $(api_image)"
[ "$(psql_q 'SELECT v FROM e2e_marker')" = "before-$FROM" ] && ok "database restored to the pre-update backup" || bad "marker after rollback: $(psql_q 'SELECT v FROM e2e_marker')"
[ "$(kubectl -n $NS get deploy $REL-api -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "api ready after rollback" || bad "api not ready after rollback"

log "=== 4. tampered manifest"
make_manifest "$W/tampered" ""
sed -i 's/"channel": "preview"/"channel": "stable"/' "$W/tampered/manifest.json"
kubectl -n $NS create configmap e2e-release-tampered --from-file="$W/tampered" >/dev/null
before=$(helm -n $NS history $REL -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
run_job e2e-tampered e2e-release-tampered 10m apply --version "$TO" --manifest-url file:///release/manifest.json
[ "$(status_of state)" = failed ] && [[ "$(status_of message)" == *signature* ]] && ok "tampered manifest refused: $(status_of message)" || bad "tampered: $(status_of state) $(status_of message)"
after=$(helm -n $NS history $REL -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$before" = "$after" ] && ok "no helm revision created by the refused update" || bad "helm revisions $before -> $after"

log "=== 5. apply with a nonexistent image digest (automatic rollback)"
make_manifest "$W/broken" "sha256:$(printf 'e%.0s' $(seq 64))"
kubectl -n $NS create configmap e2e-release-broken --from-file="$W/broken" >/dev/null
psql_q "UPDATE e2e_marker SET v='before-broken';" >/dev/null
run_job e2e-broken e2e-release-broken 4m apply --version "$TO" --manifest-url file:///release/manifest.json
[ "$(status_of state)" = rolled-back ] && ok "failed update rolled itself back" || bad "broken apply state $(status_of state); see $W/e2e-broken.log"
[[ "$(api_image)" == *":$FROM"* ]] && ok "api on $FROM after the automatic rollback" || bad "api image after automatic rollback: $(api_image)"
[ "$(psql_q 'SELECT v FROM e2e_marker')" = "before-broken" ] && ok "database intact after the automatic rollback" || bad "marker: $(psql_q 'SELECT v FROM e2e_marker')"
[ "$(kubectl -n $NS get deploy $REL-api -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "api ready after the automatic rollback" || bad "api not ready after automatic rollback"

helm -n $NS history $REL
log "RESULT: $PASS passed, $FAIL failed (logs in $W)"
[ "$KEEP" = 1 ] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
[ "$FAIL" = 0 ]
