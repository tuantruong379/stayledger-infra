# Applies stayledger-backup-notify-script from backup-notify.py (HTML email template).
# Run from this directory:
#   .\apply-backup-notify.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
kubectl create configmap stayledger-backup-notify-script `
  --from-file=notify.py="$here\backup-notify.py" `
  -n stayledger `
  --dry-run=client -o yaml |
  kubectl label --local -f - `
    app=stayledger-postgres `
    component=database-backup-notify `
    environment=production `
    -o yaml |
  kubectl apply -f -
Write-Host 'Applied stayledger-backup-notify-script from backup-notify.py'
