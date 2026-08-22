# Compare live production (context stayledger, namespace stayledger) against git manifests.
# Usage (from stayledger-infra/):
#   .\scripts\audit-production-drift.ps1
#   .\scripts\audit-production-drift.ps1 -JsonReport artifacts/prod-drift-audit.json

[CmdletBinding()]
param(
  [string]$KubectlContext = 'stayledger',
  [string]$Namespace = 'stayledger',
  [string]$JsonReport = ''
)

$ErrorActionPreference = 'Stop'
$InfraRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

function Invoke-KubectlJson {
  param([string[]]$KubectlArgs)
  $raw = & kubectl --context=$KubectlContext @KubectlArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($raw -join "`n") }
  return ($raw | Out-String) | ConvertFrom-Json
}

function Get-ConfigMapHashFromJson {
  param($Cm)
  ($Cm.data.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|'
}

function Get-ConfigMapHashFromYamlFile {
  param([string]$Path)
  $lines = Get-Content $Path
  $inData = $false
  $pairs = @()
  foreach ($line in $lines) {
    if ($line -match '^data:') { $inData = $true; continue }
    if ($inData -and $line -match '^[^ ]') { break }
    if ($inData -and $line -match '^  #') { continue }
    if ($inData -and $line -match '^  ([A-Z0-9_]+):\s+(.+)$') {
      $val = $Matches[2].Trim().Trim('"')
      $pairs += "$($Matches[1])=$val"
    }
  }
  ($pairs | Sort-Object) -join '|'
}

function Get-ConfigMapHashFromKustomize {
  param([string]$OverlayRel, [string]$ConfigMapName)
  Push-Location $InfraRoot
  try {
    $docs = & kubectl kustomize $OverlayRel 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($docs -join "`n") }
    $chunks = ($docs -join "`n") -split '(?m)^---\s*$'
    foreach ($chunk in $chunks) {
      if ($chunk -notmatch '(?m)^kind:\s+ConfigMap\s') { continue }
      if ($chunk -notmatch "name:\s+$ConfigMapName\s") { continue }
      $pairs = @()
      $inData = $false
      foreach ($line in ($chunk -split "`n")) {
        if ($line -match '^data:') { $inData = $true; continue }
        if ($inData -and $line -match '^[^ ]') { break }
        if ($inData -and $line -match '^  #') { continue }
        if ($inData -and $line -match '^  ([A-Z0-9_]+):\s+(.+)$') {
          $pairs += "$($Matches[1])=$($Matches[2].Trim().Trim('"'))"
        }
      }
      return ($pairs | Sort-Object) -join '|'
    }
    throw "ConfigMap $ConfigMapName not found in $OverlayRel"
  } finally {
    Pop-Location
  }
}

function Get-KustomizeDigest {
  param([string]$OverlayRel, [string]$ImageRepo)
  $path = Join-Path (Join-Path $InfraRoot $OverlayRel) 'kustomization.yaml'
  $text = Get-Content $path -Raw
  if ($text -match "(?ms)name:\s+$([regex]::Escape($ImageRepo))\s*\r?\n\s*digest:\s+(\S+)") {
    return "$ImageRepo@$($Matches[1])"
  }
  throw "digest for $ImageRepo not found in $OverlayRel/kustomization.yaml"
}

Write-Host "=== Production drift audit (context=$KubectlContext ns=$Namespace) ===" -ForegroundColor Cyan
$ctx = kubectl config current-context 2>&1
Write-Host "Current kubectl context: $ctx"
if ($ctx -ne $KubectlContext) {
  Write-Host "WARNING: active context is not $KubectlContext - comparisons use --context=$KubectlContext" -ForegroundColor Yellow
}

$results = @()
$drift = 0

function Add-CheckResult {
  param($Name, $Kind, [bool]$Ok, $Details)
  $script:results += [pscustomobject]@{
    name = $Name
    kind = $Kind
    ok = $Ok
    details = $Details
  }
  if (-not $Ok) { $script:drift++ }
  $color = if ($Ok) { 'Green' } else { 'Red' }
  $status = if ($Ok) { 'OK' } else { 'DRIFT' }
  Write-Host ("[{0}] {1}" -f $status, $Name) -ForegroundColor $color
  if (-not $Ok -and $Details) {
    $Details.GetEnumerator() | ForEach-Object {
      Write-Host ("  {0}: {1}" -f $_.Key, $_.Value) -ForegroundColor DarkYellow
    }
  }
}

