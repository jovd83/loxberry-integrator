#requires -Version 5.1
<#
Build a LoxBerry 3.x sandbox VM on Windows + VirtualBox, fully unattended.

What it does
  1. Installs VirtualBox via winget if missing (one UAC prompt).
  2. Downloads the DietPi VirtualBox x86_64 image (.7z) and extracts the .vmdk.
  3. Converts .vmdk -> .vhd so we can mount the FAT32 /boot partition on
     Windows Home (no Hyper-V required), then writes:
        - a preseeded dietpi.txt (AUTO_SETUP_AUTOMATED=1 + chained custom script)
        - /boot/Automation_Custom_Script.sh -> runs the LoxBerry installer
  4. Registers a VirtualBox VM with 2 vCPU / 2 GB RAM / bridged NIC, attaches
     the prepared disk, and powers it on headless.
  5. Polls until the LoxBerry web UI responds on the LAN, then prints
     credentials and next steps for installing the marstek-cloud plugin.

You can re-run this script. Existing VM is left alone unless -Force is passed.
#>

[CmdletBinding()]
param(
    [string]$VMName       = 'LoxBerry-Sandbox',
    [string]$WorkDir      = "$env:USERPROFILE\loxberry-sandbox",
    [string]$Hostname     = 'loxberry-sandbox',
    [string]$Timezone     = 'Europe/Brussels',
    [string]$Locale       = 'en_US.UTF-8',
    [string]$KeyboardLayout = 'us',
    [string]$DietPiImageUrl = 'https://dietpi.com/downloads/images/DietPi_VirtualBox-UEFI-x86_64-Bookworm.ova.xz',
    [int]$MemoryMB        = 2048,
    [int]$Cpus            = 2,
    [string]$BridgeAdapter,    # autodetected if blank
    [switch]$Force,            # delete + recreate the VM if it already exists
    [switch]$SkipBoot          # prepare disk + register VM but don't power on
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speeds up Invoke-WebRequest

# --- self-elevate (Mount-DiskImage on VHD requires admin) -----------------
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[i] Re-launching elevated (UAC prompt incoming)...' -ForegroundColor Cyan
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } else {
            $argList += "-$k"; $argList += "`"$v`""
        }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

# -------------------------------------------------------------- helpers --
function Info  { param([string]$m) Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok    { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Warn  { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Die   { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; throw $m }

function Find-Exe {
    param([string]$Name, [string[]]$Candidates)
    # Probe the explicit candidate paths first; PS 5.1 has `curl` as an alias
    # for Invoke-WebRequest, so Get-Command would return it with no Source.
    foreach ($p in $Candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Ensure-VirtualBox {
    $vbm = Find-Exe 'VBoxManage' @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
    )
    if ($vbm) { Ok "VirtualBox already installed: $vbm"; return $vbm }
    Info 'VirtualBox not found; installing via winget (you will see a UAC prompt)'
    winget install --id Oracle.VirtualBox -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Die "winget install failed (exit $LASTEXITCODE)" }
    $vbm = Find-Exe 'VBoxManage' @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
    )
    if (-not $vbm) { Die 'VirtualBox install reported success but VBoxManage.exe is missing' }
    Ok "VirtualBox installed: $vbm"
    return $vbm
}

function Ensure-7Zip {
    $sz = Find-Exe '7z' @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    if ($sz) { Ok "7-Zip already installed: $sz"; return $sz }
    Info '7-Zip not found; installing via winget'
    winget install --id 7zip.7zip -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Die "winget install of 7-Zip failed (exit $LASTEXITCODE)" }
    $sz = Find-Exe '7z' @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    if (-not $sz) { Die '7-Zip install reported success but 7z.exe is missing' }
    Ok "7-Zip installed: $sz"
    return $sz
}

function Download-IfMissing {
    param([string]$Url, [string]$Dest)
    if (Test-Path $Dest) {
        $sz = (Get-Item $Dest).Length
        if ($sz -gt 1MB) {
            Ok "Already downloaded: $Dest ($sz bytes)"
            return
        }
        Warn "Partial download at $Dest ($sz bytes); resuming"
    }
    $curl = Find-Exe 'curl' @("$env:SystemRoot\System32\curl.exe")
    if (-not $curl) { Die 'curl.exe not found (expected on Windows 10/11)' }
    Info "Downloading $Url -> $Dest (curl, resumable)"
    $attempts = 0
    while ($true) {
        $attempts++
        & $curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -C - -o $Dest $Url
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempts -ge 5) { Die "curl failed after $attempts attempts (exit $LASTEXITCODE)" }
        Warn "curl exit $LASTEXITCODE; retrying ($attempts/5)"
        Start-Sleep -Seconds (5 * $attempts)
    }
    Ok "Download complete ($((Get-Item $Dest).Length) bytes)"
}

function Extract-7z {
    param([string]$SevenZip, [string]$Archive, [string]$DestDir)
    Info "Extracting $Archive -> $DestDir"
    & $SevenZip x -bd -y "-o$DestDir" $Archive | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "7z extract failed (exit $LASTEXITCODE)" }
    Ok 'Extraction complete'
}

function Pick-BridgeAdapter {
    param([string]$VBoxManage)
    $raw = & $VBoxManage list bridgedifs
    $names = @()
    $current = @{}
    foreach ($line in $raw) {
        if ($line -match '^Name:\s*(.+)$')        { $current.Name   = $Matches[1].Trim() }
        elseif ($line -match '^Status:\s*(.+)$')  { $current.Status = $Matches[1].Trim() }
        elseif ($line -match '^IPAddress:\s*(.+)$') { $current.Ip   = $Matches[1].Trim() }
        elseif ($line -match '^MediumType:\s*(.+)$'){ $current.Media = $Matches[1].Trim() }
        elseif ($line.Trim() -eq '' -and $current.Count -gt 0) {
            $names += [pscustomobject]$current
            $current = @{}
        }
    }
    if ($current.Count -gt 0) { $names += [pscustomobject]$current }
    # Prefer Up + non-loopback IPv4
    $best = $names | Where-Object {
        $_.Status -eq 'Up' -and $_.Ip -and $_.Ip -ne '0.0.0.0' -and $_.Ip -notmatch '^169\.254\.'
    } | Select-Object -First 1
    if (-not $best) { Die 'No bridged adapter with an IPv4 address found. Pass -BridgeAdapter explicitly.' }
    Ok "Bridge adapter: $($best.Name) (IP $($best.Ip))"
    return $best.Name
}

function Ensure-Docker {
    $docker = Find-Exe 'docker' @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe"
    )
    if (-not $docker) { Die 'docker.exe not found. Start Docker Desktop or install it (winget install Docker.DockerDesktop).' }
    # Docker Desktop may be installed but engine not running
    & $docker info --format '{{.OSType}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Die 'Docker CLI is present but the engine is not responding. Start Docker Desktop and retry.' }
    Ok "Docker CLI: $docker"
    return $docker
}

function Patch-ExtImage {
    <#
    Patch the ext4 root partition of a DietPi UEFI x86_64 raw disk image,
    placing dietpi.txt and Automation_Custom_Script.sh under /boot/.
    Runs entirely inside a privileged debian:bookworm container, so we don't
    need ext4 support on the Windows host.
    #>
    param(
        [string]$Docker,
        [string]$RawImagePath,        # absolute Windows path
        [string]$WorkDirPath,         # absolute Windows path (parent dir bind-mounted)
        [string]$DietPiTxtContent,    # full text to write to /boot/dietpi.txt
        [string]$CustomScriptContent  # full text to write to /boot/Automation_Custom_Script.sh
    )

    $stageDir = Join-Path $WorkDirPath 'patch-stage'
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    $dietpiTxtHostFile = Join-Path $stageDir 'dietpi.txt'
    $customHostFile    = Join-Path $stageDir 'Automation_Custom_Script.sh'
    # Normalise to LF
    [System.IO.File]::WriteAllText($dietpiTxtHostFile, ($DietPiTxtContent -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($customHostFile,    ($CustomScriptContent -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    # Relative paths inside the container (work dir bind-mounted at /work)
    $rawRel    = ($RawImagePath -replace [regex]::Escape($WorkDirPath), '').TrimStart('\','/') -replace '\\','/'
    $dietpiRel = "patch-stage/dietpi.txt"
    $customRel = "patch-stage/Automation_Custom_Script.sh"

    $bashTemplate = @'
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y e2fsprogs util-linux parted >/dev/null

RAW=/work/__RAW_REL__
echo "Image: $RAW ($(stat -c %s "$RAW") bytes)"

# Use parted machine-readable output to find partition 2 (ext4 rootfs).
# Format: number:start:end:size:fs:name:flags
INFO=$(parted -m -s "$RAW" unit B print)
echo "parted:"
printf "%s\n" "$INFO"
LINE=$(printf "%s\n" "$INFO" | awk -F: -v n=2 '$1==n {print; exit}')
[ -n "$LINE" ] || { echo "Could not find partition 2"; exit 1; }
START=$(printf "%s" "$LINE" | awk -F: '{print $2}' | tr -d B)
SIZE=$(printf "%s"  "$LINE" | awk -F: '{print $4}' | tr -d B)
echo "Partition 2: start=${START}B size=${SIZE}B"

MNT=$(mktemp -d)
mount -o loop,offset=${START},sizelimit=${SIZE} "$RAW" "$MNT"
echo "Root partition contents (top level):"
ls "$MNT" | head -30
mkdir -p "$MNT/boot"
cp /work/__DIETPI_REL__  "$MNT/boot/dietpi.txt"
cp /work/__CUSTOM_REL__  "$MNT/boot/Automation_Custom_Script.sh"
chmod 0755 "$MNT/boot/Automation_Custom_Script.sh"
sync
echo "After write:"
ls -la "$MNT/boot/dietpi.txt" "$MNT/boot/Automation_Custom_Script.sh"
echo "dietpi.txt content:"
cat "$MNT/boot/dietpi.txt"

umount "$MNT"
rmdir "$MNT"
echo "DONE"
'@
    $bash = $bashTemplate.
        Replace('__RAW_REL__',    $rawRel).
        Replace('__DIETPI_REL__', $dietpiRel).
        Replace('__CUSTOM_REL__', $customRel)

    Info "Patching ext4 rootfs via privileged debian container"
    $winWork = $WorkDirPath -replace '\\','/'
    $dargs = @(
        'run', '--rm', '--privileged',
        '-v', "${winWork}:/work",
        'debian:bookworm',
        'bash', '-c', $bash
    )
    & $Docker @dargs
    if ($LASTEXITCODE -ne 0) { Die "docker patch container exited $LASTEXITCODE" }
    Ok 'ext4 patch complete'
}

function Build-DietPiTxt {
    param([hashtable]$Settings)
    # Emit a minimal dietpi.txt — DietPi tolerates unknown/missing entries and
    # uses defaults for anything not set. We only need the AUTO_SETUP_* keys.
    $lines = foreach ($k in $Settings.Keys) { "$k=$($Settings[$k])" }
    return ($lines -join "`n") + "`n"
}

# -------------------------------------------------------------- main ---

Info "WorkDir: $WorkDir"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$transcript = Join-Path $WorkDir 'build.log'
try { Start-Transcript -Path $transcript -Append -Force | Out-Null } catch { }
Info "Transcript: $transcript"

$VBoxManage = Ensure-VirtualBox
$SevenZip   = Ensure-7Zip

$archive    = Join-Path $WorkDir (Split-Path $DietPiImageUrl -Leaf)            # .ova.xz
$ovaDir     = Join-Path $WorkDir 'dietpi-ova'                                  # holds the .ova
$extractDir = Join-Path $WorkDir 'dietpi-extract'                              # holds the .vmdk + .ovf

Download-IfMissing -Url $DietPiImageUrl -Dest $archive

# Step 1: .ova.xz  ->  .ova (XZ-decompress; 7-Zip handles .xz)
$ovaName = ($archive -replace '\.xz$', '' | Split-Path -Leaf)
$ovaPath = Join-Path $ovaDir $ovaName
if (-not (Test-Path $ovaPath)) {
    New-Item -ItemType Directory -Force -Path $ovaDir | Out-Null
    Info "Decompressing XZ: $archive -> $ovaPath"
    & $SevenZip x -bd -y "-o$ovaDir" $archive | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "7z xz-decompress failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $ovaPath)) { Die "Expected $ovaPath after decompression but it is missing" }
    Ok "OVA ready ($((Get-Item $ovaPath).Length) bytes)"
} else {
    Ok "Already decompressed: $ovaPath"
}

# Step 2: .ova (tar)  ->  .vmdk + .ovf
$srcVmdk = $null
if (Test-Path $extractDir) {
    $srcVmdk = Get-ChildItem -Path $extractDir -Recurse -Include *.vmdk -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $srcVmdk) {
    Extract-7z -SevenZip $SevenZip -Archive $ovaPath -DestDir $extractDir
    $srcVmdk = Get-ChildItem -Path $extractDir -Recurse -Include *.vmdk | Select-Object -First 1
}
if (-not $srcVmdk) { Die "No .vmdk found under $extractDir after OVA extraction" }
Info "Source VMDK: $($srcVmdk.FullName)"

# Step 3: .vmdk -> .raw (so we can losetup + mount ext4 inside Docker)
$diskDir = Join-Path $WorkDir 'vm-disk'
New-Item -ItemType Directory -Force -Path $diskDir | Out-Null
$rawPath = Join-Path $diskDir 'loxberry-sandbox.raw'

if (-not (Test-Path $rawPath)) {
    Info "Cloning VMDK -> RAW: $rawPath"
    # Evict any stale media-registry entry for the source VMDK
    # (e.g. left over from a previous clone). Ignore failure.
    & $VBoxManage closemedium disk $srcVmdk.FullName 2>$null | Out-Null
    & $VBoxManage clonemedium disk $srcVmdk.FullName $rawPath --format RAW
    if ($LASTEXITCODE -ne 0) { Die "VBoxManage clonemedium (RAW) failed (exit $LASTEXITCODE)" }
    & $VBoxManage closemedium disk $rawPath 2>$null | Out-Null
    & $VBoxManage closemedium disk $srcVmdk.FullName 2>$null | Out-Null
    Ok 'RAW image ready'
} else {
    Ok "Reusing existing RAW image: $rawPath"
}

# --- inject dietpi.txt + Automation_Custom_Script.sh via Docker -----------
$Docker = Ensure-Docker

$preseed = @{
    'AUTO_SETUP_AUTOMATED'              = '1'
    'AUTO_SETUP_ACCEPT_LICENSE'         = '1'
    'AUTO_SETUP_NET_HOSTNAME'           = $Hostname
    'AUTO_SETUP_LOCALE'                 = $Locale
    'AUTO_SETUP_KEYBOARD_LAYOUT'        = $KeyboardLayout
    'AUTO_SETUP_TIMEZONE'               = $Timezone
    'AUTO_SETUP_HEADLESS'               = '1'
    'AUTO_SETUP_SSH_SERVER_INDEX'       = '-1'  # Dropbear (default)
    'AUTO_SETUP_GLOBAL_PASSWORD'        = 'loxberry-sandbox'
    'SURVEY_OPTED_IN'                   = '0'
    'AUTO_SETUP_CUSTOM_SCRIPT_EXEC'     = '/boot/Automation_Custom_Script.sh'
    'AUTO_SETUP_NET_ETHERNET_ENABLED'   = '1'
    'AUTO_SETUP_NET_USESTATIC'          = '0'
}
$dietpiTxtContent = Build-DietPiTxt -Settings $preseed

$customScriptSrc = Join-Path $PSScriptRoot 'Automation_Custom_Script.sh'
if (-not (Test-Path $customScriptSrc)) { Die "Missing $customScriptSrc" }
$customScriptContent = Get-Content -LiteralPath $customScriptSrc -Raw

Patch-ExtImage `
    -Docker $Docker `
    -RawImagePath $rawPath `
    -WorkDirPath $WorkDir `
    -DietPiTxtContent $dietpiTxtContent `
    -CustomScriptContent $customScriptContent

# Step 4: .raw -> .vmdk (final VirtualBox-friendly format)
# Use convertfromraw — clonemedium can't read a header-less raw file.
$vmdkPath = Join-Path $diskDir 'loxberry-sandbox.vmdk'
if (Test-Path $vmdkPath) {
    & $VBoxManage closemedium disk $vmdkPath 2>$null | Out-Null
    Remove-Item -Force $vmdkPath
}
Info "Converting patched RAW -> VMDK: $vmdkPath"
& $VBoxManage convertfromraw $rawPath $vmdkPath --format VMDK
if ($LASTEXITCODE -ne 0) { Die "VBoxManage convertfromraw failed (exit $LASTEXITCODE)" }
& $VBoxManage closemedium disk $vmdkPath 2>$null | Out-Null
Ok 'Patched VMDK ready'

# --- create / recreate the VM ---------------------------------------------
$exists = (& $VBoxManage list vms) -match "`"$([regex]::Escape($VMName))`""
if ($exists -and $Force) {
    Warn "VM '$VMName' exists; -Force given, deleting"
    & $VBoxManage controlvm $VMName poweroff 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $VBoxManage unregistervm $VMName --delete | Out-Null
    $exists = $false
}

if ($exists) {
    Ok "VM '$VMName' already exists; re-using"
} else {
    Info "Creating VM '$VMName'"
    & $VBoxManage createvm --name $VMName --ostype Debian_64 --register | Out-Null
    & $VBoxManage modifyvm $VMName `
        --memory $MemoryMB `
        --cpus $Cpus `
        --ioapic on `
        --firmware efi `
        --boot1 disk --boot2 none --boot3 none --boot4 none `
        --rtcuseutc on `
        --audio none `
        --usb off | Out-Null

    if (-not $BridgeAdapter) { $BridgeAdapter = Pick-BridgeAdapter -VBoxManage $VBoxManage }
    & $VBoxManage modifyvm $VMName --nic1 bridged --bridgeadapter1 "$BridgeAdapter" --nictype1 virtio | Out-Null

    & $VBoxManage storagectl $VMName --name SATA --add sata --controller IntelAhci --portcount 2 | Out-Null
    & $VBoxManage storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $vmdkPath | Out-Null
    Ok 'VM created and disk attached'
}

if ($SkipBoot) { Ok 'Skipping power-on as requested (-SkipBoot)'; return }

$state = (& $VBoxManage showvminfo $VMName --machinereadable | Select-String '^VMState=').ToString()
if ($state -notmatch 'running') {
    Info 'Starting VM (headless)'
    & $VBoxManage startvm $VMName --type headless | Out-Null
    Ok 'VM started'
} else {
    Ok 'VM already running'
}

# --- wait for LoxBerry web UI ---------------------------------------------
$target = "http://$Hostname"
Info "Waiting for $target to come up (this can take 1-2 hours: DietPi base setup + LoxBerry installer)..."
$deadline = (Get-Date).AddHours(3)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri $target -TimeoutSec 5 -UseBasicParsing -MaximumRedirection 5
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $ready = $true; break }
    } catch {
        # not up yet
    }
    Start-Sleep -Seconds 30
}

if (-not $ready) {
    Warn "Timed out waiting for $target. The VM is still running; check status with:"
    Warn "  & '$VBoxManage' showvminfo $VMName"
    Warn "  ssh root@$Hostname  (initial password: dietpi; after install: loxberry-sandbox)"
    return
}

Ok "LoxBerry web UI reachable at $target"
Write-Host @"

================================================================================
LoxBerry sandbox is ready.

  Web UI:   $target
  Login:    loxberry / loxberry
  SSH:      ssh loxberry@$Hostname   (password: loxberry-sandbox)
  Root:     SSH disabled by default; use 'sudo -i' from loxberry@

Next steps for the marstek-cloud plugin:
  1. Open $target -> Plugin Install
  2. Upload c:\projects\skills\loxberry-integrator\sandbox\marstek-cloud-0.1.0.zip
  3. Install the MQTT Gateway plugin if not present yet
  4. Open the marstek-cloud plugin page, enter Marstek email + password, Save
  5. Subscribe to 'marstek/#' in MQTT Gateway, watch topics arrive
================================================================================
"@
