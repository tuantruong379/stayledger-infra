# Sync SES SMTP creds into observability for Alertmanager email receivers.
# Reasoning: AlertmanagerConfig can only read Secrets in the same namespace;
# PMS staging already has working smtp-user/smtp-password for backup notify.
# Does not print secret values.
param(
  [string]$KubectlContext = 'HK-HUB-Cluster',
  [string]$SourceNamespace = 'stayledger-staging',
  [string]$SourceSecret = 'stayledger-staging-secrets',
  [string]$DestNamespace = 'observability',
  [string]$DestSecret = 'alertmanager-smtp'
)

$ErrorActionPreference = 'Stop'
kubectl --context $KubectlContext get secret $SourceSecret -n $SourceNamespace -o json |
  ConvertFrom-Json |
  ForEach-Object {
    $user = $_.data.'smtp-user'
    $pass = $_.data.'smtp-password'
    if (-not $user -or -not $pass) { throw 'Source secret missing smtp-user or smtp-password' }
    $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: $DestSecret
  namespace: $DestNamespace
  labels:
    app: stayledger
    component: alertmanager-smtp
type: Opaque
data:
  smtp-user: $user
  smtp-password: $pass
"@
    $manifest | kubectl --context $KubectlContext apply -f -
    Write-Host "Synced $DestNamespace/$DestSecret from $SourceNamespace/$SourceSecret (values not printed)"
  }
