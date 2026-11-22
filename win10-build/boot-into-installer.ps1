<#
.SYNOPSIS
  Reboot Windows into the NixOS installer via a one-shot firmware (BootNext) entry.

.DESCRIPTION
  Stages the installer payload onto the ESP, registers systemd-boot as a
  one-shot firmware boot entry, and reboots. The one-shot entry means the
  NEXT boot after this one (or any failure before it) falls back to the
  normal firmware order, i.e. Windows Boot Manager. The Windows disk is
  never modified; disko wipes it deliberately in a later phase.

  Payload expected in $PayloadDir:
    bzImage              kernel from the kexec-installer tarball (EFI stub)
    initrd               installer initrd (with ssh/authorized_keys appended)
    cmdline.txt          single line: init=... zswap... console=ttyS0,115200
    systemd-bootx64.efi  from nixpkgs: systemd/lib/systemd/boot/efi/

  ESP layout created:
    \EFI\NixOS\{bzImage,initrd}
    \EFI\systemd\systemd-bootx64.efi
    \loader\loader.conf                (timeout 0, default installer)
    \loader\entries\installer.conf     (linux/initrd/options)
#>
param(
    [string]$PayloadDir = "C:\Users\Administrator\delivery\payload",
    [string]$EspLetter = "S:",
    [string]$EntryDescription = "nixos-installer"
)

$ErrorActionPreference = "Stop"

# --- 0. BitLocker: defensive, no-op on the Packer image (BitLocker absent),
#        real-hardware safety net: boot-chain changes alter TPM measurements.
$bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq "On") {
    Suspend-BitLocker -MountPoint "C:" -RebootCount 1
    Write-Host "BitLocker suspended for one reboot"
}

# --- 1. Attach the ESP (FAT32; firmware cannot read NTFS)
mountvol $EspLetter /S
if (-not (Test-Path "$EspLetter\EFI\Microsoft\Boot\bootmgfw.efi")) {
    throw "$EspLetter does not look like the ESP (bootmgfw.efi not found)"
}

# --- 2. Stage payload on the ESP
$nixosDir = "$EspLetter\EFI\NixOS"
New-Item -ItemType Directory -Force -Path $nixosDir | Out-Null
Copy-Item "$PayloadDir\bzImage" "$nixosDir\bzImage" -Force
Copy-Item "$PayloadDir\initrd"  "$nixosDir\initrd"  -Force

$bootDir = "$EspLetter\EFI\systemd"
New-Item -ItemType Directory -Force -Path $bootDir | Out-Null
Copy-Item "$PayloadDir\systemd-bootx64.efi" "$bootDir\systemd-bootx64.efi" -Force

# --- 3. systemd-boot config: single entry, zero timeout, silent
$entriesDir = "$EspLetter\loader\entries"
New-Item -ItemType Directory -Force -Path $entriesDir | Out-Null
$cmdline = (Get-Content "$PayloadDir\cmdline.txt" -Raw).Trim()
@"
title   NixOS installer
version dummy
linux   /EFI/NixOS/bzImage
initrd  /EFI/NixOS/initrd
options $cmdline
"@ | Set-Content -Path "$entriesDir\installer.conf" -Encoding ascii
@"
timeout 0
default installer
"@ | Set-Content -Path "$EspLetter\loader\loader.conf" -Encoding ascii

# --- 4. Idempotency: delete any previous firmware entry with our description
$current = $null
$stale = @()
foreach ($line in (bcdedit /enum firmware)) {
    if ($line -match '^\s*identifier\s+({[0-9a-fA-F-]+})\s*$') {
        $current = $Matches[1]
    }
    elseif ($current -and $line -match ('^\s*description\s+' + [regex]::Escape($EntryDescription) + '\s*$')) {
        $stale += $current
    }
}
foreach ($id in $stale) {
    bcdedit /delete $id | Out-Null
}
if ($stale.Count -gt 0) {
    Write-Host "Deleted $($stale.Count) stale entry/entries"
}

# --- 5. Create the firmware entry: copy of Windows Boot Manager entry,
#        repointed at systemd-boot on the same ESP.
$copy = bcdedit /copy "{bootmgr}" /d $EntryDescription
$entry = ($copy | Select-String -Pattern '{[0-9a-fA-F-]+}').Matches[0].Value
bcdedit /set $entry path "\EFI\systemd\systemd-bootx64.efi" | Out-Null
Write-Host "Firmware entry $entry -> \EFI\systemd\systemd-bootx64.efi"

# --- 6. One-shot: BootNext boots the installer exactly once, then the
#        firmware order (Windows first) applies again. This IS the fallback.
bcdedit /set "{fwbootmgr}" bootsequence $entry | Out-Null

# --- 7. Dismount ESP and reboot
mountvol $EspLetter /D
Write-Host "Rebooting into the NixOS installer in 5 seconds..."
shutdown /r /t 5
