[CmdletBinding()]
param(
    [string]$Namespace = "airadio",
    [string]$ExpectedIcecastHost = "192.168.2.5",
    [int]$ExpectedIcecastPort = 8000,
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
    "deployment/airadio-webui",
    "deployment/radio-api"
)) {
    kubectl -n $Namespace get $resource | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Missing required $resource in namespace $Namespace."
    }
}

$icecastHost = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.ICECAST_HOST}'
$icecastPort = kubectl -n $Namespace get configmap/airadio-endpoints -o jsonpath='{.data.ICECAST_PORT}'
if ($icecastHost -ne $ExpectedIcecastHost -or $icecastPort -ne $ExpectedIcecastPort.ToString()) {
    throw "Icecast endpoint mismatch: airadio-endpoints has ${icecastHost}:${icecastPort}; expected ${ExpectedIcecastHost}:$ExpectedIcecastPort. The current Icecast Compose publishes 8000:8000, so use port 8000 or explicitly pass matching -ExpectedIcecastHost/-ExpectedIcecastPort values."
}

$apiImage = kubectl -n $Namespace get deployment/radio-api -o jsonpath='{.spec.template.spec.containers[0].image}'
$webUiImage = kubectl -n $Namespace get deployment/airadio-webui -o jsonpath='{.spec.template.spec.containers[0].image}'
if ($apiImage -match 'registry\.example\.invalid|python:3\.12-slim|REPLACE_' -or
    $webUiImage -match 'registry\.example\.invalid|REPLACE_') {
    throw "Application Deployment still uses an example or placeholder image."
}

Write-Host "Preflight passed for context '$context'."
