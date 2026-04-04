# Windows Image Build Staging

This repository is a staging area for the Windows image build materials extracted from `../cocoonv2/os-image/windows`.

Right now it contains only the pieces we already have and need to review before wiring up automation:

- `autounattend.xml`: unattended Windows setup configuration
- `docs/build-guide.md`: the current manual build guide copied from Cocoon

Not added yet:

- GitHub Actions workflow
- build/release scripts
- release manifest and split-upload helpers
- any ISO, firmware, or disk image artifacts

Recommended next step after review:

1. Add a self-hosted KVM workflow to build the qcow2 image.
2. Split the resulting qcow2 into sub-2 GiB parts.
3. Publish those parts to GitHub Releases with checksums and a small manifest.
