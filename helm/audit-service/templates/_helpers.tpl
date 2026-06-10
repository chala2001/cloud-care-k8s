{{- define "audit-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "audit-service.labels" -}}
app.kubernetes.io/name: {{ include "audit-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "audit-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "audit-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
