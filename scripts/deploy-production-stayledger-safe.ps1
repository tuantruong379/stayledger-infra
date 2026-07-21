# Safe production deployment wrapper for StayLedger.
#
# Enforces explicit image tags, operator confirmation, and preflight-before-apply.
# Delegates cluster work to deploy-production-stayledger.ps1 after validation.
#
# Usage (from stayledger-infra/ root):
#   .\scripts\deploy-production-stayledger-safe.ps1 `
#     -Phase preflight `
#     -PmsApiTag score90-20260720 `
#     -PmsAdminWebTag staging-addon-20260720-1018 `
#     -AiApiTag score90-20260720 `
#     -AiFrontendTag b7f47aa `
#     -ConfirmProd

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('preflight', 'pms-datastores', 'pms-app', 'ai-assistant', 'ingress', 'all')]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$PmsApiTag,

    [Parameter(Mandatory = $true)]
    [string]$PmsAdminWebTag,

    [Parameter(Mandatory = $true)]
    [string]$AiApiTag,

    [Parameter(Mandatory = $true)]
    [string]$AiFrontendTag,

    [string]$KubectlContext = 'stayledger',

    [switch]$ConfirmProd,

    [switch]$SkipSecrets,
    [switch]$SkipNodePrep,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$InfraRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$UnderlyingScript = Join-Path $PSScriptRoot 'deploy-production-stayledger.ps1'

function Test-ForbiddenImageTag {
    param([string]$Tag, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        throw "$Label tag is required and cannot be empty."
    }
    if ($Tag -eq 'latest') {
        throw "$Label tag '$Tag' is forbidden. Use an immutable CI or promotion tag."
    }
    if ($Tag -match ':') {
        throw "$Label tag must not include a repository prefix (got '$Tag'). Pass the tag only."
    }
}

function Get-ImageDigestSummary {
    param([string]$Repository, [string]$Tag)
    $ref = "${Repository}:${Tag}"
    try {
        $manifestJson = docker manifest inspect $ref 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($manifestJson)) {
            return 'UNKNOWN (docker manifest inspect unavailable or image not found locally/remotely)'
        }
        $manifest = $manifestJson | ConvertFrom-Json
        if ($manifest.digest) {
            return $manifest.digest
        }
        if ($manifest.manifests -and $manifest.manifests.Count -gt 0 -and $manifest.manifests[0].digest) {
            return $manifest.manifests[0].digest
        }
        return 'UNKNOWN (manifest returned without digest)'
    } catch {
        return 'UNKNOWN (digest resolution failed)'
    }
}

if (-not $ConfirmProd) {
    throw 'Production deploy refused: pass -ConfirmProd after reviewing the target summary below.'
}

$forbiddenTags = @($PmsApiTag, $PmsAdminWebTag, $AiApiTag, $AiFrontendTag)
foreach ($pair in @(
        @{ Label = 'PmsApiTag'; Value = $PmsApiTag },
        @{ Label = 'PmsAdminWebTag'; Value = $PmsAdminWebTag },
        @{ Label = 'AiApiTag'; Value = $AiApiTag },
        @{ Label = 'AiFrontendTag'; Value = $AiFrontendTag }
    )) {
    Test-ForbiddenImageTag -Tag $pair.Value -Label $pair.Label
}

$currentContext = (kubectl config current-context 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read kubectl current-context.'
}
if ($currentContext -ne $KubectlContext) {
    throw "Production deploy refused: kubectl context is '$currentContext', expected '$KubectlContext'. Run: kubectl config use-context $KubectlContext"
}

Write-Host ''
Write-Host '=== StayLedger PRODUCTION deploy — target summary ===' -ForegroundColor Cyan
Write-Host "  kubectl context     : $KubectlContext"
Write-Host '  PMS namespace       : stayledger'
Write-Host '  AI namespace        : stayledger-ai-assistant'
Write-Host '  PMS admin host      : https://app.stayledger.io'
Write-Host '  PMS API host        : https://api.stayledger.io'
Write-Host '  AI UI host          : https://assistant.stayledger.io'
Write-Host '  AI API host         : https://api-assistant.stayledger.io'
Write-Host "  Phase               : $Phase"
Write-Host ''
Write-Host '  Images:' -ForegroundColor Yellow
Write-Host "    putin111/stayledger-api:$PmsApiTag"
Write-Host "    putin111/stayledger-admin-web:$PmsAdminWebTag"
Write-Host "    putin111/ai-hotel-assistant:$AiApiTag"
Write-Host "    putin111/ai-hotel-assistant-frontend:$AiFrontendTag"
Write-Host ''
Write-Host '  Digest resolution (best effort, no secrets logged):' -ForegroundColor Yellow
Write-Host ("    stayledger-api              : {0}" -f (Get-ImageDigestSummary 'putin111/stayledger-api' $PmsApiTag))
Write-Host ("    stayledger-admin-web        : {0}" -f (Get-ImageDigestSummary 'putin111/stayledger-admin-web' $PmsAdminWebTag))
Write-Host ("    ai-hotel-assistant          : {0}" -f (Get-ImageDigestSummary 'putin111/ai-hotel-assistant' $AiApiTag))
Write-Host ("    ai-hotel-assistant-frontend : {0}" -f (Get-ImageDigestSummary 'putin111/ai-hotel-assistant-frontend' $AiFrontendTag))
Write-Host ''
Write-Host '  Operator confirmed production target (-ConfirmProd).' -ForegroundColor Green
Write-Host ''

function Invoke-ProductionDeployScript {
    param(
        [string]$TargetPhase
    )
    $invokeArgs = @{
        Phase            = $TargetPhase
        KubectlContext   = $KubectlContext
        PmsApiTag        = $PmsApiTag
        PmsAdminWebTag   = $PmsAdminWebTag
        AiApiTag         = $AiApiTag
        AiFrontendTag    = $AiFrontendTag
    }
    if ($SkipSecrets) { $invokeArgs.SkipSecrets = $true }
    if ($SkipNodePrep) { $invokeArgs.SkipNodePrep = $true }
    if ($DryRun) { $invokeArgs.DryRun = $true }
    & $UnderlyingScript @invokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Production deploy script failed for phase '$TargetPhase'."
    }
}

# Always run preflight first for non-preflight phases.
$phasesRequiringPreflight = @('pms-datastores', 'pms-app', 'ai-assistant', 'ingress', 'all')
if ($Phase -in $phasesRequiringPreflight) {
    Write-Host '[safe-wrapper] Running mandatory preflight before phase deploy...' -ForegroundColor Yellow
    Invoke-ProductionDeployScript -TargetPhase 'preflight'
}

Push-Location $InfraRoot
try {
    Invoke-ProductionDeployScript -TargetPhase $Phase
    Write-Host ''
    Write-Host "[safe-wrapper] Phase '$Phase' completed." -ForegroundColor Green
} finally {
    Pop-Location
}
