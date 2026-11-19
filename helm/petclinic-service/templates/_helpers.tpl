{{/*
Resource name = serviceName. Other services reach this one by that DNS name
(http://config-server:8888, http://discovery-server:8761/eureka/, ...), so it must not
depend on the Helm/ArgoCD release name.
*/}}
{{- define "petclinic.name" -}}
{{- required "serviceName is required (set it in helm-values/<service>.yaml)" .Values.serviceName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "petclinic.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels: stable across upgrades. */}}
{{- define "petclinic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Standard labels (technical-spec: Standard Labels). */}}
{{- define "petclinic.labels" -}}
{{ include "petclinic.selectorLabels" . }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ include "petclinic.chart" . }}
{{- end -}}

{{- define "petclinic.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ include "petclinic.name" . }}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{/* <registry>/<name>:<tag>; refuses empty or "latest" tags. */}}
{{- define "petclinic.image" -}}
{{- $tag := required "image.tag is required (commit SHA)" .Values.image.tag | toString -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be a commit SHA, never \"latest\"" -}}
{{- end -}}
{{- $registry := required "image.registry is required (set in helm-values/<env>.yaml)" .Values.image.registry -}}
{{- $name := default (include "petclinic.name" .) .Values.image.name -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) $name $tag -}}
{{- end -}}

{{/* Render one probe from {type, path, periodSeconds, ...}. */}}
{{- define "petclinic.probe" -}}
{{- if eq .type "tcp" }}
tcpSocket:
  port: http
{{- else }}
httpGet:
  path: {{ required "probe path is required for type http" .path }}
  port: http
{{- end }}
{{- with .initialDelaySeconds }}
initialDelaySeconds: {{ . }}
{{- end }}
periodSeconds: {{ .periodSeconds }}
timeoutSeconds: {{ .timeoutSeconds }}
failureThreshold: {{ .failureThreshold }}
{{- end -}}
