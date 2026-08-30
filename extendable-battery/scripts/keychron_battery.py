#!/usr/bin/env python3
"""Read Keychron device batteries for the Noctalia v5 Extendable Battery plugin.

Protocols (from Keychron Launcher production JS):

Keyboard / NAPE (usagePage 0xFF60, usage 0x61):
  sendReport(0, [0xA7, 0x31, 0...])  -> KC_USER_CMD_NAPE_GET_BAT_REPORT
  response: [0xA7, 0x31, percent, status, ...]
  watch:    [0xA7, 0x30, ...]        -> KC_USER_CMD_NAPE_BAT_REPORT

Dongle discovery (same collection):
  sendReport(0, [0xB2, 0...])
  response: [0xB2, ..., vid/pid/status triples]

Mouse RF (usagePage 0x008C, usage 0x01) — feature report 0x51:
  sendFeatureReport(0x51, [0x06, 0...])
  response input report body starting with 0x06:
    percent = body[10], state = body[11] & 3

Mouse status (64-byte output, report id 0 payload):
  payload[0]=1 (or 65 if wireless workMode), [2]=129, [3]=1, checksum at [63]
  4K response: byte0 in {1,65}, byte3==1 -> state=byte5, percent=byte6
  8K Nordic response: same filter -> state=byte10, percent=byte11

Mouse 8K feature report:
  feature 0xB3 / cmd 0x06 -> body byte19 packs state in bit7 and percent in bits0-6

Bluetooth:
  org.bluez.Battery1.Percentage when the device is connected.
"""

from __future__ import annotations

import argparse
import array
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field

KEYCHRON_VID = 0x3434

# NAPE commands (launcher enum D_)
NAPE_BAT_REPORT = 48  # 0x30 — push/watch
NAPE_GET_BAT_REPORT = 49  # 0x31 — pull
NAPE_MARKER = 0xA7  # 167
DONGLE_VPID = 0xB2  # 178

# Mouse RF
RF_USAGE_PAGE = 0x008C
RF_FEATURE_ID = 0x51
RF_INPUT_ID = 0x54
RF_CMD_STATUS = 0x06
RF_CMD_WAKE = 0x07
RF_CMD_PREPARE = 0x0C

# Mouse 8K feature report
MOUSE_8K_FEATURE_ID = 0xB3
MOUSE_8K_RESPONSE_IDS = (0xB3, 0xB4)
MOUSE_8K_COMMAND = 0x06
MOUSE_8K_POWER_OFFSET = 19

# Raw keyboard collection
NAPE_USAGE_PAGE = 0xFF60
NAPE_USAGE = 0x61

IOC_WRITE = 1
IOC_READ = 2

# Launcher WebHID collection map (from getDeviceInfo in launcher JS):
#   key = (usage << 16) | usagePage
LAUNCHER_COLLECTIONS = {
    (0x61, 0xFF60): "keyboard",  # usage 97, page 65376
    (0x01, 0xFFC1): "mouse",  # usage 1, page 65473
    (0x01, 0xFF0A): "mouse_4k",  # usage 1, page 65290
    (0x01, 0x008C): "bridge",  # usage 1, page 140
}

# Loaded from data/launcher-devices.json (see scripts/update_launcher_devices.py).
# Maps USB product id -> {name, kind, type, vpid, ...}
PRODUCT_CATALOG: dict[int, dict] = {}


def _devices_json_path() -> str:
    """Resolve bundled catalog next to the plugin / repo root."""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "data", "launcher-devices.json"),
        os.path.join(here, "data", "launcher-devices.json"),
        os.path.join(os.path.dirname(here), "data", "launcher-devices.json"),
    ]
    # Also allow override
    env = os.environ.get("KEYCHRON_DEVICES_JSON")
    if env:
        candidates.insert(0, os.path.expanduser(env))
    for c in candidates:
        p = os.path.normpath(c)
        if os.path.isfile(p):
            return p
    return os.path.normpath(candidates[0])


def vendor_product_id(vid: int, pid: int) -> int:
    """Launcher XW.vendorProductId(vid, pid) => 65536*vid + pid."""
    return (int(vid) << 16) | (int(pid) & 0xFFFF)


def _kind_from_launcher_type(type_str: str, name: str = "") -> str:
    """Map Launcher static JSON type (+ empty type) to UI kind."""
    t = (type_str or "").strip().lower()
    n = (name or "").lower()
    if t in ("mouse", "mouse3", "mouse_4k", "mouse4k") or t.startswith("mouse"):
        return "mouse"
    if t in ("keyboard", "kb") or t.startswith("key"):
        return "keyboard"
    if t in ("bridge", "dongle", "receiver", "rf", "link"):
        return "dongle"
    if t in ("trackball",) or "trackball" in n or "nape" in n:
        return "trackball"
    if t.isdigit():
        return {0: "keyboard", 1: "mouse", 2: "dongle", 3: "trackball"}.get(
            int(t), "unknown"
        )
    # Launcher often omits type for keyboards — infer from name series
    if re.search(r"\b(k|q|v|b)\d", n) or "keyboard" in n:
        return "keyboard"
    if re.search(r"\bm\d", n) or "mouse" in n:
        return "mouse"
    if "link" in n or "dongle" in n or "receiver" in n or "ultra-link" in n:
        return "dongle"
    return "unknown"


