<#
  Export-FarmConfig.ps1 - export your local OpenCode/OpenChamber setup
  (settings, models, MCP servers, skills, agents, commands, API keys)
  into an encrypted bundle for the 24/7 farm VM.

  Run:  powershell -ExecutionPolicy Bypass -File Export-FarmConfig.ps1

  Output: farm-config-<date>.zip.enc in the current folder.
  The bundle is AES-256 encrypted (openssl-compatible) with a passphrase
  ONLY YOU know. Nothing is uploaded anywhere by this script.
#>
$ErrorActionPreference = "Stop"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work  = Join-Path ([IO.Path]::GetTempPath()) "farm-config-$stamp"
New-Item -ItemType Directory -Path $work | Out-Null
$found = $false

function Grab($label, $src, $destSub) {
  if ((Test-Path $src) -and ((Get-ChildItem $src -Force | Measure-Object).Count -gt 0)) {
    $dest = Join-Path $work $destSub
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $src "*") $dest -Recurse -Force
    Write-Host "  [+] $label  ($src)"
    $script:found = $true
  } else {
    Write-Host "  [ ] $label  not found ($src)"
  }
}

function Read-PassphraseTwice {
  while ($true) {
    $s1 = Read-Host "Passphrase" -AsSecureString
    $s2 = Read-Host "Repeat passphrase" -AsSecureString
    $p1 = (New-Object PSCredential("x", $s1)).GetNetworkCredential().Password
    $p2 = (New-Object PSCredential("x", $s2)).GetNetworkCredential().Password
    if ($p1.Length -gt 0 -and $p1 -ceq $p2) { return $p1 }
    Write-Host "empty or mismatch - try again"
  }
}

Write-Host "== collecting OpenCode / OpenChamber config =="
$u = $env:USERPROFILE
Grab "opencode config"           "$u\.config\opencode"         "config\opencode"
Grab "opencode config (roaming)" "$env:APPDATA\opencode"       "config\opencode"
Grab "opencode auth (keys)"      "$u\.local\share\opencode"    "auth\opencode"
Grab "opencode auth (local)"     "$env:LOCALAPPDATA\opencode"   "auth\opencode"
Grab "opencode legacy"           "$u\.opencode"                 "config\opencode-legacy"
$ocFound = $false
foreach ($d in @("$u\.config\openchamber", "$u\.openchamber",
                 "$env:APPDATA\openchamber", "$env:LOCALAPPDATA\openchamber")) {
  if ((Test-Path $d) -and ((Get-ChildItem $d -Force | Measure-Object).Count -gt 0)) {
    Grab "openchamber config" $d "config\openchamber"
    $ocFound = $true
    break
  }
}
if (-not $ocFound) { Write-Host "  [ ] openchamber config  not found (tried .config, .openchamber, AppData)" }

if (-not $found) {
  Write-Host "nothing found to export - is OpenCode/OpenChamber installed for this Windows user?"
  exit 1
}

$zip = Join-Path (Get-Location) "farm-config-$stamp.zip"
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip -Force
$zipSize = (Get-Item $zip).Length
Write-Host ""
Write-Host "bundle: $zip ($zipSize bytes)"

Write-Host ""
Write-Host "Encrypt bundle with a passphrase? (API keys inside) [Y/n]"
$answer = Read-Host "choice"
if ($answer -notmatch "^[Nn]$") {
  $pass = Read-PassphraseTwice
  $salt = New-Object byte[] 8
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes(
    [Text.Encoding]::UTF8.GetBytes($pass), $salt, 10000,
    [Security.Cryptography.HashAlgorithmName]::SHA256)
  $keyiv = $kdf.GetBytes(48)
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Mode = [Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $keyiv[0..31]
  $aes.IV = $keyiv[32..47]
  $plain = [IO.File]::ReadAllBytes($zip)
  $enc = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
  $aes.Dispose()
  $out = New-Object byte[] (16 + $enc.Length)
  [Text.Encoding]::ASCII.GetBytes("Salted__").CopyTo($out, 0)
  $salt.CopyTo($out, 8)
  $enc.CopyTo($out, 16)
  $encFile = "$zip.enc"
  $encName = [IO.Path]::GetFileName($encFile)
  [IO.File]::WriteAllBytes($encFile, $out)
  Remove-Item $zip -Force
  Write-Host ""
  Write-Host "encrypted: $encFile"
  Write-Host ""
  Write-Host "NEXT STEPS:"
  Write-Host "  1) In the Google Cloud console open the web SSH terminal on VM 'agent-farm'"
  Write-Host "     and upload the file $encName (terminal menu -> Upload file)."
  Write-Host "  2) In that terminal run:"
  Write-Host "       curl -fsSL https://muse.ai/files/1360693247123791/1578392640635883/pbil42996f3e24l2al35y0ff/import-farm-config.sh -o /tmp/import.sh"
  Write-Host "       bash /tmp/import.sh ~/$encName"
  Write-Host "     then type your passphrase when asked. Done - services restart themselves."
} else {
  Write-Host ""
  Write-Host "NEXT: transfer $zip to the VM (web SSH upload) and run import-farm-config.sh on it."
}
Remove-Item $work -Recurse -Force
