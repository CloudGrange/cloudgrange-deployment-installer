#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Print the source VM's install-time secret values, base64-encoded, one "label=<b64>" per
# line, for Build-CloudGrangeAppliance.ps1's post-export VHDX secret scan. The build script keeps
# them in memory only and never prints or writes them. Run as root BEFORE cloudgrange-generalize.sh.
set -euo pipefail
cd /opt/cloudgrange
grep -E '^[A-Z_]*(PASSWORD|TOKEN|SECRET)=' .env | while IFS='=' read -r key value; do
    printf 'env:%s=%s\n' "$key" "$(printf '%s' "$value" | base64 -w0)"
done
HELPER_IMAGE=$(head -1 helper-images.txt)
for vol in api_secrets relay_identity; do
    docker volume inspect "cloudgrange_$vol" >/dev/null 2>&1 || continue
    docker run --rm --network none -v "cloudgrange_$vol:/v:ro" "$HELPER_IMAGE" sh -c \
        'find /v -type f -size -65k | while read -r f; do printf "'"$vol"':%s=%s\n" "${f#/v/}" "$(base64 -w0 < "$f")"; done'
done
docker run --rm --network none -v cloudgrange_nginx_certs:/c:ro "$HELPER_IMAGE" sh -c \
    'printf "tls:private-key-line2=%s\n" "$(sed -n 2p /c/cloudgrange.key | tr -d "\n" | base64 -w0)"'
