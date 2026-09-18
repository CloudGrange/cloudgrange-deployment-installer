# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation §3/§4, E1) — the in-cluster Platform
# updater image: ghcr.io/cloudgrange/cloudgrange-platform-updater:<platform version>.
#
# Every version is pinned in release/pins.conf and passed in as a build-arg by build.sh; there are
# deliberately NO defaults here, so a build that bypasses the pins file fails instead of silently
# picking up something unpinned. test/lint-pins.sh checks this file for unpinned FROM lines.
#
# Base: the same Postgres 17.11 the chart runs, by digest, so pg_dump/pg_restore/psql match the
# server's major version (a pg_dump older than the server refuses to dump it).
ARG PLATFORM_UPDATER_BASE_IMAGE
FROM ${PLATFORM_UPDATER_BASE_IMAGE}

ARG HELM_VERSION
ARG HELM_LINUX_AMD64_SHA256
ARG KUBECTL_VERSION
ARG KUBECTL_LINUX_AMD64_SHA256
ARG COSIGN_VERSION
ARG COSIGN_LINUX_AMD64_SHA256

# bash/jq/curl for the entrypoint; coreutils for `date -d`/`sort -V`. These come from the Alpine
# release the pinned base image ships; the base digest fixes which Alpine that is.
RUN apk add --no-cache bash curl jq coreutils ca-certificates

RUN set -eux; \
    for v in HELM_VERSION HELM_LINUX_AMD64_SHA256 KUBECTL_VERSION KUBECTL_LINUX_AMD64_SHA256 COSIGN_VERSION COSIGN_LINUX_AMD64_SHA256; do \
        eval "val=\${$v:-}"; [ -n "$val" ] || { echo "build-arg $v is required (use images/platform-updater/build.sh)" >&2; exit 1; }; \
    done; \
    cd /tmp; \
    curl -fsSLo helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"; \
    echo "${HELM_LINUX_AMD64_SHA256}  helm.tgz" | sha256sum -c -; \
    tar -xzf helm.tgz linux-amd64/helm; install -m 0755 linux-amd64/helm /usr/local/bin/helm; \
    curl -fsSLo kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    echo "${KUBECTL_LINUX_AMD64_SHA256}  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    curl -fsSLo cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"; \
    echo "${COSIGN_LINUX_AMD64_SHA256}  cosign" | sha256sum -c -; \
    install -m 0755 cosign /usr/local/bin/cosign; \
    rm -rf /tmp/*; \
    helm version --short; kubectl version --client; cosign version; pg_dump --version

COPY entrypoint.sh /usr/local/bin/cloudgrange-platform-updater
RUN chmod 0755 /usr/local/bin/cloudgrange-platform-updater \
    && adduser -D -H -u 10001 -s /sbin/nologin updater

# Non-root, writable scratch only under /tmp; /backups is the mounted backup PVC.
ENV HOME=/tmp/updater \
    HELM_CACHE_HOME=/tmp/updater/helm/cache \
    HELM_CONFIG_HOME=/tmp/updater/helm/config \
    HELM_DATA_HOME=/tmp/updater/helm/data \
    CLOUDGRANGE_BACKUP_DIR=/backups
USER 10001
ENTRYPOINT ["/usr/local/bin/cloudgrange-platform-updater"]
CMD ["--help"]
