{{/*
Expand the name of the chart.
*/}}
{{- define "limina.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "limina.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "limina.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "limina.labels" -}}
helm.sh/chart: {{ include "limina.chart" . }}
app.kubernetes.io/name: {{ include "limina.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Image reference for a Limina components. Expects a dict with "image" and "root".
*/}}
{{- define "limina.image" -}}
{{- printf "%s/%s:%v" (default .root.Values.repository .image.repository) .image.name .image.tag }}
{{- end }}

{{/*
Service account name used by the Limina Platform pods.
When create is true, defaults to <fullname>-platform unless a name is set.
When create is false, returns the name of an existing service account, or empty to use the namespace default.
*/}}
{{- define "limina.platform.serviceAccountName" -}}
{{- if .Values.platform.shared.serviceAccount.create }}
{{- default (printf "%s-platform" (include "limina.fullname" .)) .Values.platform.shared.serviceAccount.name }}
{{- else }}
{{- .Values.platform.shared.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Returns "true" when the External Secrets Operator is enabled for at least one product, otherwise empty.
*/}}
{{- define "limina.externalSecretsEnabled" -}}
{{- $es := .Values.externalSecrets }}
{{- if or $es.dockerCredential.enabled $es.core.enabled $es.async.enabled $es.platform.enabled }}
{{- true }}
{{- end }}
{{- end }}

{{/*
Service account name used by the SecretStore to authenticate to the secret store provider.
When create is true, defaults to <fullname>-secret-store unless a name is set.
When create is false, returns the name of an existing service account, or empty to use the identity of the External Secrets Operator controller.
*/}}
{{- define "limina.secretStore.serviceAccountName" -}}
{{- if .Values.externalSecrets.secretStore.serviceAccount.create }}
{{- default (printf "%s-secret-store" (include "limina.fullname" .)) .Values.externalSecrets.secretStore.serviceAccount.name }}
{{- else }}
{{- .Values.externalSecrets.secretStore.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Provider configuration of the SecretStore, rendered as YAML for spec.provider.
Adds the SecretStore service account to the aws provider (auth.jwt.serviceAccountRef, unless auth is set)
and to the azurekv provider with authType WorkloadIdentity (serviceAccountRef, unless set).
*/}}
{{- define "limina.secretStore.provider" -}}
{{- $provider := deepCopy .Values.externalSecrets.secretStore.provider }}
{{- $serviceAccountName := include "limina.secretStore.serviceAccountName" . }}
{{- if $serviceAccountName }}
{{- if and (kindIs "map" $provider.aws) (not (hasKey $provider.aws "auth")) }}
{{- $_ := set $provider.aws "auth" (dict "jwt" (dict "serviceAccountRef" (dict "name" $serviceAccountName))) }}
{{- end }}
{{- if and (kindIs "map" $provider.azurekv) (eq (toString $provider.azurekv.authType) "WorkloadIdentity") (not (hasKey $provider.azurekv "serviceAccountRef")) }}
{{- $_ := set $provider.azurekv "serviceAccountRef" (dict "name" $serviceAccountName) }}
{{- end }}
{{- end }}
{{- toYaml $provider }}
{{- end }}

{{/*
Persistent volume claim name for the Limina Platform file store.
*/}}
{{- define "limina.platform.claimName" -}}
{{- printf "%s-platform" (include "limina.fullname" .) }}
{{- end }}

{{/*
API_PORT set in the middleware's configmap data, or the platform shared configmap data, which envFrom loads last
and so wins. Empty when neither sets it.
*/}}
{{- define "limina.platform.middleware.userPort" -}}
{{- $port := "" }}
{{- range (concat (.Values.platform.middleware.configmap.data | default list) (.Values.platform.shared.configmap.data | default list)) }}
{{- if eq .name "API_PORT" }}
{{- $port = toString .value }}
{{- end }}
{{- end }}
{{- $port }}
{{- end }}

{{/*
Port the middleware container listens on: a user-set API_PORT, else platform.middleware.service.targetPort.
*/}}
{{- define "limina.platform.middleware.port" -}}
{{- default (toString .Values.platform.middleware.service.targetPort) (include "limina.platform.middleware.userPort" .) }}
{{- end }}
