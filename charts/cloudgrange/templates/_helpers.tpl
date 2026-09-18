{{- /*
AB#9171 (plan 2026-09-18-foundation-platform-separation B2) — first-party image references.

Defined in the umbrella chart and used by the api, portal and relay subcharts: Helm loads every
chart's named templates into one namespace, so a subchart can include these. They are evaluated
in the CALLER's context, which is why the tag falls back to the calling subchart's own
.Chart.AppVersion. The release tooling (scripts/release/Set-ChartVersion.sh) stamps the same
platform version into the umbrella and into the api, portal and relay Chart.yaml appVersion, so
the fallback is the release version on every path.

No image ever defaults to `latest`:
  - global.image.tag empty (the default)  -> the chart's appVersion, e.g. 2609.0.0
  - global.image.tag set                  -> that tag (wrappers and `helm upgrade --set`)
  - <subchart>.image.digest set           -> repo:tag@sha256:..., pinned by digest
*/ -}}

{{- define "cloudgrange.imageTag" -}}
{{- default .Chart.AppVersion .Values.global.image.tag -}}
{{- end -}}

{{- define "cloudgrange.firstPartyImage" -}}
{{- $ref := printf "%s/%s:%s" .Values.global.image.registry .Values.image.repository (include "cloudgrange.imageTag" .) -}}
{{- with .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .) -}}
{{- fail (printf "image.digest must be sha256:<64 hex>, got %q" .) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref . -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{- /* The name every in-cluster Platform-updater object shares (plan §4: "<fullname>-platform-updater").
This chart names every object "<release>-<component>" and has no separate fullname helper, so the
release name is the fullname. */ -}}
{{- define "cloudgrange.platformUpdaterName" -}}
{{- printf "%s-platform-updater" .Release.Name -}}
{{- end -}}

{{- define "cloudgrange.platformUpdaterImage" -}}
{{- $tag := default .Chart.AppVersion .Values.platformUpdater.image.tag -}}
{{- $ref := printf "%s:%s" .Values.platformUpdater.image.repository $tag -}}
{{- with .Values.platformUpdater.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .) -}}
{{- fail (printf "platformUpdater.image.digest must be sha256:<64 hex>, got %q" .) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref . -}}
{{- end -}}
{{- $ref -}}
{{- end -}}
