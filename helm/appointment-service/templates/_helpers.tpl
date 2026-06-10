{{- define "appointment-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "appointment-service.labels" -}}
app.kubernetes.io/name: {{ include "appointment-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "appointment-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "appointment-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
