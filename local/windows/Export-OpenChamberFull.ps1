<#
  Export-OpenChamberFull.ps1 - one-file clone of your OpenCode + OpenChamber setup.
  Run: powershell -ExecutionPolicy Bypass -File Export-OpenChamberFull.ps1
  Out: openchamber-full-<date>.zip[.enc] next to the script.
  Copy that ONE file to the other computer, run Import-OpenChamberFull.ps1 there. Done.
  ponytail: stdlib only, excludes junk (node_modules/logs/run/backups/caches).
#>
param([switch]$NoEncrypt, [string]$OutDir = "", [switch]$IncludeHistory)
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $here }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work = Join-Path ([IO.Path]::GetTempPath()) "oc-full-$stamp"
New-Item -ItemType Directory -Path $work | Out-Null
$log = @()

function Copy-Filtered($src, $destSub) {
  $dest = Join-Path $work $destSub
  if (!(Test-Path $src)) { $log += "MISS $destSub <- $src"; return 0 }
  $n = 0
  $items = Get-ChildItem $src -Force -ErrorAction SilentlyContinue
  foreach ($it in $items) {
    $name = $it.Name
    if ($name -eq "node_modules" -or $name -eq "logs" -or $name -eq "run" -or $name -eq ".git") { continue }
    if ($name -like "*.bak.*" -or $name -like "*.backup" -or $name -eq "opencode.db-shm" -or $name -eq "opencode.db-wal") { continue }
    if ($it.PSIsContainer) {
      $sub = Join-Path $dest $name
      New-Item -ItemType Directory -Path $sub -Force | Out-Null
      Copy-Item (Join-Path $it.FullName "*") $sub -Recurse -Force -ErrorAction SilentlyContinue
    } else {
      if ($name -like "*.log") { continue }
      New-Item -ItemType Directory -Path $dest -Force | Out-Null
      Copy-Item $it.FullName $dest -Force
    }
    $n++
  }
  $log += "OK $destSub ($n top-level items <- $src)"
  return $n
}

$u = $env:USERPROFILE
Write-Host "== collecting =="
$total = 0
$total += Copy-Filtered "$u\.config\opencode" "config\opencode"
$total += Copy-Filtered "$u\.config\openchamber" "config\openchamber"
$total += Copy-Filtered "$env:APPDATA\opencode" "config\opencode-roaming"
# NOTE: $u\.opencode (legacy) skipped - old install with 90MB exe, not needed.
$authSrc = Join-Path $u ".local\share\opencode\auth.json"
if (Test-Path $authSrc) {
  $ad = Join-Path $work "auth\opencode-share"
  New-Item -ItemType Directory -Path $ad -Force | Out-Null
  Copy-Item $authSrc $ad -Force
  $log += "OK auth\opencode-share\auth.json (API keys)"
  $total++
} else { $log += "MISS auth.json" }
if ($IncludeHistory) {
  $dbSrc = Join-Path $u ".local\share\opencode\opencode.db"
  if (Test-Path $dbSrc) {
    Copy-Item $dbSrc (Join-Path $work "auth\opencode-share\opencode.db") -Force
    $log += "OK opencode.db (chat history, large)"
    $total++
  }
} else { $log += "SKIP opencode.db (chat history, 1GB+) - use -IncludeHistory to add it" }
if ($total -eq 0) { Write-Host "nothing found - is OpenCode installed for this user?"; exit 1 }
foreach ($l in $log) { Write-Host "  [+] $l" }
Get-ChildItem $work -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*.bak.*" -or $_.Name -like "*.backup" -or $_.Name -like "*.log" -or $_.Name -eq "package-lock.json" -or $_.Name -like "*.exe" } | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $work "config\opencode\node_modules") -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $work -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "__pycache__" -or $_.Name -eq "bin" -and $_.FullName -like "*opencode-legacy*" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$manifest = "stamp=$stamp`r`nuser=$env:USERNAME`r`ncomputer=$env:COMPUTERNAME`r`n" + ($log -join "`r`n") + "`r`n"
[IO.File]::WriteAllText((Join-Path $work "MANIFEST.txt"), $manifest, [Text.Encoding]::ASCII)

$zip = Join-Path $OutDir "openchamber-full-$stamp.zip"
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip -Force
Write-Host "bundle: $zip ($((Get-Item $zip).Length) bytes)"

if (-not $NoEncrypt) {
  Write-Host ""
  Write-Host "Encrypt bundle with a passphrase? (auth.json has API keys) [Y/n]"
  $answer = Read-Host "choice"
  if ($answer -notmatch "^[Nn]$") {
    $s1 = Read-Host "Passphrase" -AsSecureString
    $s2 = Read-Host "Repeat passphrase" -AsSecureString
    $p1 = (New-Object PSCredential("x", $s1)).GetNetworkCredential().Password
    $p2 = (New-Object PSCredential("x", $s2)).GetNetworkCredential().Password
    if ($p1.Length -eq 0 -or $p1 -cne $p2) { Write-Host "empty or mismatch - leaving unencrypted"; }
    else {
      $salt = New-Object byte[] 8
      [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
      $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes([Text.Encoding]::UTF8.GetBytes($p1), $salt, 10000, [Security.Cryptography.HashAlgorithmName]::SHA256)
      $keyiv = $kdf.GetBytes(48)
      $aes = [Security.Cryptography.Aes]::Create()
      $aes.Mode = [Security.Cryptography.CipherMode]::CBC
      $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
      $aes.Key = $keyiv[0..31]; $aes.IV = $keyiv[32..47]
      $plain = [IO.File]::ReadAllBytes($zip)
      $enc = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
      $aes.Dispose()
      $out = New-Object byte[] (16 + $enc.Length)
      [Text.Encoding]::ASCII.GetBytes("Salted__").CopyTo($out, 0)
      $salt.CopyTo($out, 8); $enc.CopyTo($out, 16)
      $encFile = "$zip.enc"
      [IO.File]::WriteAllBytes($encFile, $out)
      Remove-Item $zip -Force
      $zip = $encFile
      Write-Host "encrypted: $zip"
      Write-Host "On the other computer: bash import-openchamber-full.sh $(([IO.Path]::GetFileName($zip)))  OR  Import-OpenChamberFull.ps1, then type passphrase."
    }
    $p1 = $null; $p2 = $null
  }
}
Remove-Item $work -Recurse -Force
Write-Host ""
Write-Host "NEXT: copy this ONE file to the other computer and run the matching import script."
Write-Host "  Windows target: powershell -ExecutionPolicy Bypass -File Import-OpenChamberFull.ps1"
Write-Host "  Linux target:   bash import-openchamber-full.sh <bundle>"
