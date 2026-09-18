#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation B1/B2) — stamp a platform version into
# the chart. The chart is the platform, so it carries the platform version:
#   - umbrella Chart.yaml  version + appVersion  = <version>
#   - api/portal/relay     appVersion            = <version>
# The subcharts need it too: the first-party image tag falls back to .Chart.AppVersion, and inside
# a subchart template that is the SUBCHART's appVersion (templates/_helpers.tpl). The subcharts'
# own `version` stays their component version.
#
# Usage: Set-ChartVersion.sh <chart-dir> <YYMM.MINOR.PATCH[-preview.N|-rc.N]>
# Works on a release copy of the chart (New-ReleaseBundleK3s.sh) or on the repo tree before
# tagging a release commit. Idempotent.
set -euo pipefail
CHART=${1:?usage: Set-ChartVersion.sh <chart-dir> <version>}
VERSION=${2:?usage: Set-ChartVersion.sh <chart-dir> <version>}
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "version must be YYMM.MINOR.PATCH[-preview.N|-rc.N] (release-versioning.md), got: $VERSION" >&2; exit 2; }
[ -f "$CHART/Chart.yaml" ] || { echo "no Chart.yaml in $CHART" >&2; exit 2; }

set_field() { # <file> <field> <value>
    local file=$1 field=$2 value=$3
    grep -qE "^$field:" "$file" || { echo "$file has no top-level $field:" >&2; exit 1; }
    sed -i -E "s|^$field:.*$|$field: \"$value\"|" "$file"
    grep -qxF "$field: \"$value\"" "$file" || { echo "failed to stamp $field in $file" >&2; exit 1; }
}

set_field "$CHART/Chart.yaml" version "$VERSION"
set_field "$CHART/Chart.yaml" appVersion "$VERSION"
for sub in api portal relay; do
    set_field "$CHART/charts/$sub/Chart.yaml" appVersion "$VERSION"
done
echo "stamped platform version $VERSION into $CHART (umbrella version/appVersion, api/portal/relay appVersion)"
