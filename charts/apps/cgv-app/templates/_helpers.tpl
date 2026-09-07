{{- define "app.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.name" -}}
{{- include "app.fullname" . -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- /* 이미지 주소는 세 축이 합쳐진 값이다 — registry(환경) / repository(서비스) : tag(빌드).
       조립을 여기 한 곳에 두는 이유 = deployment 와 migration-job 두 군데가 같은 이미지를 쓰는데,
       흩어 두면 한쪽만 고쳐 두 파드가 다른 이미지로 뜨는 상태가 조용히 생긴다.
       required 는 렌더 시점에 어느 층이 비었는지 말하게 한다 — 없으면 ImagePullBackOff 로만 드러난다. */}}
{{- define "app.image" -}}
{{- $reg := required "image.registry 가 비었다 — envs/<env>/<서비스>.yaml 에서 지정한다" .Values.image.registry -}}
{{- $repo := required "image.repository 가 비었다 — charts/apps/<서비스>/values.yaml 에서 지정한다" .Values.image.repository -}}
{{- printf "%s/%s:%s" $reg $repo .Values.image.tag -}}
{{- end -}}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
app.kubernetes.io/name: {{ include "app.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.partOf }}
app.kubernetes.io/part-of: {{ . }}
{{- end }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
