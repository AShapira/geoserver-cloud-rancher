{{- define "platform-infra.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-infra.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "platform-infra.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-infra.labels" -}}
app.kubernetes.io/name: {{ include "platform-infra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
