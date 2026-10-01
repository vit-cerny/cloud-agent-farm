<#
  Send-Task.ps1 - the easy way to give your 24/7 farm work from Windows.
  Usage:
    powershell -ExecutionPolicy Bypass -File Send-Task.ps1 -Task "fix login bug" -Prompt "in ~/projects/shop, the login form..."
    powershell -ExecutionPolicy Bypass -File Send-Task.ps1 -Task "cleanup" -File .\prompt.txt -Dir "~/projects/shop"
  The worker picks it up within ~2 min; the answer lands in queue/done/<task>.summary.
  Set $FB to your VM IP once below. Password = your file manager (:8080) password.
#>
param([string]$Task = "", [string]$Prompt = "", [string]$File = "", [string]$Dir = "")
$ErrorActionPreference = "Stop"
$FB = "http://YOUR_VM_IP:8080"
if ([string]::IsNullOrWhiteSpace($Task)) { $Task = Read-Host "Task name (one word, e.g. fix-login)" }
$Task = ($Task -replace "[^A-Za-z0-9_-]", "-").Trim("-")
if ([string]::IsNullOrWhiteSpace($Task)) { Write-Host "empty task name"; exit 1 }
if (-not [string]::IsNullOrWhiteSpace($File)) {
  if (!(Test-Path $File)) { Write-Host "file not found: $File"; exit 1 }
  $Prompt = Get-Content $File -Raw
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { $Prompt = Read-Host "Prompt for the agent" }
if ([string]::IsNullOrWhiteSpace($Prompt)) { Write-Host "empty prompt"; exit 1 }
$tmp = Join-Path ([IO.Path]::GetTempPath()) "$Task.task"
[IO.File]::WriteAllText($tmp, $Prompt, [Text.Encoding]::UTF8)
$cred = Read-Host "File manager password" -AsSecureString
$pass = (New-Object PSCredential("x", $cred)).GetNetworkCredential().Password
try {
  $token = Invoke-RestMethod -Uri "$FB/api/login" -Method Post -ContentType "application/json" `
    -Body (@{username = "admin"; password = $pass} | ConvertTo-Json)
} catch { Write-Host "login failed: $($_.Exception.Message)"; exit 1 }
$pass = $null
if ([string]::IsNullOrWhiteSpace($token)) { Write-Host "login failed (empty token)"; exit 1 }
try {
  Invoke-RestMethod -Uri "$FB/api/resources/queue/pending/$Task.task" -Method Post `
    -Headers @{"X-Auth" = $token} -InFile $tmp -ContentType "text/plain" | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($Dir)) {
    $dtmp = Join-Path ([IO.Path]::GetTempPath()) "$Task.dir"
    [IO.File]::WriteAllText($dtmp, $Dir, [Text.Encoding]::UTF8)
    Invoke-RestMethod -Uri "$FB/api/resources/queue/pending/$Task.dir" -Method Post `
      -Headers @{"X-Auth" = $token} -InFile $dtmp -ContentType "text/plain" | Out-Null
    Remove-Item $dtmp -Force
  }
} catch { Write-Host "upload failed: $($_.Exception.Message)"; exit 1 }
Remove-Item $tmp -Force
Write-Host "Sent: $Task (watch queue/done/$Task.summary in the file manager)"
