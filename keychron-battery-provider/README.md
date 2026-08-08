# Keychron Battery Provider

Keychron battery backend for the [Extendable Battery](../extendable-battery/README.md) plugin.

Reads Keychron keyboards, mice, and receivers over Linux `hidraw`, with optional Bluetooth readings via BlueZ.

The HID protocol was reverse-engineered from the official [Keychron Launcher](https://launcher.keychron.cn/) WebHID frontend; see [`PROTOCOL.md`](PROTOCOL.md). The plugin ships a bundled device catalog and does **not** access the network at runtime.

## Install

Full repository setup (source URL, install order) is in the [repository README](../README.md).

1. Install and enable **Extendable Battery** first.
2. Install and enable **Keychron Battery Provider**.
3. Install the [udev rule](#hid-permissions) for USB / receiver HID access.
4. Ensure the Extendable Battery widget is on the bar.

Noctalia v4 records the dependency on Extendable Battery as metadata but does not install or enable it automatically.

## HID permissions

Install the udev rule so the desktop user can open Keychron HID interfaces.

From the **repository root**:

```bash
sudo cp keychron-battery-provider/udev/70-keychron.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --action=add
```

From the **plugin directory** (`keychron-battery-provider/`):

```bash
sudo cp udev/70-keychron.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --action=add
```

Re-plug the device (or reboot) if it was already connected. Confirm your user can read/write the relevant `/dev/hidraw*` nodes.

## Settings

Configured in the plugin settings UI. Defaults come from `manifest.json`.

| Setting                   | Default    | Description                                               |
| ------------------------- | ---------- | --------------------------------------------------------- |
| Refresh interval (ms)     | `60000`    | How often to query HID and BlueZ (minimum 5000).          |
| Enable Bluetooth readings | on         | Read battery info exposed by BlueZ.                       |
| Bluetooth name filter     | `keychron` | Only include BlueZ devices whose name contains this text. |
| Battery notifications     | on         | Low/critical toasts once per discharge cycle.             |
| Low battery threshold (%) | `20`       | When to show a low-battery notification.                  |
| Critical threshold (%)    | `5`        | When to show a critical-battery notification.             |

These thresholds and notifications apply only to **provider** devices. They do not change Noctalia’s system-battery thresholds.

## CLI diagnostics

From the plugin directory (works without Noctalia):

```bash
cd keychron-battery-provider   # if you are at the repository root
python3 scripts/keychron_battery.py --pretty
python3 scripts/keychron_battery.py --list-hid
```

Output is JSON in the Extendable Battery provider device schema.

## Troubleshooting

| Symptom                               | What to check                                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Device connected, no battery in panel | Provider enabled? Extendable Battery enabled and widget on bar?                                                     |
| HID path missing / permission errors  | [udev rule](#hid-permissions) installed, rules reloaded, device re-plugged; rule uses `uaccess` for the active seat |
| Only Bluetooth shows a percentage     | HID interface not readable; fix udev / permissions, then re-run `--list-hid`                                        |
| No devices from CLI                   | `python3 scripts/keychron_battery.py --list-hid` and `--pretty`; confirm VID `0x3434` / Keychron product appears    |
| Stale or wrong name                   | Catalog is offline; see [Updating the device catalog](#updating-the-device-catalog) (maintainers)                   |

Optional debug: set `KEYCHRON_BATTERY_DEBUG=1` when running the Python script for extra stderr diagnostics.

## Local development

From a checkout of this repository:

```bash
ln -sfn "$(pwd)/keychron-battery-provider" ~/.config/noctalia/plugins/keychron-battery-provider
```

Enable **Extendable Battery** and this provider in Noctalia. Use the CLI above to validate HID access before debugging QML.

## Updating the device catalog

**Maintainer task** — end users do not need this for normal use.

```bash
cd keychron-battery-provider
python3 scripts/update_launcher_devices.py
python3 scripts/update_launcher_devices.py --full
python3 scripts/update_launcher_devices.py --quick --out /tmp/keychron-devices.json
```

The catalog lives in [`data/launcher-devices.json`](data/launcher-devices.json). Review the diff before committing; the updater refuses to replace the catalog with an empty or substantially smaller result.

## Requirements

**Required**

- Linux
- Python **3.10+**
- Read/write access to `/dev/hidraw*` (udev rule above)
- Noctalia Shell **v4.7.7+** and **Extendable Battery** for in-shell integration

**Optional**

- BlueZ and `busctl` for Bluetooth battery readings
