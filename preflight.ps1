[CmdletBinding()]
param(
    [string]$Namespace = "airadio",
    [switch]$Offline
)

$ErrorActionPreference = "Stop"

kubectl kustomize . | kubectl apply --dry-run=client -f -
if ($LASTEXITCODE -ne 0) {
    throw "Client-side Kubernetes manifest validation failed."
}

if ($Offline) {
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

$apiImage = kubectl -n $Namespace get deployment/radio-api -o jsonpath='{.spec.template.spec.containers[0].image}'
$webUiImage = kubectl -n $Namespace get deployment/airadio-webui -o jsonpath='{.spec.template.spec.containers[0].image}'
if ($apiImage -match 'registry\.example\.invalid|python:3\.12-slim|REPLACE_' -or
    $webUiImage -match 'registry\.example\.invalid|REPLACE_') {
    throw "Application Deployment still uses an example or placeholder image."
}

Write-Host "Preflight passed for context '$context'."
