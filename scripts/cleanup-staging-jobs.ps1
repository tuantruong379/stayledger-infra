<#!
.SYNOPSIS
  Remove old terminal Jobs from staging namespaces.

.DESCRIPTION
  TTL is the primary retention mechanism for managed Jobs. This script is a
  safety net for legacy/ad-hoc Jobs that were created without a TTL. It is
  dry-run by default; pass -ConfirmCleanup to delete the listed Jobs.

  The script never deletes active Jobs and only targets Jobs whose latest
  terminal condition is Complete or Failed and whose terminal/creation time is
  older than the configured age.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$KubectlContext = 'HK-HUB-Cluster',
  [string[]]$Namespaces = @('stayledger-ai-assistant', 'stayledger-staging'),
  [int]$OlderThanHours = 24,
  [switch]$ConfirmCleanup
)

$ErrorActionPreference = 'Stop'

if ($OlderThanHours -lt 1) {
  throw 'OlderThanHours must be at least 1 hour.'
}

function Invoke-KubectlJson {
  param([string[]]$KubectlArgs)
  $raw = & kubectl "--context=$KubectlContext" @KubectlArgs -o json
  if ($LASTEXITCODE -ne 0) {
    throw "kubectl failed: kubectl --context=$KubectlContext $($KubectlArgs -join ' ')"
  }
  return ($raw | ConvertFrom-Json)
}

$cutoff = [datetime]::UtcNow.AddHours(-$OlderThanHours)
$candidates = @()

foreach ($namespace in $Namespaces) {
  $jobs = Invoke-KubectlJson -KubectlArgs @('get', 'jobs', '-n', $namespace)
  foreach ($job in @($jobs.items)) {
    if (($job.status.active ?? 0) -gt 0) { continue }

    $terminal = @($job.status.conditions | Where-Object {
      $_.type -in @('Complete', 'Failed')
    } | Sort-Object lastTransitionTime -Descending | Select-Object -First 1)
    if ($terminal.Count -eq 0) { continue }

    $terminalTime = $job.status.completionTime
    if (-not $terminalTime) { $terminalTime = $terminal[0].lastTransitionTime }
    if (-not $terminalTime) { $terminalTime = $job.metadata.creationTimestamp }
    if ([datetime]$terminalTime -gt $cutoff) { continue }

    $candidates += [pscustomobject]@{
      Namespace = $namespace
      Name = $job.metadata.name
      Status = $terminal[0].type
      TerminalTime = $terminalTime
      HasTtl = [bool]$job.spec.ttlSecondsAfterFinished
    }
  }
}

if ($candidates.Count -eq 0) {
  Write-Host "No terminal Jobs older than $OlderThanHours hours were found." -ForegroundColor Green
  exit 0
}

Write-Host "Terminal Jobs older than $OlderThanHours hours:" -ForegroundColor Yellow
$candidates | Sort-Object Namespace, TerminalTime | Format-Table -AutoSize

if (-not $ConfirmCleanup) {
  Write-Host 'Dry-run only. Re-run with -ConfirmCleanup to delete these Jobs.' -ForegroundColor Cyan
  exit 0
}

foreach ($group in ($candidates | Group-Object Namespace)) {
  $names = @($group.Group | ForEach-Object { $_.Name })
  if ($PSCmdlet.ShouldProcess("$($group.Name): $($names -join ', ')", 'delete old terminal Jobs')) {
    & kubectl "--context=$KubectlContext" delete job -n $group.Name @names
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to delete one or more Jobs in namespace $($group.Name)."
    }
  }
}

Write-Host "Deleted $($candidates.Count) old terminal Job(s)." -ForegroundColor Green
