# Windows VM Image

Build guide for Windows 11 25H2 targeting Cloud Hypervisor. Uses an `autounattend.xml` for fully unattended installation with zero manual interaction — both locally and in CI.

Two flows share the same automation:

1. **CI**: `.github/workflows/build.yml` runs the full pipeline on `ubuntu-latest` (KVM) and publishes the resulting qcow2 to `ghcr.io/cmgs/windows` via ORAS.
2. **Local**: follow the manual steps below to reproduce the build on any Linux + KVM host.

## Version Requirements

| Component        | Version      | Notes                                                                         |
|------------------|--------------|-------------------------------------------------------------------------------|
| Cloud Hypervisor | **v51+**     | Use [cocoonstack/cloud-hypervisor `dev`][ch-fork] for full Windows support    |
| Firmware         | **patched**  | Use [cocoonstack/rust-hypervisor-firmware `dev`][fw-fork] for ACPI shutdown   |
| virtio-win       | **0.1.285**  | Latest stable; 0.1.240 also works on upstream CH without patches              |
| QEMU             | **≥ 8.x**    | Build host only — production runs on Cloud Hypervisor                         |
| OVMF             | **secboot**  | `OVMF_CODE_4M.secboot.fd` — Win11 requires Secure Boot, see quirk #3          |

