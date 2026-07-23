# Apply email AlertmanagerConfig with authUsername filled from Secret (not committed).
# Usage: pwsh -File apply-alertmanager-email-config.ps1
param([string]$KubectlContext = 'HK-HUB-Cluster')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
& (Join-Path $root 'sync-alertmanager-smtp-from-staging.ps1') -KubectlContext $KubectlContext

$userB64 = kubectl --context $KubectlContext get secret alertmanager-smtp -n observability -o jsonpath='{.data.smtp-user}'
if (-not $userB64) { throw 'alertmanager-smtp/smtp-user missing' }
$user = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($userB64))

$src = Join-Path $root 'alertmanager-config.yaml'
$tmp = Join-Path $env:TEMP ("amconfig-email-{0}.yaml" -f [guid]::NewGuid().ToString('N'))
try {
  (Get-Content $src -Raw) -replace 'authUsername: ""', ("authUsername: `"$user`"") | Set-Content $tmp -Encoding utf8
  kubectl --context $KubectlContext apply -f $tmp
  Write-Host 'Applied AlertmanagerConfig email receivers (authUsername injected from secret; not printed).'
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
