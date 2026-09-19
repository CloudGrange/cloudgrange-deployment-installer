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

{{/* The update channel URL (api.updateChannel), shared by the API (which offers the release) and
the platform updater (which pins the release manifest to the SHA-256 this channel lists).
Args: dict "ch" <updateChannel values> "tag" <image tag>. */}}
{{- define "cloudgrange.updateChannelUrl" -}}
{{- $ch := .ch -}}
{{- $name := $ch.name -}}
{{- if not $name -}}
{{- $name = ternary "preview" (ternary "rc" "stable" (contains "-rc." .tag)) (contains "-preview." .tag) -}}
{{- end -}}
{{- if not (has $name (list "preview" "rc" "stable")) }}{{ fail (printf "api.updateChannel.name must be preview, rc or stable, got %q" $name) }}{{ end -}}
{{- $ch.url | default (printf "%s/channels/%s.json" (trimSuffix "/" $ch.baseUrl) $name) -}}
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

{{- /* AB#9171 (C2 on kind v1.34, plan D1): every workload meets the Pod Security "restricted"
profile by default, so the chart installs into a namespace labelled
pod-security.kubernetes.io/enforce=restricted. Pod level: cloudgrange.podSecurity with the image's
numeric UID; container level: cloudgrange.containerSecurity. The one exception is promtail
(hostPath + an optional privileged init), which is off by default. */ -}}
{{- define "cloudgrange.podSecurity" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ if hasKey . "gid" }}{{ .gid }}{{ else }}{{ .uid }}{{ end }}
fsGroup: {{ if hasKey . "fsGroup" }}{{ .fsGroup }}{{ else }}{{ .uid }}{{ end }}
seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{- define "cloudgrange.containerSecurity" -}}
allowPrivilegeEscalation: false
capabilities: { drop: ["ALL"] }
{{- end -}}

{{- /* AB#9171: the ingress TLS Secret name — used by the Ingress and by the portal, which serves the
Secret's PUBLIC certificate (ca.crt / tls.crt, never tls.key) at /downloads/platform-ca.crt for
`cg auth login --ca-cert`. One definition so the two can never diverge. Works from the subcharts
too (global values, same release). */ -}}
{{- define "cloudgrange.tlsSecretName" -}}
{{- tpl ((((.Values.global).ingress).tls).secretName | default "") . | default (printf "%s-tls" .Release.Name) -}}
{{- end -}}