With our [CH fork][ch-fork] and [firmware fork][fw-fork], all previously known Windows issues on Cloud Hypervisor are resolved:
- v51 BSOD fixed ([#7849][ch-7849], [PR #7936][ch-7936])
- virtio-win 0.1.285 works ([#7925][ch-7925], ctrl_queue + used_len fix)
- ACPI power-button shutdown works ([firmware#422][fw-422], [firmware PR #423][fw-423])

If using **upstream** (unpatched) Cloud Hypervisor, use v50.2 + virtio-win 0.1.240 + the SSH shutdown workaround.

### Installing patched binaries

Download pre-built binaries from our forks and replace the originals:

```bash
# Cloud Hypervisor (patched: DISCARD fix + virtio-net ctrl_queue fix)
curl -fsSL -o /usr/local/bin/cloud-hypervisor \
  https://github.com/cocoonstack/cloud-hypervisor/releases/download/dev/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor

# CLOUDHV.fd firmware (patched: ACPI power-button / ResetSystem fix)
curl -fsSL -o /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  https://github.com/cocoonstack/rust-hypervisor-firmware/releases/download/dev/hypervisor-fw
```

These URLs are stable — they always point to the latest `dev` branch build.

[ch-fork]: https://github.com/cocoonstack/cloud-hypervisor/tree/dev
[fw-fork]: https://github.com/cocoonstack/rust-hypervisor-firmware/tree/dev
[ch-7849]: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7849
[ch-7925]: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7925
[ch-7936]: https://github.com/cloud-hypervisor/cloud-hypervisor/pull/7936
[fw-422]: https://github.com/cloud-hypervisor/rust-hypervisor-firmware/issues/422
[fw-423]: https://github.com/cloud-hypervisor/rust-hypervisor-firmware/pull/423

## Prerequisites

- Linux host with KVM (`/dev/kvm` accessible)
- Packages: `qemu-system-x86 qemu-utils ovmf swtpm mtools genisoimage openssh-client sshpass netcat-openbsd`
- Windows 11 25H2 ISO (Microsoft licensing prohibits redistribution — obtain a signed link from microsoft.com)
- [virtio-win-0.1.285.iso](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/)

## Quirks worth knowing upfront

Understanding these four points avoids hours of debugging. All four are inlined into the build steps below and encoded in `build.yml`.

### 1. q35 `-cdrom` puts the Windows ISO where OVMF cannot boot from it

The shorthand `-cdrom windows.iso` plus a second `-drive ...,media=cdrom` both land on the q35 AHCI controller, but they collide on ports where OVMF's BdsDxe reports `Not Found` for Boot0001 and the CD never boots. **You must attach each CD-ROM explicitly on a dedicated SATA port**:

```
-drive id=cd0,if=none,file=windows.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd0,bus=ide.0,bootindex=0
-drive id=cd1,if=none,file=virtio-win.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd1,bus=ide.1
```

Each `ide.N` bus on q35's ICH9-AHCI controller only supports 1 unit, so two CD-ROMs need two different buses.

### 2. q35 has no working floppy for Windows PE

The classic "deliver autounattend.xml on a FAT floppy" trick does not work on q35 — the `-drive if=floppy` device is visible to QEMU but Windows PE's driver stack does not enumerate it, so the unattend file is never read, Setup falls to its GUI, and the disk stays at 196K forever while the screen (that you can't see in headless mode) waits for a click.

**Fix**: pack `autounattend.xml` into a tiny ISO and attach it as a third CD-ROM. Windows Setup searches every CD-ROM for `autounattend.xml` at the root, so this works across every machine type:

```bash
genisoimage -o autounattend.iso -J -r autounattend.xml
```

```
-drive id=cd2,if=none,file=autounattend.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd2,bus=ide.2
```

### 3. Windows 11 25H2 refuses to install without Secure Boot

If you use `OVMF_CODE_4M.fd` (non-secboot) to dodge CD-ROM boot issues, the installer reads your autounattend.xml, starts Setup, and then immediately shows:

> This PC doesn't currently meet Windows 11 system requirements.
> The PC must support Secure Boot.

You **must** use the Secure Boot firmware *and* enable SMM:

```
-machine q35,accel=kvm,smm=on
-global driver=cfi.pflash01,property=secure,value=on
-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
-drive if=pflash,format=raw,file=OVMF_VARS.fd
```

The TPM 2.0 swtpm socket is also non-negotiable — Win11 checks for both.

### 4. Windows Boot Manager has "Press any key to boot from CD" even on UEFI

The "Press any key to boot from CD or DVD..." prompt is **not** a firmware prompt — it's inside `bootmgfw.efi` (Windows Boot Manager) that OVMF loads from the ISO. It appears on every CD boot, first install and reboots alike. Microsoft's design is that after install you typically *don't* press a key, so the bootmgr times out in ~5 seconds, returns control to the firmware, and you fall through to the installed disk. The prompt still renders on first boot though, and an unattended ISO has no way to auto-accept it.

In a headless build we have no keyboard, so the serial log shows:

```
BdsDxe: loading Boot0001 "UEFI QEMU DVD-ROM QM00001" from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
BdsDxe: starting Boot0001 "UEFI QEMU DVD-ROM QM00001" from ...
BdsDxe: failed to start Boot0001 ...: Time out
```

The `Time out` is the Windows bootmgr exiting after nobody pressed a key, and OVMF treats that as "this boot entry failed" and moves to the next entry (which is usually the virtio-win CD or PXE — all of which also fail, ending in the EFI Shell).

**Fix**: attach a QEMU monitor, then spray Enter keys into it during the window between OVMF loading bootmgfw.efi and the bootmgr timeout:

```bash
qemu-system-x86_64 ... \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  -daemonize -pidfile qemu.pid

for delay in 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1; do
  sleep $delay
  echo 'sendkey ret' | nc -w 1 -q 1 127.0.0.1 4444
done
```

Fifteen presses from +2s through +17s is enough slack for cold QEMU start + OVMF boot time.

## Build Steps (local)

### 1. Create disk image

```bash
qemu-img create -f qcow2 windows-11-25h2.qcow2 40G
```

### 2. Copy OVMF variables (writable)

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS.fd
```

### 3. Start TPM emulator

```bash
mkdir -p /tmp/mytpm
swtpm socket --tpmstate dir=/tmp/mytpm \
  --ctrl type=unixio,path=/tmp/swtpm-sock \
  --tpm2 --log level=5 &
```

### 4. Pack autounattend.xml into an ISO

See quirk #2 for why this is a CD-ROM and not a floppy:

```bash
genisoimage -o autounattend.iso -J -r autounattend.xml
```

### 5. Launch QEMU

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm,smm=on \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -m 8G -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive id=cd0,if=none,file=windows.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.0,bootindex=0 \
  -drive id=cd1,if=none,file=virtio-win-0.1.285.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd1,bus=ide.1 \
  -drive id=cd2,if=none,file=autounattend.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd2,bus=ide.2 \
  -drive if=none,id=root,file=windows-11-25h2.qcow2,format=qcow2 \
  -device virtio-blk-pci,drive=root,disable-legacy=on \
  -device virtio-net-pci,netdev=mynet0,disable-legacy=on \
  -netdev user,id=mynet0,hostfwd=tcp::2222-:22 \
  -chardev socket,id=chrtpm,path=/tmp/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -display none \
  -serial file:serial.log \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  -daemonize -pidfile qemu.pid
```

Notes on some of the flags:
- `-display none` instead of `-nographic` because `-nographic` is incompatible with `-daemonize`.
- `-serial file:serial.log` lets you `tail -f serial.log` to watch the OVMF / BdsDxe output.
- `hostfwd=tcp::2222-:22` exposes the Windows SSH server on host port 2222 once it's up.

### 6. Defeat "Press any key" (quirk #4)

Run this immediately after the launch step:

```bash
for delay in 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1; do
  sleep $delay
  echo 'sendkey ret' | nc -w 1 -q 1 127.0.0.1 4444
done
```

You can also verify progress at any time with a screenshot:

```bash
echo 'screendump /tmp/screen.ppm' | nc -w 1 -q 1 127.0.0.1 4444
convert /tmp/screen.ppm /tmp/screen.png   # requires imagemagick
```

The Windows installer takes **~30 minutes** to reach OOBE and another ~20-30 minutes for OOBE + FirstLogonCommands. Expect disk growth from 196 K → 7-8 GiB → 15-17 GiB.

### 7. Wait for the install.success marker

The last `FirstLogonCommand` writes `C:\install.success` with a timestamp. Poll over SSH:

```bash
while true; do
  sleep 60
  sshpass -p 'C@c#on160' ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -p 2222 cocoon@localhost \
      'if exist C:\install.success echo READY' 2>/dev/null | grep -q READY && break
  echo "$(date) still waiting, disk=$(du -sh windows-11-25h2.qcow2 | cut -f1)"
done
```

### 8. Verify and remediate

Upload `scripts/verify.ps1` and `scripts/remediate.ps1` to the VM and run the verify → reboot → verify → remediate loop:

```bash
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost "mkdir C:\scripts"
sshpass -p 'C@c#on160' scp $SSH_OPTS -P 2222 scripts/verify.ps1 scripts/remediate.ps1 \
    cocoon@localhost:"C:\scripts\\"

# baseline
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost \
    "powershell -ExecutionPolicy Bypass -File C:\scripts\verify.ps1"

# reboot, verify persistence
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost "shutdown /r /t 5"
# wait ~45 s for SSH to come back
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost \
    "powershell -ExecutionPolicy Bypass -File C:\scripts\verify.ps1"
```

`verify.ps1` checks ~23 things (services, RDP, SSH, WinRM, SAC/EMS, firewall, hibernate, ACPI power button, shutdown optimization, hostname, VirtIO drivers, virtio-win guest tools, EMS-SAC Tools capability, `install.success`). If any check fails, run `scripts/remediate.ps1` — it is idempotent and re-applies all FirstLogonCommands configuration. Reboot and verify again; up to 3 attempts in the workflow.

### 9. Shut down and compress

```bash
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost "shutdown /s /t 10"
# wait for QEMU process to exit, then
qemu-img convert -O qcow2 -c windows-11-25h2.qcow2 windows-11-25h2.qcow2.tmp
mv windows-11-25h2.qcow2.tmp windows-11-25h2.qcow2
```

Typical sizes: ~17 GiB uncompressed → ~14 GiB after `qemu-img convert -c`.

## CI build (GitHub Actions)

`.github/workflows/build.yml` runs the entire flow on `ubuntu-latest` (which has `/dev/kvm` since 2023). Trigger it manually via `workflow_dispatch`:

```bash
gh workflow run build.yml --repo CMGS/windows -f version_tag=win11-25h2
```

### Required secret

- `WINDOWS_ISO_URL` — signed download URL for the Windows 11 25H2 ISO. Microsoft licensing prohibits bundling the ISO into the repo or an artifact, so fetch it at build time.

### Disk space

`ubuntu-latest` has ~14 GiB free by default, which is not enough for `windows.iso` (8 GiB) + `virtio-win.iso` (754 MiB) + a growing qcow2 (up to ~17 GiB). The workflow's first step aggressively removes `dotnet`, `ghc`, `boost`, Android SDK, `azure-cli`, etc. to free ~30 GiB.

### Publishing to GHCR

After verify passes, the qcow2 is compressed with `qemu-img convert -c`, split into ~1.9 GiB parts with `split`, and pushed to GHCR as a single OCI artifact using ORAS:

```bash
oras push "ghcr.io/cmgs/windows:win11-25h2-$(date +%Y%m%d)" \
  --artifact-type "application/vnd.cocoonstack.windows-image.v1+json" \
  --annotation "cocoonstack.windows.reassemble=cat windows-11-25h2.qcow2.*.qcow2.part > windows-11-25h2.qcow2" \
  windows-11-25h2.qcow2.00.qcow2.part:application/vnd.cocoonstack.windows.disk.qcow2.part \
  windows-11-25h2.qcow2.01.qcow2.part:application/vnd.cocoonstack.windows.disk.qcow2.part \
  ... \
  SHA256SUMS:text/plain
```

Each 1.9 GiB part becomes its own layer, well under any GHCR per-blob limit. A moving `win11-25h2` tag is also pushed alongside the dated one so consumers can always pull "the latest good build".

### Consuming the image

```bash
oras pull ghcr.io/cmgs/windows:win11-25h2
cat windows-11-25h2.qcow2.*.qcow2.part > windows-11-25h2.qcow2
sha256sum -c SHA256SUMS
qemu-img info windows-11-25h2.qcow2
```

## autounattend.xml explained

The included [`autounattend.xml`](../autounattend.xml) drives the install across three passes.

### windowsPE pass

- **Keyboard**: US (`InputLocale=0409:00000409`). Nothing else in `Microsoft-Windows-International-Core-WinPE` is set — all other locale fields inherit from the image default, so the same autounattend works for English International, English (US), or any other edition.
- **VirtIO driver injection**: auto-loads drivers from D: and E: (dual drive letter handles varying CD-ROM assignment):
  - `viostor` — virtio storage controller (required for Setup to see the disk)
  - `NetKVM` — virtio network adapter
  - `Balloon` — virtio memory balloon
  - Both `Win11/amd64/{driver}` (attestation layout) and `{driver}/w11/amd64` (standard) paths are searched.
- **Disk partitioning**: wipes Disk 0, creates EFI (100 MB) + MSR (16 MB) + Windows (remaining, NTFS, C:).
- **Image**: `ImageIndex=6` (Windows 11 Pro).
- **Product key**: `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (generic install key, not activation).

### specialize pass

- **BypassNRO**: registry write to skip Win11 mandatory network + Microsoft account during OOBE.
- **ComputerName**: `COCOON-VM` (also re-applied in FirstLogonCommands via `Rename-Computer` because 25H2 sometimes drops this).
- **TimeZone**: Pacific Standard Time.
- **Keyboard**: US (same `InputLocale` only).

### oobeSystem pass

- **International-Core**: `InputLocale=0409:00000409` only. The `Microsoft-Windows-International-Core` component has to be present here for Windows 11 25H2 OOBE to skip the country / keyboard selection screens, but we deliberately do not pin `SystemLocale`/`UILanguage`/`UserLocale` so the image default wins.
- **OOBE**: hides EULA, online account, wireless setup.
- **User account**: local admin `cocoon` with auto-logon (password base64-encoded in XML).
- **FirstLogonCommands**: 26 commands, see table below.

| Order  | Action | Notes |
|--------|--------|-------|
| 1-2    | **RDP** | `fDenyTSConnections=0` + Enable-NetFirewallRule |
| 3-4    | **SSH** | `Add-WindowsCapability OpenSSH.Server`, auto-start, firewall rule |
| 5      | **ICMP** | Allow ping |
| 6      | **Firewall** | Disable all profiles (dev/test environment) |
| 7      | **Hibernate** | `powercfg /h off` |
| 8-10   | **SAC / EMS** | `bcdedit /emssettings emsport:1 emsbaudrate:115200`, `/ems on`, `/bootems on` |
| 11     | **TermService** | Set to auto-start |
| 12     | **EMS-SAC Tools** | `Add-WindowsCapability Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0` — wrapped in `Start-Job` + `Wait-Job -Timeout 1200` so a hung FoD download from Windows Update cannot block the rest of the sequence indefinitely |
| 13     | **Network profile** | Set to Private (required before WinRM AllowUnencrypted) |
| 14-17  | **WinRM** | Enable PS Remoting, AllowUnencrypted, Basic auth, firewall on 5985 |
| 18     | **Hostname** | Force `Rename-Computer` to `COCOON-VM` (specialize ComputerName unreliable on 25H2) |
| 19     | **virtio-win guest tools** | Silent install `virtio-win-guest-tools.exe /S` from CD-ROM — installs drivers + QEMU Guest Agent + spice agent in one shot |
| 20-22  | **ACPI power button = Shut down** | Set PBUTTONACTION=3 for AC + DC power schemes |
| 23-24  | **Shutdown optimization** | `WaitToKillServiceTimeout=5000`, `DisableShutdownNamedPipeCheck=1` |
| 25     | **Shutdown without logon** | Allow remote `shutdown /s /t 0` with no user logged in |
| 26     | **Install marker** | `cmd /c "echo %date% %time% > C:\install.success"` |

## Post-install verification checklist

`scripts/verify.ps1` covers every row in the table above. For a manual spot check:

```powershell
# Services
Get-Service sshd, TermService, QEMU-GA | Select-Object Name, Status, StartType

# RDP
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections   # 0

# SSH / WinRM ports
Test-NetConnection localhost -Port 22
Test-NetConnection localhost -Port 5985

# WinRM config
winrm get winrm/config/service | Select-String "AllowUnencrypted"
winrm get winrm/config/service/auth | Select-String "Basic"

# EMS
bcdedit /enum | Select-String "ems"

# Firewall off
Get-NetFirewallProfile | Select-Object Name, Enabled

# ACPI power button
powercfg /query SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION | Select-String "Current.*Setting"    # 0x00000003

# Hostname
hostname                                                                                         # COCOON-VM

# VirtIO drivers (minimum 2: viostor + NetKVM; Balloon only if host exposes virtio-balloon)
Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'VirtIO' } | Select-Object DeviceName

# virtio-win guest tools
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -match 'Virtio-win' }

# EMS-SAC Tools capability
Get-WindowsCapability -Online -Name "Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0" | Select-Object State

# Install marker
Test-Path C:\install.success
Get-Content C:\install.success
```

## Post-clone networking

- **DHCP networks**: no action needed, Windows DHCP client auto-configures on new NIC.
- **Static IP**: configure via SAC serial console:
  ```
  cmd
  ch -si 1
  netsh interface ip set address "Ethernet" static <IP> <MASK> <GW>
  ```
  See the [Cloud Hypervisor Windows documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/windows.md) for details.
