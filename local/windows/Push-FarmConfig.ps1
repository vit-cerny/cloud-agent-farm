<#
  Push-FarmConfig.ps1 — put your ENTIRE local setup onto your 24/7 farm VM.
  No SSH key needed.

  Grabs: OpenCode + OpenChamber + Antigravity + Antigravity CLI (agy)
         settings, models, MCP servers, skills, agents, API keys —
         plus any extra folders you choose (your own skills, tools...).

  RUN:
    powershell -ExecutionPolicy Bypass -File Push-FarmConfig.ps1

  What it does:
    1) collects your local configs
    2) encrypts everything with AES-256 (passphrase only you know, asked twice)
    3) uploads to the VM through the file manager (asks your Filebrowser password)
    4) deletes the local bundle — nothing unencrypted ever leaves your PC

  Then ONE command from you in the VM's web terminal finishes it:
    Google Cloud Console > Compute Engine > click SSH on "agent-farm",
    paste:  sudo -u farm bash /home/farm/agent-farm/bin/import-farm-config.sh
    and type your bundle passphrase when asked. Done.
#>
$ErrorActionPreference = "Stop"

$FB        = "http://YOUR_VM_IP:8080"
$VM_IMPORT = "/home/farm/agent-farm/bin/import-farm-config.sh"

# ---------- 1) collect ----------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tmp   = [IO.Path]::GetTempPath()
$work  = Join-Path $tmp "farm-config-$stamp"
New-Item -ItemType Directory -Path $work | Out-Null
$script:found = $false

function Grab($label, $src, $destSub) {
  if ((Test-Path $src) -and ((Get-ChildItem $src -Force | Measure-Object).Count -gt 0)) {
    $dest = Join-Path $work $destSub
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $src "*") $dest -Recurse -Force
    Write-Host "  [+] $label"
    $script:found = $true
  } else {
    Write-Host "  [ ] $label (not found)"
  }
}

Write-Host "== collecting your local configs =="
$u = $env:USERPROFILE
Grab "opencode config"              "$u\.config\opencode"        "config\opencode"
Grab "opencode config (roaming)"    "$env:APPDATA\opencode"      "config\opencode"
Grab "opencode auth (keys)"         "$u\.local\share\opencode"   "auth\opencode"
Grab "opencode auth (local)"        "$env:LOCALAPPDATA\opencode" "auth\opencode"
Grab "opencode legacy"              "$u\.opencode"               "config\opencode-legacy"
Grab "antigravity config"           "$u\.antigravity"            "config\antigravity"
Grab "antigravity config (roaming)" "$env:APPDATA\Antigravity"   "config\antigravity"
Grab "antigravity CLI (agy)"        "$u\.gemini"                 "config\antigravity-cli"
$ocFound = $false
foreach ($d in @("$u\.config\openchamber", "$u\.openchamber",
                 "$env:APPDATA\openchamber", "$env:LOCALAPPDATA\openchamber")) {
  if ((Test-Path $d) -and ((Get-ChildItem $d -Force | Measure-Object).Count -gt 0)) {
    Grab "openchamber config" $d "config\openchamber"
    $ocFound = $true
    break
  }
}
if (-not $ocFound) { Write-Host "  [ ] openchamber config (not found)" }

Write-Host ""
Write-Host "Anything else to include? (a folder with your own skills, tools, projects...)"
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
if (-not $script:found) { Write-Host "nothing found to sync."; exit 1 }

# ---------- 2) encrypt (passphrase only you know) ----------
function Read-PassphraseTwice {
  while ($true) {
    $s1 = Read-Host "Choose a bundle passphrase (only you will know it)" -AsSecureString
    $s2 = Read-Host "Repeat bundle passphrase" -AsSecureString
    $p1 = (New-Object PSCredential("x", $s1)).GetNetworkCredential().Password
    $p2 = (New-Object PSCredential("x", $s2)).GetNetworkCredential().Password
    if ($p1.Length -ge 8 -and $p1 -ceq $p2) { return $p1 }
    Write-Host "empty, shorter than 8 chars, or mismatch - try again"
  }
}
$zip = Join-Path $tmp "farm-config-$stamp.zip"
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip -Force
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
$encName = "farm-config-$stamp.zip.enc"
$encFile = Join-Path $tmp $encName
[IO.File]::WriteAllBytes($encFile, $out)
Remove-Item $zip -Force
$pass = $null
Write-Host "  encrypted: $encName"

# ---------- 3) upload through the file manager (no SSH key needed) ----------
Write-Host "== uploading to the VM =="
$fbCred = Read-Host "Your file manager password" -AsSecureString
$fbPass = (New-Object PSCredential("x", $fbCred)).GetNetworkCredential().Password
try {
  $token = Invoke-RestMethod -Uri "$FB/api/login" -Method Post `
    -ContentType "application/json" `
    -Body (@{username = "admin"; password = $fbPass} | ConvertTo-Json)
} catch {
  Write-Host "file manager login failed: $($_.Exception.Message)"
  exit 1
}
$fbPass = $null
if ([string]::IsNullOrWhiteSpace($token)) { Write-Host "file manager login failed (empty token)"; exit 1 }
Write-Host "  logged in"
try {
  Invoke-RestMethod -Uri "$FB/api/resources/$encName" -Method Post `
    -Headers @{"X-Auth" = $token} -InFile $encFile `
    -ContentType "application/octet-stream" | Out-Null
  Invoke-RestMethod -Uri "$FB/api/resources/$encName" -Method Get `
    -Headers @{"X-Auth" = $token} | Out-Null
} catch {
  Write-Host "upload failed: $($_.Exception.Message)"
  exit 1
}
Write-Host "  uploaded: $encName (verified on the VM)"

# ---------- 4) cleanup ----------
Remove-Item $encFile -Force
Remove-Item $work -Recurse -Force
Write-Host "  local bundle deleted"

Write-Host ""
Write-Host "UPLOAD COMPLETE. One last step, in the VM's web terminal:"
Write-Host "  1) open https://console.cloud.google.com/compute/instances"
Write-Host "     and click SSH on the 'agent-farm' VM (a terminal opens in your browser)"
Write-Host "  2) paste this command:"
Write-Host ""
Write-Host "     sudo -u farm bash $VM_IMPORT"
Write-Host ""
Write-Host "  3) type your bundle passphrase when asked. Done."
Write-Host ""
Write-Host "Tell Muse when it says HOTOVO - she will verify your MCPs and runtimes."
