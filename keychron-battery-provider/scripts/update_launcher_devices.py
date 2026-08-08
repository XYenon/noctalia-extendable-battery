#!/usr/bin/env python3
"""Download Keychron Launcher static device definitions into data/launcher-devices.json.

Launcher (launcher.keychron.cn) serves per-device UI JSON at:

  https://launcher.keychron.cn/static/device/{vpid}/json/v3.json

where vpid = (vid << 16) | pid  (same as WebHID vendorProductId).

Each file typically contains:
  { "name": "Keychron M6 4K", "type": "mouse", "keys": [...], ... }

Usage:
  python3 scripts/update_launcher_devices.py
  python3 scripts/update_launcher_devices.py --quick
  python3 scripts/update_launcher_devices.py --out data/launcher-devices.json
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

KEYCHRON_VID = 0x3434

STATIC_BASES = (
    "https://launcher.keychron.cn/static/device/{vpid}/json/v3.json",
    "https://launcher.keychron.cn/static/device/{vpid}/json/v2.json",
    "https://launcher.keychron.com/static/device/{vpid}/json/v3.json",
    "https://launcher.keychron.com/static/device/{vpid}/json/v2.json",
)

# PID ranges known to host Launcher device definitions.
# Extend as needed; --full widens some bands.
DEFAULT_RANGES = [
    (0x0600, 0x06A0),
    (0x0700, 0x07D0),
    (0x0800, 0x08A0),
    (0x0900, 0x09A0),
    (0x0A00, 0x0A80),
    (0x0B00, 0x0B80),
    (0x0C00, 0x0C40),
    (0xB000, 0xB080),
    (0xD000, 0xD0C0),
]

FULL_RANGES = [
    (0x0500, 0x0D00),
    (0xA000, 0xA200),
    (0xB000, 0xB200),
    (0xC000, 0xC100),
    (0xD000, 0xD200),
]


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_out_path() -> Path:
    return repo_root() / "data" / "launcher-devices.json"


def vendor_product_id(vid: int, pid: int) -> int:
    return ((vid & 0xFFFF) << 16) | (pid & 0xFFFF)


def fetch_one(
    pid: int, vid: int = KEYCHRON_VID, timeout: float = 2.5
) -> tuple[str, dict] | None:
    vpid = vendor_product_id(vid, pid)
    for base in STATIC_BASES:
        url = base.format(vpid=vpid)
        try:
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "noctalia-keychron-battery/1.0 (+update_launcher_devices)",
                    "Accept": "application/json",
                    "Referer": "https://launcher.keychron.cn/",
                },
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="replace"))
            name = (data.get("name") or "").strip()
            type_str = (data.get("type") or "").strip()
            if not name and not type_str:
                continue
            key = f"{vid:04x}:{pid:04x}"
            return key, {
                "vid": vid,
                "pid": pid,
                "vpid": vpid,
                "name": name,
                "type": type_str,
                "sourceUrl": url,
            }
        except (
            urllib.error.HTTPError,
            urllib.error.URLError,
            TimeoutError,
            json.JSONDecodeError,
            OSError,
        ):
            continue
    return None


def iter_pids(ranges: list[tuple[int, int]]) -> list[int]:
    pids: set[int] = set()
    for start, end in ranges:
        pids.update(range(start, end))
    return sorted(pids)


def update(
    out_path: Path,
    ranges: list[tuple[int, int]],
    workers: int = 24,
    timeout: float = 2.5,
    quiet: bool = False,
) -> dict:
    pids = iter_pids(ranges)
    found: dict[str, dict] = {}
    t0 = time.time()

    if not quiet:
        print(
            f"Scanning {len(pids)} PIDs (vid=0x{KEYCHRON_VID:04X}) with {workers} workers…",
            flush=True,
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [pool.submit(fetch_one, pid, KEYCHRON_VID, timeout) for pid in pids]
        for fut in concurrent.futures.as_completed(futs):
            res = fut.result()
            if not res:
                continue
            key, entry = res
            found[key] = entry
            if not quiet:
                print(
                    f"+ {entry['pid']:04X} {entry['name']!r} type={entry['type']!r}",
                    flush=True,
                )

    if not found:
        raise RuntimeError("No device metadata found; refusing to replace the catalog")

    previous_count = 0
    if out_path.is_file():
        try:
            previous = json.loads(out_path.read_text(encoding="utf-8"))
            previous_count = len(previous.get("devices") or {})
        except (OSError, json.JSONDecodeError, AttributeError):
            pass
    if previous_count and len(found) < previous_count * 0.95:
        raise RuntimeError(
            f"Found only {len(found)} of {previous_count} existing entries; "
            "write to a separate --out path and review the result"
        )

    payload = {
        "version": 1,
        "description": (
            "Keychron Launcher static device definitions (name + type). "
            "Generated by scripts/update_launcher_devices.py"
        ),
        "source": "https://launcher.keychron.cn/static/device/{vpid}/json/v3.json",
        "vendorId": KEYCHRON_VID,
        "vendorProductIdFormula": "vpid = (vid << 16) | pid",
        "updatedAt": int(time.time()),
        "count": len(found),
        "devices": dict(sorted(found.items())),
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = out_path.with_name(out_path.name + ".tmp")
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary_path.replace(out_path)

    if not quiet:
        print(
            f"Wrote {out_path} ({len(found)} devices, {time.time() - t0:.1f}s)",
            flush=True,
        )
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=default_out_path(),
        help=f"Output JSON path (default: {default_out_path()})",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="Scan wider PID ranges (slower, more complete)",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Only scan mouse/dongle band 0xD000-0xD100 (fast smoke test)",
    )
    parser.add_argument("--workers", type=int, default=24, help="Parallel HTTP workers")
    parser.add_argument(
        "--timeout", type=float, default=2.5, help="Per-request timeout seconds"
    )
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args(argv)

    if args.quick:
        if args.out.resolve() == default_out_path().resolve():
            parser.error("--quick requires a separate --out path")
        ranges = [(0xD000, 0xD100)]
    elif args.full:
        ranges = FULL_RANGES
    else:
        ranges = DEFAULT_RANGES

    update(
        out_path=args.out,
        ranges=ranges,
        workers=max(1, args.workers),
        timeout=max(0.1, args.timeout),
        quiet=args.quiet,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
