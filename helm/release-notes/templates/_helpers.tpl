{{- define "release-notes.name" -}}release-notes{{- end }}

{{- define "release-notes.labels" -}}
app.kubernetes.io/name: {{ include "release-notes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: release-notes
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
environment: {{ .Values.environment }}
{{- end }}

{{- define "release-notes.selectorLabels" -}}
app.kubernetes.io/name: {{ include "release-notes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Immutable digest reference when available, tag otherwise. */}}
{{- define "release-notes.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{ fail "image.digest or image.tag must be set" }}
{{- end -}}
{{- end }}

{{- define "release-notes.dbHost" -}}{{ .Release.Name }}-db{{- end }}

{{/* Restricted-profile security context shared by app and migration containers. */}}
{{- define "release-notes.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* Database credentials come from the Secret; everything else from the ConfigMap. */}}
{{- define "release-notes.dbEnv" -}}
- name: DATABASE_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: username
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: password
{{- end }}
