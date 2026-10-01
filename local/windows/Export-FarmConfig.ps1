<#
  Export-FarmConfig.ps1 - export your local OpenCode/OpenChamber/Antigravity setup
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
$script:found = $false

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

Write-Host "== collecting OpenCode / OpenChamber / Antigravity config =="
$u = $env:USERPROFILE
Grab "opencode config"              "$u\.config\opencode"          "config\opencode"
Grab "opencode config (roaming)"    "$env:APPDATA\opencode"        "config\opencode"
Grab "opencode auth (keys)"         "$u\.local\share\opencode"     "auth\opencode"
Grab "opencode auth (local)"        "$env:LOCALAPPDATA\opencode"   "auth\opencode"
Grab "opencode legacy"              "$u\.opencode"                 "config\opencode-legacy"
Grab "antigravity config"           "$u\.antigravity"               "config\antigravity"
Grab "antigravity config (roaming)" "$env:APPDATA\Antigravity"      "config\antigravity"
Grab "antigravity CLI (agy)"       "$u\.gemini"                      "config\antigravity-cli"
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

Write-Host ""
Write-Host "Anything else to include? (e.g. a folder with your own skills or tools)"
Write-Host "Paste a folder path, or just press Enter to continue."
while ($true) {
  $extra = Read-Host "extra folder (empty = done)"
  if ([string]::IsNullOrWhiteSpace($extra)) { break }
  $extra = $extra.Trim().Trim('"')
  if (Test-Path $extra) {
    $name = Split-Path $extra -Leaf
    Grab "extra: $name" $extra "custom\$name"
  } else {
    Write-Host "  not found: $extra"
  }
}

if (-not $script:found) {
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
  Write-Host "NEXT STEPS (about 2 minutes):"
  Write-Host "  1) Upload $encName to the farm: open http://YOUR_VM_IP:8080"
  Write-Host "     in your browser (file manager, the password you already have)"
  Write-Host "     and upload the file into the main folder."
  Write-Host "  2) In the Google Cloud Console open the web SSH terminal on VM"
  Write-Host "     'agent-farm' and run this one command:"
  Write-Host "       sudo -u farm bash /home/farm/agent-farm/bin/import-farm-config.sh"
  Write-Host "     then type your passphrase when asked. Done - services restart"
  Write-Host "     themselves and your settings, MCPs, skills and keys are live."
} else {
  Write-Host ""
  Write-Host "NEXT: upload $zip to the farm file manager (http://YOUR_VM_IP:8080),"
  Write-Host "then in web SSH run:"
  Write-Host "  sudo -u farm bash /home/farm/agent-farm/bin/import-farm-config.sh <file>"
}
Remove-Item $work -Recurse -Force
