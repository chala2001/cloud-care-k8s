{{/*
Expand the name of the chart.
*/}}
{{- define "patient-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources in this chart.
*/}}
{{- define "patient-service.labels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by the Deployment and Service.
*/}}
{{- define "patient-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}