def load_product_catalog(
    path: str | None = None, force: bool = False
) -> dict[int, dict]:
    """Load PRODUCT_CATALOG from launcher-devices.json."""
    global PRODUCT_CATALOG
    if PRODUCT_CATALOG and not force:
        return PRODUCT_CATALOG

    json_path = path or _devices_json_path()
    catalog: dict[int, dict] = {}
    try:
        with open(json_path, encoding="utf-8") as fh:
            data = json.load(fh)
        devices = data.get("devices") or {}
        if isinstance(devices, dict):
            for _key, entry in devices.items():
                if not isinstance(entry, dict):
                    continue
                try:
                    pid = int(entry.get("pid"))
                except (TypeError, ValueError):
                    # key form "3434:d046"
                    try:
                        pid = int(str(_key).split(":")[-1], 16)
                    except ValueError:
                        continue
                name = (entry.get("name") or "").strip()
                type_str = (entry.get("type") or "").strip()
                kind = _kind_from_launcher_type(type_str, name)
                catalog[pid] = {
                    "name": name or f"Keychron {pid:04X}",
                    "kind": kind,
                    "type": type_str,
                    "vpid": entry.get("vpid") or vendor_product_id(KEYCHRON_VID, pid),
                    "vid": int(entry.get("vid") or KEYCHRON_VID),
                    "sourceUrl": entry.get("sourceUrl") or "",
                }
    except (OSError, json.JSONDecodeError) as exc:
        # Minimal built-in safety net if JSON missing
        catalog = {
            0xD031: {
                "name": "Keychron Link",
                "kind": "dongle",
                "type": "",
                "vpid": vendor_product_id(KEYCHRON_VID, 0xD031),
                "vid": KEYCHRON_VID,
                "sourceUrl": "",
            },
            0xD03F: {
                "name": "Keychron M6",
                "kind": "mouse",
                "type": "mouse",
                "vpid": vendor_product_id(KEYCHRON_VID, 0xD03F),
                "vid": KEYCHRON_VID,
                "sourceUrl": "",
            },
            0xD046: {
                "name": "Keychron M6 4K",
                "kind": "mouse",
                "type": "mouse",
                "vpid": vendor_product_id(KEYCHRON_VID, 0xD046),
                "vid": KEYCHRON_VID,
                "sourceUrl": "",
            },
            0xD049: {
                "name": "Keychron M6 8K",
                "kind": "mouse",
                "type": "mouse3",
                "vpid": vendor_product_id(KEYCHRON_VID, 0xD049),
                "vid": KEYCHRON_VID,
                "sourceUrl": "",
            },
        }
        if os.environ.get("KEYCHRON_BATTERY_DEBUG"):
            print(f"catalog load failed ({json_path}): {exc}", file=sys.stderr)

    PRODUCT_CATALOG = catalog
    return PRODUCT_CATALOG


# Load once at import
load_product_catalog()

_GENERIC_LINK_NAMES = {
    "keychron  keychron link",
    "keychron keychron link",
    "keychron link",
    "keychron",
}


def classify_hid_collection(usages: list) -> str:
    """Classify one hidraw by Launcher WebHID collection rules."""
    for page, usage in usages:
        key = (int(usage), int(page))
        if key in LAUNCHER_COLLECTIONS:
            return LAUNCHER_COLLECTIONS[key]
    # Page-only fallbacks (usage parse can miss)
    pages = {int(p) for p, _u in usages}
    if NAPE_USAGE_PAGE in pages:
        return "keyboard"
    if 0xFFC1 in pages:
        return "mouse"
    if 0xFF0A in pages:
        return "mouse_4k"
    if RF_USAGE_PAGE in pages:
        return "bridge"
    return "unknown"


def collection_to_kind(collection: str) -> str:
    c = (collection or "").lower()
    if c in ("mouse", "mouse_4k"):
        return "mouse"
    if c == "keyboard":
        return "keyboard"
    if c == "bridge":
        return "dongle"
    return "unknown"


def get_launcher_device_meta(vid: int, pid: int) -> dict | None:
    """Return bundled Launcher metadata without accessing the network."""
    if vid != KEYCHRON_VID or not pid:
        return None
    vpid = vendor_product_id(vid, pid)
    if pid in PRODUCT_CATALOG:
        cat = PRODUCT_CATALOG[pid]
        return {
            "name": cat["name"],
            "kind": cat["kind"],
            "type": cat["kind"],
            "vpid": vpid,
            "source": "catalog",
        }
    return None


