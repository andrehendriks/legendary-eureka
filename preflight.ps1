[CmdletBinding()]
param(
    [string]$Namespace = "airadio",
    [string]$ExpectedIcecastHost = "192.168.2.5",
    [int]$ExpectedIcecastPort = 8030,
    [string]$ExpectedIcecastMount = "/live",
    [string]$ExpectedPlaylistPath = "/radio/playlist/playlist.m3u8",
    [string]$ExpectedMediaNfsServer = "192.168.2.5",
    [string]$ExpectedMediaNfsPath = "/volume1/Dj/Music",
    [string]$ExpectedWebUiImage = "ghcr.io/andrehendriks/airadio-webui@sha256:b1b1da95075fca653a34f8d9ebb329a719edafd34c7c0075da8d69c95d9535cb",
    [switch]$Offline
)

$ErrorActionPreference = "Stop"

kubectl kustomize . | kubectl apply --dry-run=client -f -
if ($LASTEXITCODE -ne 0) {
    throw "Client-side Kubernetes manifest validation failed."
}

if ($Offline) {
    $renderedManifests = kubectl kustomize .
    $renderedIcecastHost = ($renderedManifests | Select-String -Pattern '^\s*ICECAST_HOST:\s*(\S+)\s*$').Matches.Groups[1].Value
    $renderedIcecastPort = ($renderedManifests | Select-String -Pattern '^\s*ICECAST_PORT:\s*"?(\d+)"?\s*$').Matches.Groups[1].Value
    if ($renderedIcecastHost -ne $ExpectedIcecastHost -or
        $renderedIcecastPort -ne $ExpectedIcecastPort.ToString()) {
        throw "Rendered ICECAST_HOST/ICECAST_PORT does not match the expected ${ExpectedIcecastHost}:$ExpectedIcecastPort deployment."
    }
    if (($renderedManifests -join "`n") -notmatch [regex]::Escape($ExpectedPlaylistPath)) {
        throw "Rendered Liquidsoap configuration does not reference the expected playlist '$ExpectedPlaylistPath'."
    }
    $renderedText = $renderedManifests -join "`n"
    if ($renderedText -notmatch [regex]::Escape("mount=`"$ExpectedIcecastMount`"")) {
        throw "Rendered Liquidsoap configuration does not use the expected Icecast mount '$ExpectedIcecastMount'."
    }
    if ($renderedText -notmatch [regex]::Escape("server: $ExpectedMediaNfsServer") -or
        $renderedText -notmatch [regex]::Escape("path: $ExpectedMediaNfsPath")) {
        throw "Rendered Liquidsoap media NFS volume does not match the expected ${ExpectedMediaNfsServer}:$ExpectedMediaNfsPath export."
    }
    if ($renderedText -notmatch [regex]::Escape($ExpectedWebUiImage)) {
        throw "Rendered WebUI Deployment does not use the expected immutable image '$ExpectedWebUiImage'."
    }
    Write-Host "Offline manifest validation passed."
    exit 0
}

$context = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
    throw "No active kubectl context. Configure the production cluster context first."
}

foreach ($resource in @(
    "secret/desktop-stream-vught-eu-tls",
    "secret/airadio-runtime-secrets",
    "pvc/ollama-pvc",
    "deployment/airadio-webui",
    "deployment/radio-api"
)) {
    kubectl -n $Namespace get $resource | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Missing required $resource in namespace $Namespace."
    }
}

$ollamaPvcPhase = kubectl -n $Namespace get pvc/ollama-pvc -o jsonpath='{.status.phase}'
if ($ollamaPvcPhase -ne "Bound") {
    throw "Ollama PVC is not Bound (current phase: '$ollamaPvcPhase'). The standard bundle intentionally preserves its existing immutable PVC specification."
}

$icecastHost = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.ICECAST_HOST}'
$icecastPort = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.ICECAST_PORT}'
$mediaNfsServer = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.MEDIA_NFS_SERVER}'
$mediaNfsPath = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.MEDIA_NFS_PATH}'
if ($icecastHost -match '^(localhost|127\.0\.0\.1|::1)$') {
    throw "Icecast endpoint '$icecastHost' is loopback from the Liquidsoap pod and cannot reach the external Docker-host service."
}
if ($mediaNfsServer -ne $ExpectedMediaNfsServer -or $mediaNfsPath -ne $ExpectedMediaNfsPath) {
    throw "Media NFS export mismatch: airadio-endpoints has ${mediaNfsServer}:$mediaNfsPath; expected ${ExpectedMediaNfsServer}:$ExpectedMediaNfsPath. Confirm the Synology NFS export is reachable from every Kubernetes node before rollout."
}
if ($icecastHost -ne $ExpectedIcecastHost -or $icecastPort -ne $ExpectedIcecastPort.ToString()) {
    throw "Icecast endpoint mismatch: airadio-endpoints has ${icecastHost}:${icecastPort}; expected ${ExpectedIcecastHost}:$ExpectedIcecastPort. For an intentional different reachable endpoint, explicitly pass matching -ExpectedIcecastHost/-ExpectedIcecastPort values."
}

$apiImage = kubectl -n $Namespace get deployment/radio-api -o jsonpath='{.spec.template.spec.containers[0].image}'
$webUiImage = kubectl -n $Namespace get deployment/airadio-webui -o jsonpath='{.spec.template.spec.containers[0].image}'
if ($apiImage -match 'registry\.example\.invalid|python:3\.12-slim|REPLACE_' -or
    $webUiImage -match 'registry\.example\.invalid|REPLACE_') {
    throw "Application Deployment still uses an example or placeholder image."
}
if ($webUiImage -ne $ExpectedWebUiImage) {
    throw "WebUI image mismatch: deployment has '$webUiImage'; expected the approved immutable image '$ExpectedWebUiImage'."
}

Write-Host "Preflight passed for context '$context'."
