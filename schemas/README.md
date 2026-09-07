# schemas/ — CI 가 쓰는 CRD 스키마

`kubeconform`은 쿠버네티스 내장 리소스의 스키마만 안다. 이 클러스터가 쓰는 CRD 11종은 모른다.
그래서 **클러스터에서 뽑은 `openAPIV3Schema`를 파일로 커밋해 두고** CI가 그것을 읽는다.

CI 러너(데스크탑)에는 kubeconfig가 없다. 검증이 클러스터에 의존하면 안 되기도 한다 —
클러스터가 검증 장치가 되는 순간, 잘못된 매니페스트를 알려 주는 시점이 배포 이후로 밀린다.

## 왜 `-ignore-missing-schemas`를 안 쓰나

그 옵션은 모르는 종류를 통째로 건너뛴다. 그러면 `Kafka` CR의 브로커 수·리스너,
`Certificate`의 도메인, `Middleware`의 헤더 설정이 전부 검증 밖으로 나간다.
**이 저장소에서 오타가 나면 아픈 자리가 정확히 거기다.**

## 담긴 것 (11종)

| 그룹 | 종류 |
|---|---|
| `kafka.strimzi.io` | Kafka · KafkaNodePool · KafkaTopic |
| `cert-manager.io` | ClusterIssuer · Certificate |
| `metallb.io` | IPAddressPool · L2Advertisement |
| `monitoring.coreos.com` | ServiceMonitor · PodMonitor |
| `bitnami.com` | SealedSecret |
| `traefik.io` | Middleware |

## 갱신 — CRD 버전을 올리면 여기도 다시 뽑는다

오퍼레이터나 차트를 업그레이드해 CRD 스키마가 바뀌면, 이 파일들은 옛 스키마 그대로다.
**그러면 CI가 새 필드를 "스키마에 없는 필드"로 잡아 통과하던 매니페스트가 실패한다.**
반대로 없어진 필드를 못 잡는다.

PowerShell에서 뽑는다.

```powershell
cd cgv-infra
$crds = 'kafkas.kafka.strimzi.io','kafkanodepools.kafka.strimzi.io','kafkatopics.kafka.strimzi.io',
        'sealedsecrets.bitnami.com','clusterissuers.cert-manager.io','certificates.cert-manager.io',
        'ipaddresspools.metallb.io','l2advertisements.metallb.io','middlewares.traefik.io',
        'servicemonitors.monitoring.coreos.com','podmonitors.monitoring.coreos.com'
foreach ($c in $crds) {
  $j = kubectl get crd $c -o json | ConvertFrom-Json
  foreach ($v in $j.spec.versions) {
    if (-not $v.schema.openAPIV3Schema) { continue }
    $f = "$PWD\schemas\$($j.spec.names.kind.ToLower())-$($j.spec.group)-$($v.name).json"
    [System.IO.File]::WriteAllText($f, ($v.schema.openAPIV3Schema | ConvertTo-Json -Depth 100 -Compress),
                                   [System.Text.UTF8Encoding]::new($false))
  }
}
```

**함정 둘 — 둘 다 실제로 겪었다.**

1. **파일 이름은 `<kind>-<group>-<version>.json`이고 kind는 소문자다.** 그룹과 버전은 원본 표기 그대로다.
   `kubeconform`이 `{{.ResourceKind}}`를 소문자로 치환하기 때문이다
   (v0.6.7 `pkg/registry/registry.go`의 `ResourceKind: strings.ToLower(resourceKind)`).
   그래서 위 추출 명령이 `kind`에 `.ToLower()`를 건다. `SealedSecret-...`로 두면 러너에서 안 찾는다.
2. **UTF-8(BOM 없이)로 저장해야 한다.** `Out-File -Encoding ascii`로 쓰면 설명문의 비ASCII
   문자가 깨져 `kubeconform`이 그 파일을 로드하지 못하고, 증상은 **"could not find schema"**로 나온다.
   파일이 있는데 못 찾는다고 나오면 이걸 의심한다.

## 확인

```powershell
docker run --rm -v "${PWD}:/w" -w /w ghcr.io/yannh/kubeconform:v0.6.7 `
  -strict -summary -schema-location default `
  -schema-location '/w/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' `
  manifests/
```

`Errors: 0`이어야 한다. `could not find schema`가 뜨면 그 종류의 CRD가 여기 없거나 위 함정 둘 중 하나다.

**⚠ 이 확인은 함정 1을 못 잡는다.** Windows 디렉터리를 마운트하므로 파일시스템이 대소문자를
구분하지 않아, 이름이 `SealedSecret-...`이어도 소문자 조회가 그대로 열린다. 러너(리눅스)에서는
안 열린다 — 파이프라인 #111부터 #115까지 이 차이 때문에 로컬은 통과하고 CI만 실패했다.
대소문자는 `git ls-files schemas/`로 눈으로 확인한다.
