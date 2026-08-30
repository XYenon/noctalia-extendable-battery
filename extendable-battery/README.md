# Extendable Battery for Noctalia v5

A native-style Noctalia v5 bar widget and panel for Keychron keyboards, mice, and receivers.

## v5 integration

- Uses v5's `plugin.toml`, Luau service/widget/panel entries, generated settings UI, shared state, native palette roles, glyphs, and controls.
- Aligns with the native battery widget's `none` / `glyph` / `graphic` modes, label fallback, warning color, hide-when-plugged/full behavior, structured tooltip, and glyph thresholds. Because v5 does not expose the native graphic battery renderer, `graphic` uses the native declarative progress control and palette.
- Left click keeps the extension's original combined view: system batteries are listed first, followed by Keychron and registered-provider batteries with the same per-device status, progress, percentage, and fallback error rows. Right click has no default action and middle click opens widget settings, matching the native v5 widget gesture defaults.
- The old power-profile option remains off by default. Enabling it shows an entry to Noctalia's native **Control Center → Power** tab for UPower-backed controls instead of reimplementing private shell services. Noctalia v5 removed the old shell-performance mode, so there is no native `showNoctaliaPerformance` equivalent to preserve.
- Provider data and low-battery notifications are owned by one background service.

Noctalia v5 does not expose its private `UPowerService`, native battery geometry, or a cross-plugin provider registry to Luau. Consequently, the old v4 QML provider split cannot be preserved. The bundled service reads the system battery for the combined panel and Keychron backend, while advanced system controls are delegated to the native Power tab instead of copied.

## Settings

Noctalia generates and persists settings from `plugin.toml`.

Widget-instance settings mirror the native v5 widget: display mode, label visibility/content, hide when plugged/full, and warning color. Advanced settings select a device by name substring and prefer Bluetooth readings.

Plugin-wide settings configure refresh interval, Bluetooth discovery, notification thresholds, and notifications.

## HID permissions

Install the rule for USB / 2.4 GHz access:

```bash
sudo cp udev/70-keychron.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --action=add
```

Re-plug or wake the device after installing the rule.

## CLI diagnostics

From this directory:

```bash
python3 scripts/keychron_battery.py --pretty
python3 scripts/keychron_battery.py --list-hid
```

Protocol details are documented in [`PROTOCOL.md`](PROTOCOL.md).

## External provider snapshots

Noctalia v5 isolates plugin VMs, so providers register JSON snapshots through the service entry's IPC endpoint. Re-send `registerProvider` whenever the device list changes:

```bash
noctalia msg plugin xyenon/extendable-battery:battery-service all registerProvider \
  '{"id":"example","name":"Example","devices":[{"id":"mouse","name":"Wireless Mouse","percent":85,"ready":true,"present":true,"kind":"mouse"}]}'

noctalia msg plugin xyenon/extendable-battery:battery-service all unregisterProvider example
```

Registered devices appear below the system battery alongside the bundled Keychron devices. Registrations are in-memory and should be restored by the provider after either plugin reloads.

## Local development and validation

Add the repository as a path source in Noctalia v5, or copy/symlink this directory under the v5 plugin development directory. Validate with:

```bash
noctalia plugins lint extendable-battery
python3 scripts/keychron_battery.py --pretty
```

## Requirements

- Noctalia Shell v5 with plugin API 24+
- Python 3.10+
- Linux; optional BlueZ and `busctl` for Bluetooth readings
- Read/write access to Keychron `/dev/hidraw*` nodes for USB / receiver readings