def list_bluez_keychron_names() -> list[dict]:
    """Return BlueZ Device1 entries whose name/alias mentions Keychron."""
    out: list[dict] = []
    try:
        tree = subprocess.check_output(
            ["busctl", "--system", "tree", "org.bluez"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return out

    paths = sorted(set(re.findall(r"/org/bluez/hci\d+/dev_[A-F0-9_]+", tree)))
    for path in paths:
        name = ""
        alias = ""
        for prop in ("Name", "Alias"):
            raw = _busctl_get(path, "org.bluez.Device1", prop)
            if raw and '"' in raw:
                val = raw.split('"', 2)[1]
                if prop == "Name":
                    name = val
                else:
                    alias = val
        label = alias or name
        if not label or "keychron" not in label.lower():
            continue
        conn_raw = _busctl_get(path, "org.bluez.Device1", "Connected") or ""
        connected = conn_raw.strip().endswith("true")
        out.append(
            {
                "name": label,
                "path": path,
                "connected": connected,
            }
        )
    return out


def _guess_pids_from_bluez_name(label: str) -> list[int]:
    """Map a BlueZ friendly name to candidate USB PIDs for static lookup."""
    n = (label or "").lower()
    hits: list[int] = []
    for pid, cat in PRODUCT_CATALOG.items():
        cname = cat["name"].lower()
        # "Keychron M6" should match "Keychron M6 4K" / "Keychron M6 8K"
        short = re.sub(r"\s+", " ", n).strip()
        if short and short in cname:
            hits.append(pid)
            continue
        # token overlap on model id (m6, k10, ...)
        m = re.search(r"\b([kmqvb]\d+[a-z0-9]*)\b", n, re.IGNORECASE)
        if m and m.group(1).lower() in cname.replace(" ", ""):
            hits.append(pid)
    return hits


def resolve_identity(
    usb_name: str,
    pid: int,
    vid: int = KEYCHRON_VID,
    collection: str = "",
    product_vid: int = 0,
    product_pid: int = 0,
    bluez_names: list[dict] | None = None,
) -> dict:
    """Resolve display name + kind the way Launcher does (meta > collection > fallbacks).

    Returns {name, kind, metaSource, productVid, productPid, collection}.
    """
    bluez_names = (
        bluez_names if bluez_names is not None else list_bluez_keychron_names()
    )
    collection = collection or ""
    coll_kind = collection_to_kind(collection)

    # Product identity: prefer downstream (paired) vid/pid when known
    p_vid = product_vid or vid or KEYCHRON_VID
    p_pid = product_pid or pid or 0

    meta = get_launcher_device_meta(p_vid, p_pid) if p_pid else None

    # On a Link/bridge with only dongle PID, try BlueZ name → candidate product PIDs → static JSON
    usb_compact = " ".join((usb_name or "").split()).lower()
    is_generic_dongle = (
        coll_kind == "dongle"
        or usb_compact in _GENERIC_LINK_NAMES
        or "link" in usb_compact
        or (p_pid in PRODUCT_CATALOG and PRODUCT_CATALOG[p_pid]["kind"] == "dongle")
    )
    if (not meta or meta.get("kind") == "dongle") and is_generic_dongle and bluez_names:
        candidates = sorted(
            bluez_names,
            key=lambda c: (0 if c.get("connected") else 1, c.get("name") or ""),
        )
        for c in candidates:
            label = c.get("name") or ""
            for cand_pid in _guess_pids_from_bluez_name(label):
                m2 = get_launcher_device_meta(KEYCHRON_VID, cand_pid)
                if m2 and m2.get("kind") in ("mouse", "keyboard", "trackball"):
                    meta = m2
                    p_pid = cand_pid
                    p_vid = KEYCHRON_VID
                    # Prefer exact BlueZ label when it's more natural ("Keychron M6" vs "Keychron M6 4K")
                    if label:
                        meta = dict(meta)
                        meta["name"] = label
                        meta["source"] = (meta.get("source") or "") + "+bluez-name"
                    break
            if meta and meta.get("kind") in ("mouse", "keyboard", "trackball"):
                break
            # Even without static hit, BlueZ name is what the OS/Web show
            if label and (not meta or meta.get("kind") == "dongle"):
                kind_guess = "unknown"
                if (
                    re.search(r"\bm\d", label, re.IGNORECASE)
                    or "mouse" in label.lower()
                ):
                    kind_guess = "mouse"
                elif (
                    re.search(r"\b(k|q|v|b)\d", label, re.IGNORECASE)
                    or "keyboard" in label.lower()
                ):
                    kind_guess = "keyboard"
                meta = {
                    "name": label,
                    "kind": kind_guess
                    if kind_guess != "unknown"
                    else (coll_kind or "unknown"),
                    "type": kind_guess,
                    "vpid": vendor_product_id(p_vid, p_pid) if p_pid else 0,
                    "source": "bluez-name",
                }
                break

    # Compose final name/kind
    if meta and meta.get("name"):
        name = meta["name"]
        kind = meta.get("kind") or coll_kind or "unknown"
        # Static type wins over bridge collection (bridge is the radio path, not the product)
        if kind == "dongle" and coll_kind in ("mouse", "keyboard"):
            kind = coll_kind
        elif kind == "unknown":
            kind = coll_kind or "unknown"
        return {
            "name": name,
            "kind": kind,
            "metaSource": meta.get("source") or "",
            "productVid": p_vid,
            "productPid": p_pid,
            "collection": collection,
        }

    # Fallbacks without meta
    if p_pid in PRODUCT_CATALOG:
        cat = PRODUCT_CATALOG[p_pid]
        return {
            "name": cat["name"],
            "kind": cat["kind"]
            if cat["kind"] != "dongle" or coll_kind == "dongle"
            else coll_kind,
            "metaSource": "catalog",
            "productVid": p_vid,
            "productPid": p_pid,
            "collection": collection,
        }

    # Clean USB string
    compact = " ".join((usb_name or "").split())
    if compact:
        parts = compact.split()
        if (
            len(parts) >= 2
            and parts[0].lower() == "keychron"
            and parts[1].lower() == "keychron"
        ):
            compact = (
                "Keychron " + " ".join(parts[2:]) if len(parts) > 2 else "Keychron"
            )
        elif not compact.lower().startswith("keychron"):
            compact = f"Keychron {compact}"
    else:
        compact = f"Keychron {p_pid:04X}" if p_pid else "Keychron"

    kind = coll_kind or "unknown"
    return {
        "name": compact,
        "kind": kind,
        "metaSource": "usb",
        "productVid": p_vid,
        "productPid": p_pid,
        "collection": collection,
    }


def _ioc(direction: int, type_: str, nr: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord(type_) << 8) | nr


def HIDIOCSFEATURE(size: int) -> int:
    return _ioc(IOC_WRITE | IOC_READ, "H", 0x06, size)


def HIDIOCGFEATURE(size: int) -> int:
    return _ioc(IOC_WRITE | IOC_READ, "H", 0x07, size)


def checksum64(buf: bytearray) -> bytearray:
    """Launcher T(): buf[63] = 161 - sum(buf[0:63]) & 0xff."""
    total = sum(buf[:63]) & 0xFF
    buf[63] = (161 - total) & 0xFF
    return buf


def apply_work_mode(buf: bytearray, work_mode: int) -> None:
    """Launcher I(): when workMode==1 (wireless), set bit6 on byte0."""
    if work_mode == 1:
        buf[0] |= 1 << 6


def infer_device_kind(
    name: str = "",
    protocol: str = "",
    transport: str = "",
    pages: set | None = None,
    pid: int = 0,
    collection: str = "",
    meta_kind: str = "",
) -> str:
    """Classify device for UI icons — prefers Launcher meta/collection over name regex."""
    # 1) Official / resolved product category (Launcher static type / VU)
    if meta_kind in ("mouse", "keyboard", "dongle", "trackball"):
        return meta_kind

    # 2) WebHID collection role (bridge is the radio path — only use if no better signal)
    coll_kind = collection_to_kind(collection)
    if coll_kind in ("mouse", "keyboard"):
        return coll_kind

    n = (name or "").lower()
    p = (protocol or "").lower()
    pages = pages or set()

    # 3) Offline catalog by USB PID
    if pid in PRODUCT_CATALOG:
        k = PRODUCT_CATALOG[pid]["kind"]
        if k in ("mouse", "keyboard"):
            return k

    # 4) Name / protocol heuristics (last resort — same as before)
    if re.search(r"\bm\d", n) or "mouse" in n:
        return "mouse"
    if re.search(r"\b(k|q|v|b)\d", n) or "keyboard" in n or "keychron k" in n:
        return "keyboard"
    if "mouse" in p or p.startswith("mouse_") or RF_USAGE_PAGE in pages:
        return "mouse"
    if "nape" in p or NAPE_USAGE_PAGE in pages:
        return "keyboard"
    if coll_kind == "dongle" or "link" in n or "dongle" in n:
        return "dongle"
    if pid in PRODUCT_CATALOG:
        return PRODUCT_CATALOG[pid]["kind"]

    return "unknown"


@dataclass
class BatteryReading:
    name: str
    percent: int
    charging: bool = False
    plugged_in: bool = False
    status: int = 0
    protocol: str = ""
    transport: str = ""
    kind: str = "unknown"  # mouse | keyboard | dongle | unknown
    vid: int = KEYCHRON_VID
    pid: int = 0
    hidraw: str = ""
    path: str = ""
    device_id: str = ""
    connected: bool = True
    error: str = ""
    extra: dict = field(default_factory=dict)

    def to_public(self) -> dict:
        d = asdict(self)
        d["vid"] = f"0x{self.vid:04X}"
        d["pid"] = f"0x{self.pid:04X}"
        d["id"] = d.pop("device_id")
        d["present"] = self.connected
        d["ready"] = self.connected and self.percent >= 0
        d["pluggedIn"] = d.pop("plugged_in")
        d["timeToFull"] = 0
        d["timeToEmpty"] = 0
        d["changeRate"] = 0
        d["healthSupported"] = False
        d["healthPercentage"] = 0
        if not d.get("kind"):
            d["kind"] = infer_device_kind(
                name=self.name,
                protocol=self.protocol,
                transport=self.transport,
                pid=self.pid,
            )
        if not d["error"]:
            d.pop("error", None)
        if not d["extra"]:
            d.pop("extra", None)
        return d


def parse_report_descriptor(desc: bytes):
    pages = set()
    usages = []
    report_ids = []
    i = 0
    cur_page = None
    while i < len(desc):
        b = desc[i]
        i += 1
        if b == 0xFE:
            size = desc[i]
            i += 2 + size
            continue
        size = b & 0x03
        if size == 3:
            size = 4
        tag = b & 0xFC
        val = 0
        if size:
            val = int.from_bytes(desc[i : i + size], "little")
            i += size
        if tag == 0x04:  # Usage Page
            cur_page = val
            pages.add(val)
        elif tag == 0x08:  # Usage
            usages.append((cur_page, val))
        elif b == 0x85:  # Report ID
            report_ids.append(val)
    return pages, usages, report_ids


def iter_keychron_hidraw() -> list[dict]:
    devices = []
    for uevent_path in sorted(glob.glob("/sys/class/hidraw/hidraw*/device/uevent")):
        name = uevent_path.split("/")[4]
        info = {}
        with open(uevent_path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    info[k] = v
        hid_id = info.get("HID_ID", "")
        parts = hid_id.split(":")
        if len(parts) < 3:
            continue
        try:
            vid = int(parts[1], 16)
            pid = int(parts[2], 16)
        except ValueError:
            continue
        product = info.get("HID_NAME", "").strip()
        if vid != KEYCHRON_VID:
            continue
        desc_path = f"/sys/class/hidraw/{name}/device/report_descriptor"
        try:
            with open(desc_path, "rb") as descriptor:
                desc = descriptor.read()
        except OSError:
            desc = b""
        pages, usages, rids = parse_report_descriptor(desc)
        collection = classify_hid_collection(usages)
        uniq = info.get("HID_UNIQ", "").strip()
        phys = info.get("HID_PHYS", "").strip()
        physical_id = uniq or re.sub(r"/input\d+$", "", phys)
        devices.append(
            {
                "hidraw": name,
                "path": f"/dev/{name}",
                "vid": vid,
                "pid": pid,
                "name": product or f"Keychron {pid:04X}",
                "phys": phys,
                "uniq": uniq,
                "physical_id": physical_id,
                "pages": pages,
                "usages": usages,
                "report_ids": rids,
                # Launcher WebHID collection role: keyboard | mouse | mouse_4k | bridge
                "collection": collection,
            }
        )
    return devices


def drain(fd: int) -> None:
    while True:
        try:
            os.read(fd, 256)
        except BlockingIOError:
            break
        except OSError:
            break


def read_for(fd: int, seconds: float = 0.8) -> list[bytes]:
    deadline = time.time() + seconds
    got: list[bytes] = []
    while time.time() < deadline:
        try:
            data = os.read(fd, 256)
            if data:
                got.append(bytes(data))
        except BlockingIOError:
            time.sleep(0.01)
        except OSError:
            break
    return got


def open_hidraw(path: str) -> int:
    return os.open(path, os.O_RDWR | os.O_NONBLOCK)


def write_raw(fd: int, payload: bytes) -> None:
    drain(fd)
    os.write(fd, payload)


def feature_set(fd: int, report_id: int, payload: bytes, body_size: int) -> None:
    data = bytes([report_id]) + payload
    total_size = body_size + 1
    if len(data) < total_size:
        data = data + bytes(total_size - len(data))
    data = data[:total_size]
    buf = array.array("B", data)
    drain(fd)
    fcntl.ioctl(fd, HIDIOCSFEATURE(len(buf)), buf, True)


def feature_get(fd: int, report_id: int, body_size: int) -> bytes:
    data = array.array("B", [report_id] + [0] * body_size)
    count = fcntl.ioctl(fd, HIDIOCGFEATURE(len(data)), data, True)
    return bytes(data[:count]) if count > 0 else b""


def strip_optional_report_id(data: bytes, expected_ids: Iterable[int] = ()) -> bytes:
    """Linux hidraw prefixes numbered reports with the report id."""
    if not data:
        return data
    if expected_ids and data[0] in expected_ids and len(data) > 1:
        return data[1:]
    return data


def parse_nape_battery(data: bytes) -> tuple | None:
    body = data
    if len(body) >= 5 and body[0] == 0x00 and body[1] == NAPE_MARKER:
        body = body[1:]
    if len(body) < 4 or body[0] != NAPE_MARKER:
        return None
    if body[1] not in (NAPE_GET_BAT_REPORT, NAPE_BAT_REPORT):
        return None
    percent = body[2]
    status = body[3]
    if percent > 100:
        return None
    return percent, status


def parse_mouse_getpower(
    body: bytes, work_mode: int
) -> tuple[int, int, bool, str] | None:
    """Parse the 4K or 8K Nordic getPower layout from Launcher V1.4.3."""
    if len(body) < 7 or body[0] != (65 if work_mode == 1 else 1) or body[3] != 1:
        return None

    is_8k_nordic = len(body) >= 12 and (body[6], body[7]) in (
        (ord("4"), ord("4")),
        (ord("-"), ord("6")),
    )
    if is_8k_nordic:
        raw_status = body[10]
        status = 0 if raw_status == 3 else raw_status
        percent = body[11]
        variant = "8k_nordic"
    else:
        status = body[5]
        percent = body[6]
        variant = "4k"

    if percent > 100:
        return None
    return percent, status, status not in (0, 3), variant


def parse_mouse_8k_feature(data: bytes) -> tuple[int, int] | None:
    """Parse packed battery state from an 8K 0xB3/0x06 response."""
    bodies = [data]
    if data and data[0] in MOUSE_8K_RESPONSE_IDS:
        bodies.insert(0, data[1:])
    elif len(data) > 1 and data[0] == 0 and data[1] in MOUSE_8K_RESPONSE_IDS:
        bodies.insert(0, data[2:])

    for body in bodies:
        if len(body) <= MOUSE_8K_POWER_OFFSET or body[0] != MOUSE_8K_COMMAND:
            continue
        packed = body[MOUSE_8K_POWER_OFFSET]
        return packed & 0x7F, (packed >> 7) & 0x01
    return None


def probe_nape(dev: dict, timeout: float = 0.45) -> list[BatteryReading]:
    if NAPE_USAGE_PAGE not in dev["pages"]:
        return []
    out: list[BatteryReading] = []
    try:
        fd = open_hidraw(dev["path"])
    except OSError as exc:
        return [
            BatteryReading(
                name=dev["name"],
                percent=-1,
                protocol="nape",
                transport="hid",
                vid=dev["vid"],
                pid=dev["pid"],
                hidraw=dev["hidraw"],
                path=dev["path"],
                connected=False,
                error=str(exc),
            )
        ]
    try:
        # Optional dongle discovery (best-effort)
        try:
            write_raw(fd, b"\x00" + bytes([DONGLE_VPID] + [0] * 31))
            read_for(fd, 0.2)
        except OSError:
            pass

        for cmd, method in (
            (NAPE_GET_BAT_REPORT, "nape_get"),
            (NAPE_BAT_REPORT, "nape_watch"),
        ):
            try:
                write_raw(fd, b"\x00" + bytes([NAPE_MARKER, cmd] + [0] * 30))
            except OSError as exc:
                out.append(
                    BatteryReading(
                        name=dev["name"],
                        percent=-1,
                        protocol=method,
                        transport="hid",
                        vid=dev["vid"],
                        pid=dev["pid"],
                        hidraw=dev["hidraw"],
                        path=dev["path"],
                        connected=False,
                        error=str(exc),
                    )
                )
                continue
            for packet in read_for(fd, timeout):
                parsed = parse_nape_battery(packet)
                if not parsed:
                    continue
                percent, status = parsed
                out.append(
                    BatteryReading(
                        name=dev["name"],
                        percent=percent,
                        charging=bool(status & 0x01) or status == 1,
                        status=status,
                        protocol=method,
                        transport="usb-nape",
                        vid=dev["vid"],
                        pid=dev["pid"],
                        hidraw=dev["hidraw"],
                        path=dev["path"],
                    )
                )
                return out
    finally:
        os.close(fd)
    return out


def probe_mouse_rf(dev: dict, timeout: float = 0.35) -> list[BatteryReading]:
    if RF_USAGE_PAGE not in dev["pages"]:
        return []
    out: list[BatteryReading] = []
    try:
        fd = open_hidraw(dev["path"])
    except OSError as exc:
        return [
            BatteryReading(
                name=dev["name"],
                percent=-1,
                protocol="mouse_rf_51",
                transport="hid",
                vid=dev["vid"],
                pid=dev["pid"],
                hidraw=dev["hidraw"],
                path=dev["path"],
                connected=False,
                error=str(exc),
            )
        ]
    try:
        # Compatibility probes from lightfex/keychron_battery_display, then
        # verified live on Keychron Link. Prepare often elicits an 0xE2/0xE3
        # monitor frame that already carries battery data.
        for prep in (
            bytes([RF_CMD_PREPARE, 0x02, 0x11]),
            bytes([RF_CMD_WAKE]),
            bytes([RF_CMD_STATUS]),
        ):
            try:
                feature_set(fd, RF_FEATURE_ID, prep, 20)
            except OSError:
                continue
            packets = read_for(fd, timeout)
            try:
                packets.append(feature_get(fd, RF_FEATURE_ID, 20))
            except OSError:
                pass
            for packet in packets:
                body = strip_optional_report_id(packet, (RF_INPUT_ID, RF_FEATURE_ID))
                if not body:
                    continue

                # Launcher monitor-base:
                #   0xE2 (226): power.state=body[3], power.value=body[4]
                #               UI treats power.state as truthy => charging
                #   0xE3 Link (verified live while plugging charge cable):
                #     e3 00 02 02 4e 00 ...  => 78%, not charging (body[5]=0)
                #     e3 00 02 02 50 01 ...  => 80%, charging     (body[5]=1)
                #     percent stays at body[4]; charge flag is body[5]
                if body[0] in (0xE2, 0xE3, 0xE6, 0xE7) and len(body) >= 5:
                    percent = body[4]
                    if body[0] == 0xE2:
                        status = body[3]
                        # Launcher UI: power.state truthy => charge icon
                        charging = bool(status)
                    else:
                        # Link E3/E6/E7: body[3] stays connected-ish (often 2);
                        # charge bit lives next to percent at body[5].
                        charge_flag = body[5] if len(body) > 5 else 0
                        status = charge_flag
                        charging = bool(charge_flag & 0x01)
                    if percent <= 100:
                        # Trailing ASCII often holds firmware like "0.1.7"
                        fw = ""
                        if len(body) >= 13 and body[7] in (
                            ord("0"),
                            ord("v"),
                            ord("V"),
                        ):
                            fw = (
                                bytes(body[7:13])
                                .split(b"\x00", 1)[0]
                                .decode("ascii", errors="ignore")
                            )
                        out.append(
                            BatteryReading(
                                name=dev["name"],
                                percent=percent,
                                charging=charging,
                                status=status,
                                protocol="mouse_rf_monitor",
                                transport="usb-rf",
                                vid=dev["vid"],
                                pid=dev["pid"],
                                hidraw=dev["hidraw"],
                                path=dev["path"],
                                extra={
                                    "raw": body[:16].hex(),
                                    "firmware": fw,
                                    "frame": f"0x{body[0]:02x}",
                                    "chargeFlag": int(body[5])
                                    if len(body) > 5
                                    else None,
                                },
                            )
                        )
                        return out

                # Launcher: filter it[0]==6, percent=it[10], state=it[11]&3
                if len(body) >= 12 and body[0] == RF_CMD_STATUS:
                    percent = body[10]
                    status = body[11] & 0x03
                    if percent <= 100:
                        out.append(
                            BatteryReading(
                                name=dev["name"],
                                percent=percent,
                                charging=status != 0,
                                status=status,
                                protocol="mouse_rf_51",
                                transport="usb-rf",
                                vid=dev["vid"],
                                pid=dev["pid"],
                                hidraw=dev["hidraw"],
                                path=dev["path"],
                                extra={"raw": body[:16].hex()},
                            )
                        )
                        return out
                # lightfex-style: echo 0x51 0x06 then percent at +11
                if len(body) >= 13 and body[0] == 0x51 and body[1] == RF_CMD_STATUS:
                    percent = body[11]
                    status = body[12] if len(body) > 12 else 0
                    if percent <= 100:
                        out.append(
                            BatteryReading(
                                name=dev["name"],
                                percent=percent,
                                charging=bool(status),
                                status=status,
                                protocol="mouse_rf_51_alt",
                                transport="usb-rf",
                                vid=dev["vid"],
                                pid=dev["pid"],
                                hidraw=dev["hidraw"],
                                path=dev["path"],
                            )
                        )
                        return out
    finally:
        os.close(fd)
    return out


def probe_mouse_getpower(dev: dict, timeout: float = 0.35) -> list[BatteryReading]:
    """64-byte getPower used by several launcher mouse protocol variants."""
    if dev.get("collection") != "mouse_4k":
        return []
    try:
        fd = open_hidraw(dev["path"])
    except OSError:
        return []
    try:
        for work_mode in (0, 1):
            payload = bytearray(64)
            payload[0] = 1
            payload[2] = 129  # 0x81
            payload[3] = 1
            apply_work_mode(payload, work_mode)
            checksum64(payload)
            try:
                # hidraw write() requires a report-id selector even for an
                # unnumbered report; the WebHID body follows that zero byte.
                write_raw(fd, b"\x00" + bytes(payload))
            except OSError:
                continue
            for packet in read_for(fd, timeout):
                body = packet
                # Response may include a leading report id
                candidates = [body]
                if len(body) > 1:
                    candidates.append(body[1:])
                for cand in candidates:
                    parsed = parse_mouse_getpower(cand, work_mode)
                    if not parsed:
                        continue
                    percent, status, charging, variant = parsed
                    return [
                        BatteryReading(
                            name=dev["name"],
                            percent=percent,
                            charging=charging,
                            status=status,
                            protocol="mouse_getpower",
                            transport="usb",
                            vid=dev["vid"],
                            pid=dev["pid"],
                            hidraw=dev["hidraw"],
                            path=dev["path"],
                            extra={"workMode": work_mode, "variant": variant},
                        )
                    ]
    finally:
        os.close(fd)
    return []


def probe_mouse_8k_feature(dev: dict, timeout: float = 0.3) -> list[BatteryReading]:
    """0xB3/0x06 packed battery report used by Launcher 8K protocol."""
    if dev.get("collection") != "mouse":
        return []
    try:
        fd = open_hidraw(dev["path"])
    except OSError:
        return []
    try:
        try:
            feature_set(fd, MOUSE_8K_FEATURE_ID, bytes([MOUSE_8K_COMMAND]), 63)
        except OSError:
            return []
        packets = read_for(fd, timeout)
        try:
            packets.append(feature_get(fd, MOUSE_8K_FEATURE_ID, 63))
        except OSError:
            pass
        for packet in packets:
            parsed = parse_mouse_8k_feature(packet)
            if not parsed:
                continue
            percent, status = parsed
            return [
                BatteryReading(
                    name=dev["name"],
                    percent=percent,
                    charging=bool(status),
                    status=status,
                    protocol="mouse_8k_feature",
                    transport="usb",
                    vid=dev["vid"],
                    pid=dev["pid"],
                    hidraw=dev["hidraw"],
                    path=dev["path"],
                )
            ]
    finally:
        os.close(fd)
    return []


def _busctl_get(path: str, interface: str, prop: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["busctl", "--system", "get-property", "org.bluez", path, interface, prop],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return out
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def probe_bluez(name_filter: str = "keychron") -> list[BatteryReading]:
    out: list[BatteryReading] = []
    for dev in list_bluez_keychron_names():
        name = dev["name"]
        path = dev["path"]
        connected = dev["connected"]
        if name_filter and name_filter.lower() not in name.lower():
            continue
        pct_raw = _busctl_get(path, "org.bluez.Battery1", "Percentage")
        if not pct_raw:
            # Still useful as a name source; only emit as a reading when connected
            if connected:
                out.append(
                    BatteryReading(
                        name=name,
                        percent=-1,
                        protocol="bluez",
                        transport="bluetooth",
                        path=path,
                        connected=True,
                        error="Battery1 not available (enable BlueZ Experimental?)",
                    )
                )
            continue
        try:
            percent = int(pct_raw.split()[-1])
        except ValueError:
            continue
        out.append(
            BatteryReading(
                name=name,
                percent=percent,
                charging=False,
                protocol="bluez",
                transport="bluetooth",
                path=path,
                connected=connected,
            )
        )
    return out


def _apply_friendly_names(
    readings: list[BatteryReading],
    devices: list[dict] | None = None,
    bluez_names: list[dict] | None = None,
) -> None:
    """Resolve name/kind using Launcher rules: static meta + HID collection + fallbacks."""
    names = bluez_names if bluez_names is not None else list_bluez_keychron_names()
    dev_by_hidraw = {}
    if devices:
        for d in devices:
            dev_by_hidraw[d.get("hidraw") or ""] = d

    for r in readings:
        if r.kind == "system":
            continue
        dev = dev_by_hidraw.get(r.hidraw or "") or {}
        collection = dev.get("collection") or ""
        # Prefer product pid from extra if a probe stored downstream identity
        product_vid = int(r.extra.get("productVid") or 0) if r.extra else 0
        product_pid = int(r.extra.get("productPid") or 0) if r.extra else 0

        identity = resolve_identity(
            usb_name=r.name,
            pid=r.pid or dev.get("pid") or 0,
            vid=r.vid or dev.get("vid") or KEYCHRON_VID,
            collection=collection,
            product_vid=product_vid,
            product_pid=product_pid,
            bluez_names=names,
        )
        r.name = identity["name"]
        r.kind = identity["kind"]
        if r.extra is None:
            r.extra = {}
        r.extra["collection"] = collection or identity.get("collection") or ""
        r.extra["metaSource"] = identity.get("metaSource") or ""
        if identity.get("productPid"):
            r.extra["productVid"] = f"0x{identity['productVid']:04X}"
            r.extra["productPid"] = f"0x{identity['productPid']:04X}"
            r.extra["vpid"] = vendor_product_id(
                identity["productVid"], identity["productPid"]
            )


def probe_system_battery() -> list[BatteryReading]:
    """Probe Linux sysfs for native system/laptop battery (BAT0, etc.)."""
    out: list[BatteryReading] = []
    for bat_path in sorted(glob.glob("/sys/class/power_supply/BAT*")):
        try:
            cap_file = os.path.join(bat_path, "capacity")
            stat_file = os.path.join(bat_path, "status")
            if not os.path.exists(cap_file):
                continue
            with open(cap_file, encoding="utf-8") as f:
                percent = int(f.read().strip())
            st = ""
            if os.path.exists(stat_file):
                with open(stat_file, encoding="utf-8") as f:
                    st = f.read().strip().lower()
            charging = st == "charging"
            plugged_in = st in ("full", "not charging")
            bat_name = os.path.basename(bat_path)
            out.append(
                BatteryReading(
                    name=f"System Battery ({bat_name})",
                    percent=percent,
                    charging=charging,
                    plugged_in=plugged_in,
                    status=1 if charging or plugged_in else 0,
                    protocol="sysfs",
                    transport="internal",
                    kind="system",
                    path=bat_path,
                    connected=True,
                )
            )
        except (OSError, ValueError):
            continue
    return out


def collect_readings(
    include_bluez: bool = True,
    bluez_filter: str = "keychron",
    include_system: bool = False,
) -> list[BatteryReading]:
    readings: list[BatteryReading] = []
    if include_system:
        readings.extend(probe_system_battery())

    devices = iter_keychron_hidraw()
    bluez_names = list_bluez_keychron_names()

    # Prefer more specific collections first
    for dev in devices:
        readings.extend(probe_nape(dev))
    for dev in devices:
        if any(r.hidraw == dev["hidraw"] and r.percent >= 0 for r in readings):
            continue
        readings.extend(probe_mouse_rf(dev))
    for dev in devices:
        if any(r.hidraw == dev["hidraw"] and r.percent >= 0 for r in readings):
            continue
        readings.extend(probe_mouse_getpower(dev))
    for dev in devices:
        if any(r.hidraw == dev["hidraw"] and r.percent >= 0 for r in readings):
            continue
        readings.extend(probe_mouse_8k_feature(dev))

    # Attach Launcher-style name/kind before BlueZ battery merge
    _apply_friendly_names(readings, devices=devices, bluez_names=bluez_names)

    if include_bluez:
        readings.extend(probe_bluez(bluez_filter))

    hid_devices = {d["hidraw"]: d for d in devices}
    for reading in readings:
        if reading.transport == "bluetooth" and reading.path:
            reading.device_id = "bluez:" + reading.path
            continue
        if reading.protocol == "sysfs" and reading.path:
            reading.device_id = "sysfs:" + reading.path
            continue
        source = hid_devices.get(reading.hidraw)
        physical_id = source.get("physical_id", "") if source else ""
        if physical_id:
            reading.device_id = (
                f"hid:{physical_id}:{source['vid']:04x}:{source['pid']:04x}"
            )

    # One row per stable physical identity, preferring a successful reading.
    unique_by_id: dict[str, BatteryReading] = {}
    for reading in readings:
        if not reading.device_id:
            if os.environ.get("KEYCHRON_BATTERY_DEBUG"):
                print(
                    f"ignoring reading without stable identity: {reading.name}",
                    file=sys.stderr,
                )
            continue
        previous = unique_by_id.get(reading.device_id)
        if previous is None or (previous.percent < 0 <= reading.percent):
            unique_by_id[reading.device_id] = reading
    return list(unique_by_id.values())


def build_snapshot(
    include_bluez: bool = True,
    bluez_filter: str = "keychron",
    include_system: bool = False,
    only_ok: bool = False,
) -> dict:
    devices = iter_keychron_hidraw()
    readings = collect_readings(
        include_bluez=include_bluez,
        bluez_filter=bluez_filter,
        include_system=include_system,
    )
    ok = [r for r in readings if r.percent >= 0]
    if only_ok:
        readings = ok

    primary = None
    if ok:
        # Prefer keyboard-like names, then lowest battery
        def sort_key(r: BatteryReading):
            is_kb = (
                0
                if any(
                    x in r.name.lower()
                    for x in ("keychron", "keyboard", "k ", "q ", "v ")
                )
                else 1
            )
            return (is_kb, r.percent, r.name)

        primary = min(ok, key=sort_key)

    public_devices = [r.to_public() for r in readings]
    bluez_names = list_bluez_keychron_names()
    # Surface one pending row for every physical HID device not represented by
    # a probe result, even when another physical device answered successfully.
    if not only_ok and devices:
        represented_ids = {d.get("id") for d in public_devices}
        grouped_devices: dict[str, list[dict]] = {}
        for hid_device in devices:
            if not hid_device.get("physical_id"):
                continue
            pending_id = f"hid:{hid_device['physical_id']}:{hid_device['vid']:04x}:{hid_device['pid']:04x}"
            grouped_devices.setdefault(pending_id, []).append(hid_device)

        collection_rank = {
            "keyboard": 4,
            "mouse": 4,
            "mouse_4k": 4,
            "bridge": 3,
            "unknown": 0,
            "": 0,
        }
        for pending_id, hid_group in grouped_devices.items():
            if pending_id in represented_ids:
                continue
            d = max(
                hid_group,
                key=lambda candidate: collection_rank.get(
                    candidate.get("collection") or "", 1
                ),
            )
            collection = d.get("collection") or classify_hid_collection(
                d.get("usages") or []
            )
            role = collection or "unknown"
            if role == "bridge":
                role = "bridge"
            elif role == "keyboard":
                role = "nape-raw"
            elif role in ("mouse", "mouse_4k"):
                role = "mouse-rf"
            identity = resolve_identity(
                usb_name=d["name"],
                pid=d["pid"],
                vid=d["vid"],
                collection=collection,
                bluez_names=bluez_names,
            )
            if identity["kind"] == "mouse":
                role = "mouse-rf"
            elif identity["kind"] == "keyboard":
                role = "nape-raw"
            public_devices.append(
                {
                    "id": pending_id,
                    "name": identity["name"],
                    "percent": -1,
                    "charging": False,
                    "status": 0,
                    "protocol": role,
                    "transport": "usb",
                    "kind": identity["kind"],
                    "vid": f"0x{d['vid']:04X}",
                    "pid": f"0x{d['pid']:04X}",
                    "hidraw": d["hidraw"],
                    "path": d["path"],
                    "connected": True,
                    "extra": {
                        "collection": collection,
                        "metaSource": identity.get("metaSource") or "",
                    },
                    "error": "no battery response (device asleep or unsupported firmware?)",
                }
            )

    for device in public_devices:
        device.setdefault("present", device.get("connected") is not False)
        device.setdefault(
            "ready",
            bool(
                device["present"]
                and isinstance(device.get("percent"), (int, float))
                and device["percent"] >= 0
            ),
        )
        device.setdefault("pluggedIn", False)
        device.setdefault("timeToFull", 0)
        device.setdefault("timeToEmpty", 0)
        device.setdefault("changeRate", 0)
        device.setdefault("healthSupported", False)
        device.setdefault("healthPercentage", 0)

    return {
        "ok": bool(ok),
        "timestamp": int(time.time()),
        "deviceCount": len(ok),
        "hidInterfaces": [
            {
                "hidraw": d["hidraw"],
                "name": d["name"],
                "vid": f"0x{d['vid']:04X}",
                "pid": f"0x{d['pid']:04X}",
                "pages": sorted(f"0x{p:04X}" for p in d["pages"]),
                "collection": d.get("collection") or "",
            }
            for d in devices
        ],
        "primary": primary.to_public() if primary else None,
        "devices": public_devices,
        "error": None
        if ok
        else (
            "No battery reading available. Connect via cable/2.4G/Bluetooth, "
            "wake the device, and ensure udev access to hidraw (see udev/70-keychron.rules)."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Keychron battery reader (Launcher HID protocol)"
    )
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    parser.add_argument(
        "--no-bluez", action="store_true", help="Skip BlueZ battery probe"
    )
    parser.add_argument(
        "--bluez-filter", default="keychron", help="Bluetooth name substring filter"
    )
    parser.add_argument(
        "--include-system",
        action="store_true",
        help="Include Linux native system battery (BAT0)",
    )
    parser.add_argument(
        "--only-ok", action="store_true", help="Only include successful readings"
    )
    parser.add_argument(
        "--list-hid", action="store_true", help="Only list Keychron hidraw interfaces"
    )
    args = parser.parse_args(argv)

    if args.list_hid:
        devices = iter_keychron_hidraw()
        payload = [
            {
                "hidraw": d["hidraw"],
                "path": d["path"],
                "name": d["name"],
                "vid": f"0x{d['vid']:04X}",
                "pid": f"0x{d['pid']:04X}",
                "pages": sorted(f"0x{p:04X}" for p in d["pages"]),
                "reportIds": [f"0x{r:02X}" for r in d["report_ids"]],
            }
            for d in devices
        ]
        print(json.dumps(payload, indent=2 if args.pretty else None))
        return 0

    snap = build_snapshot(
        include_bluez=not args.no_bluez,
        bluez_filter=args.bluez_filter,
        include_system=args.include_system,
        only_ok=args.only_ok,
    )
    print(json.dumps(snap, indent=2 if args.pretty else None, ensure_ascii=False))
    return 0 if snap["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
