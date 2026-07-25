# Applies stayledger-backup-notify-script from backup-notify.py (HTML email template).
# Run from this directory:
#   .\apply-backup-notify.ps1                         # production ns
#   .\apply-backup-notify.ps1 -Namespace stayledger-staging -Environment staging
param(
    [string]$Namespace = 'stayledger',
    [ValidateSet('production', 'staging')]
    [string]$Environment = 'production'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
kubectl create configmap stayledger-backup-notify-script `
  --from-file=notify.py="$here\backup-notify.py" `
  -n $Namespace `
  --dry-run=client -o yaml |
  kubectl label --local -f - `
    app=stayledger-postgres `
    component=database-backup-notify `
    environment=$Environment `
    -o yaml |
  kubectl apply -f -
Write-Host "Applied stayledger-backup-notify-script from backup-notify.py (ns=$Namespace env=$Environment)"