# Deployments
$deployChecks = @(
  @{ dep = 'stayledger-api'; container = 'api'; gitImage = { Get-KustomizeDigest 'stayledger-api/production' 'putin111/stayledger-api' }; gitVersion = '6764d49' },
  @{ dep = 'stayledger-ai-worker'; container = 'ai-worker'; gitImage = { Get-KustomizeDigest 'stayledger-api/production' 'putin111/stayledger-api' }; gitVersion = '6764d49' },
  @{ dep = 'stayledger-admin-web'; container = 'admin-web'; gitImage = { Get-KustomizeDigest 'stayledger-admin-web/production' 'putin111/stayledger-admin-web' }; gitVersion = '77cebd3' }
)

foreach ($c in $deployChecks) {
  $live = Invoke-KubectlJson @('get', "deployment/$($c.dep)", '-n', $Namespace, '-o', 'json')
  $liveImage = ($live.spec.template.spec.containers | Where-Object name -eq $c.container).image
  $gitImage = & $c.gitImage
  $liveVersion = $live.spec.template.metadata.labels.version
  $ok = ($liveImage -eq $gitImage) -and ($liveVersion -eq $c.gitVersion)
  Add-CheckResult $c.dep 'deployment' $ok @{
    liveImage = $liveImage
    gitImage = $gitImage
    liveVersion = $liveVersion
    gitVersion = $c.gitVersion
  }
}

# Landing (standalone prd/deployment.yaml)
$landingLive = Invoke-KubectlJson @('get', 'deployment/stayledger-landing', '-n', $Namespace, '-o', 'json')
$landingLiveImage = ($landingLive.spec.template.spec.containers | Where-Object name -eq 'landing').image
$landingYaml = Get-Content (Join-Path $InfraRoot 'stayledger-landing/prd/deployment.yaml') -Raw
$landingGitImage = if ($landingYaml -match 'image:\s+(\S+)') { $Matches[1] } else { 'MISSING' }
Add-CheckResult 'stayledger-landing' 'deployment' ($landingLiveImage -eq $landingGitImage) @{
  liveImage = $landingLiveImage
  gitImage = $landingGitImage
  liveReplicas = $landingLive.spec.replicas
  gitReplicas = 1
}

# ConfigMaps
$apiCmLive = Invoke-KubectlJson @('get', 'configmap/stayledger-api-config', '-n', $Namespace, '-o', 'json')
$apiCmGit = Get-ConfigMapHashFromKustomize 'stayledger-api/production' 'stayledger-api-config'
Add-CheckResult 'stayledger-api-config' 'configmap' ((Get-ConfigMapHashFromJson $apiCmLive) -eq $apiCmGit) @{ note = 'kustomize build vs live' }

$adminCmLive = Invoke-KubectlJson @('get', 'configmap/stayledger-admin-web-config', '-n', $Namespace, '-o', 'json')
$adminCmGit = Get-ConfigMapHashFromKustomize 'stayledger-admin-web/production' 'stayledger-admin-web-config'
Add-CheckResult 'stayledger-admin-web-config' 'configmap' ((Get-ConfigMapHashFromJson $adminCmLive) -eq $adminCmGit) @{ note = 'kustomize build vs live' }

$landingCmLive = Invoke-KubectlJson @('get', 'configmap/stayledger-landing-config', '-n', $Namespace, '-o', 'json')
$landingCmGit = Get-ConfigMapHashFromYamlFile (Join-Path $InfraRoot 'stayledger-landing/prd/deployment.yaml')
Add-CheckResult 'stayledger-landing-config' 'configmap' ((Get-ConfigMapHashFromJson $landingCmLive) -eq $landingCmGit) @{ note = 'landing config embedded in prd/deployment.yaml' }

Write-Host ''
if ($drift -eq 0) {
  Write-Host 'Verdict: NO DRIFT detected for checked PMS workloads.' -ForegroundColor Green
} else {
  Write-Host "Verdict: $drift drift item(s). Run: kubectl apply -k stayledger-api/production; kubectl apply -k stayledger-admin-web/production; kubectl apply -f stayledger-landing/prd/" -ForegroundColor Red
}

if ($JsonReport) {
  $dir = Split-Path -Parent $JsonReport
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  @{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    context = $KubectlContext
    namespace = $Namespace
    driftCount = $drift
    checks = $results
  } | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonReport -Encoding UTF8
  Write-Host "Report: $JsonReport"
}

exit $(if ($drift -eq 0) { 0 } else { 1 })
