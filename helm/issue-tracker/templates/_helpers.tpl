{{/*
──────────────────────────────────────────────────────────────────────────────
_helpers.tpl — reusable template snippets
──────────────────────────────────────────────────────────────────────────────
*/}}

{{/*
Common labels stamped on every resource.
*/}}
{{- define "issue-tracker.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "issue-tracker.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default "issue-app-sa" -}}
{{- end }}

{{/*
MySQL service hostname.
  - mysql.enabled=true  → derived from the in-cluster Service name (<release>-mysql)
  - mysql.enabled=false → db.host must be set (e.g. RDS endpoint)
*/}}
{{- define "issue-tracker.mysqlHost" -}}
{{- if .Values.mysql.enabled -}}
  {{- printf "%s-mysql" .Release.Name -}}
{{- else -}}
  {{- required "db.host must be set when mysql.enabled=false (e.g. your RDS endpoint)" .Values.db.host -}}
{{- end -}}
{{- end }}

{{/*
Full JDBC URL passed to both auth-service and issue-service.
*/}}
{{- define "issue-tracker.jdbcUrl" -}}
{{- printf "jdbc:mysql://%s:%d/%s?createDatabaseIfNotExist=true&useSSL=false&allowPublicKeyRetrieval=true" (include "issue-tracker.mysqlHost" .) (.Values.db.port | int) .Values.db.name -}}
{{- end }}

{{/*
Ingress backend path entries — shared by both the host and no-host rule branches.
Indented at the "paths:" child level (each path entry is a list item).
*/}}
{{- define "issue-tracker.ingressPaths" -}}
- path: {{ .Values.ingress.paths.api | quote }}
  pathType: {{ .Values.ingress.paths.apiPathType }}
  backend:
    service:
      name: api-gateway
      port:
        number: 80
- path: {{ .Values.ingress.paths.frontend | quote }}
  pathType: {{ .Values.ingress.paths.frontendPathType }}
  backend:
    service:
      name: frontend-service
      port:
        number: 80
{{- end }}

{{/*
cert-manager ClusterIssuer name — derived from tls.issuerType.
  selfsigned          → issue-tracker-selfsigned-issuer
  letsencrypt-staging → letsencrypt-staging
  letsencrypt         → letsencrypt-prod
*/}}
{{- define "issue-tracker.clusterIssuerName" -}}
{{- if eq .Values.tls.issuerType "selfsigned" -}}
  issue-tracker-selfsigned-issuer
{{- else if eq .Values.tls.issuerType "letsencrypt-staging" -}}
  letsencrypt-staging
{{- else if eq .Values.tls.issuerType "letsencrypt" -}}
  letsencrypt-prod
{{- else -}}
  {{- fail (printf "tls.issuerType must be selfsigned | letsencrypt-staging | letsencrypt, got: %s" .Values.tls.issuerType) -}}
{{- end -}}
{{- end }}
