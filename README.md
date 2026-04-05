# Windows VM Image

Build automation for Windows 11 25H2 disk images targeting Cloud Hypervisor.

- `autounattend.xml` — unattended Windows setup configuration
- `scripts/verify.ps1` + `scripts/remediate.ps1` — post-install verification loop
- `.github/workflows/build.yml` — headless QEMU/KVM build on GitHub Actions
- `docs/build-guide.md` — manual build guide

## Distribution

Built images are published as OCI artifacts to GHCR (not Git LFS):

```
ghcr.io/cmgs/windows:win11-25h2
ghcr.io/cmgs/windows:win11-25h2-<YYYYMMDD>
```

### Pull and reassemble

```bash
# Requires oras CLI (https://oras.land)
oras pull ghcr.io/cmgs/windows:win11-25h2
cat windows-11-25h2.qcow2.*.qcow2.part > windows-11-25h2.qcow2
sha256sum -c SHA256SUMS
qemu-img info windows-11-25h2.qcow2
```

The qcow2 is split into ~1.9 GiB parts so every blob fits comfortably inside the GHCR per-layer limit. The reassemble command is also stored in the manifest annotation `cocoonstack.windows.reassemble`.

## Building

Trigger the **Build Windows qcow2** workflow manually (`workflow_dispatch`). Requires one repository secret:

- `WINDOWS_ISO_URL` — signed download URL for the Windows 11 25H2 ISO (Microsoft licensing prohibits redistribution, so this cannot live in the repo).

Runs on `ubuntu-latest` with KVM. Total runtime ~2h (installer ~1h, verify/reboot/push ~1h). The workflow:

1. Boots QEMU with Secure Boot OVMF + swtpm TPM 2.0
2. Injects Enter keys via the QEMU monitor to defeat the "Press any key to boot from CD" prompt
3. Runs unattended install from `autounattend.xml` (delivered as a third CD-ROM since q35 floppy is not visible to Windows PE)
4. Polls SSH for `C:\install.success` marker
5. Runs `verify.ps1`, reboots, re-verifies, and applies `remediate.ps1` until all checks pass (or 3 attempts)
6. Shuts the VM down cleanly, compresses the qcow2, splits it, and pushes to GHCR via ORAS

## Why GHCR instead of LFS?

- GitHub LFS has a hard 2 GiB per-file limit; a compressed Windows 11 image is ~14 GiB.
- GHCR supports larger blobs, is free for public repos, and speaks a standard protocol (OCI) that maps naturally to a multi-layer "split archive".
- Consumers can pull without extra credentials on public repos.

## Licensing

Microsoft licensing prohibits public distribution of Windows disk images. The GHCR package visibility should be restricted to authorized consumers; this repo only ships the automation code (`autounattend.xml`, scripts, workflow).
