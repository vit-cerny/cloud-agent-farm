<#
  Import-OpenChamberFull.ps1 - restore an openchamber-full bundle on Windows.
  Run in the folder with the bundle:
    powershell -ExecutionPolicy Bypass -File Import-OpenChamberFull.ps1
  Optional: -Bundle <path> -NoBackup
  Backs up current config to ~/.config/*-backup-<date>, then restores.
  ponytail: stdlib only.
#>
param([string]$Bundle = "", [switch]$NoBackup)
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
if ([string]::IsNullOrWhiteSpace($Bundle)) {
  $cand = Get-ChildItem $here -Filter "openchamber-full-*.zip*" | Sort-Object Name -Descending | Select-Object -First 1
  if ($cand -eq $null) { Write-Host "no openchamber-full-*.zip[.enc] found next to this script."; exit 1 }
  $Bundle = $cand.FullName
}
if ($Bundle -like "*.enc") {
  $s = Read-Host "Bundle passphrase" -AsSecureString
  $pass = (New-Object PSCredential("x", $s)).GetNetworkCredential().Password
  $raw = [IO.File]::ReadAllBytes($Bundle)
  $salt = $raw[8..15]
  $ct = New-Object byte[] ($raw.Length - 16)
  [Array]::Copy($raw, 16, $ct, 0, $ct.Length)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes([Text.Encoding]::UTF8.GetBytes($pass), $salt, 10000, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $keyiv = $kdf.GetBytes(48)
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Mode = [Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $keyiv[0..31]; $aes.IV = $keyiv[32..47]
  $plain = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
  $aes.Dispose(); $pass = $null
  $Bundle = $Bundle -replace "\.enc$", ""
  [IO.File]::WriteAllBytes($Bundle, $plain)
  Write-Host "decrypted: $Bundle"
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("oc-restore-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $tmp | Out-Null
Expand-Archive -Path $Bundle -DestinationPath $tmp -Force
$u = $env:USERPROFILE
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
function Restore-Dir($sub, $target) {
  $src = Join-Path $tmp $sub
  if (!(Test-Path $src)) { Write-Host "  [ ] $sub (not in bundle)"; return }
  if ((Test-Path $target) -and (-not $NoBackup)) {
    $bak = "$target-backup-$stamp"
    Copy-Item $target $bak -Recurse -Force
    Write-Host "  [backup] $target -> $bak"
  }
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  Copy-Item (Join-Path $src "*") $target -Recurse -Force
  Write-Host "  [+] $target"
}
Write-Host "== restoring =="
Restore-Dir "config\opencode" "$u\.config\opencode"
Restore-Dir "config\openchamber" "$u\.config\openchamber"
$share = Join-Path $tmp "auth\opencode-share\auth.json"
if (Test-Path $share) {
  $t = "$u\.local\share\opencode"
  New-Item -ItemType Directory -Path $t -Force | Out-Null
  Copy-Item $share (Join-Path $t "auth.json") -Force
  Write-Host "  [+] auth.json -> $t"
}
$db = Join-Path $tmp "auth\opencode-share\opencode.db"
if (Test-Path $db) {
  $t = "$u\.local\share\opencode"
  New-Item -ItemType Directory -Path $t -Force | Out-Null
  Copy-Item $db (Join-Path $t "opencode.db") -Force
  Write-Host "  [+] opencode.db -> $t"
}
Remove-Item $tmp -Recurse -Force
Write-Host "DONE. Restart OpenChamber / opencode. Old config is in *-backup-$stamp folders."
