#!/usr/bin/env python3
"""Verify the base64-encoded PowerShell wrappers in autounattend.xml decode
to a here-string body byte-for-byte matching the corresponding standalone
script in scripts/. The base64 in autounattend Orders 53 / 54 is a self-
extracting wrapper that drops the body to disk at firstboot; if the two
sources drift, images silently install the old version.

To regenerate a base64 block after editing the standalone .ps1, run this
script in --regen mode (TODO: not yet implemented; for now, edit by hand
using the recipe below).

Encoding recipe (matches autounattend.xml Order 53/54 format):

    wrapper = f'''$content = @'
{ps1_body}
'@
... wrapper body that writes $content to disk and invokes it ...
'''
    base64.b64encode(wrapper.encode('utf-16-le')).decode('ascii')

Run from repo root: python3 scripts/check-base64-drift.py
"""

import base64
import re
import sys
from pathlib import Path

PAIRS = [
    (53, 'scripts/install-cocoon-agent-bootstrap.ps1'),
    (54, 'scripts/cocoon-nic-autoheal.ps1'),
]


def check_pair(autounattend: str, order: int, ps1_path: str) -> tuple[bool, str]:
    pattern = (
        rf'<Order>{order}</Order><CommandLine>powershell\.exe -NoProfile '
        rf'-EncodedCommand ([^<]+)</CommandLine>'
    )
    m = re.search(pattern, autounattend)
    if not m:
        return False, f'Order {order}: <Order>...</Order> not found in autounattend.xml'
    decoded = base64.b64decode(m.group(1)).decode('utf-16-le')
    inner = re.search(r"@'\n(.*?)\n'@", decoded, re.DOTALL)
    if not inner:
        return False, f'Order {order}: single-quoted here-string body not found in decoded wrapper'
    embedded = inner.group(1).rstrip()
    standalone = Path(ps1_path).read_text().rstrip()
    if embedded == standalone:
        return True, f'OK Order {order} matches {ps1_path}'
    return False, (
        f'Order {order} drift: decoded base64 body does not match {ps1_path}\n'
        f'  re-encode the wrapper from the standalone .ps1 (see this script header)'
    )


def main() -> int:
    autounattend = Path('autounattend.xml').read_text()
    failures = 0
    for order, ps1_path in PAIRS:
        ok, msg = check_pair(autounattend, order, ps1_path)
        print(msg if ok else f'FAIL: {msg}', file=sys.stderr if not ok else sys.stdout)
        if not ok:
            failures += 1
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
