# Extendable Battery

Extensible battery provider manager and native-style battery widget for Noctalia Shell **v4.7.7+**.

## Features

- Merges native UPower (laptop) batteries with devices from independent provider plugins in one bar widget and panel.
- Native-style display modes, device selection, visibility options, tooltips, Bluetooth device list, power-profile controls, and Noctalia Performance mode.
- System batteries keep Noctalia’s native service and thresholds; provider devices use provider-owned thresholds and notifications.
- Providers can register live via QML or as a static snapshot over IPC.

## Install

Full repository setup (source URL, install order, bar widget) is in the [repository README](../README.md).

After the shared source is added:

1. Install and enable **Extendable Battery**.
2. Add its widget to the bar.
3. Install and enable one or more provider plugins if you need peripheral batteries.

## Settings

Configured in the plugin settings UI. Defaults come from `manifest.json`.

| Setting                   | Default         | Description                                                                          |
| ------------------------- | --------------- | ------------------------------------------------------------------------------------ |
| Display mode              | `graphic-clean` | How the bar presents charge.                                                         |
| Device                    | `__default__`   | Which battery the bar follows (`__default__` = automatic).                           |
| Show power profiles       | off             | Power-profile controls in the panel.                                                 |
| Show Noctalia Performance | off             | Noctalia Performance toggle in the panel.                                            |
| Hide if not detected      | on              | Hide the widget when no suitable battery is available.                               |
| Hide if idle              | off             | Hide when the selected device is idle / not interesting.                             |
| Prefer Bluetooth          | on              | When a provider reports multiple transports, prefer Bluetooth for default selection. |
| Device name filter        | _(empty)_       | Optional substring to prefer a specific device name.                                 |

Power-profile UI needs `power-profiles-daemon` or `power-profiles` on the system.

## Local development

From a checkout of this repository:

```bash
ln -sfn "$(pwd)/extendable-battery" ~/.config/noctalia/plugins/extendable-battery
```

Enable the plugin in Noctalia, add the bar widget, then symlink and enable provider plugins as needed.

## Provider API

### Live QML registration

```qml
import QtQuick
import qs.Commons
import qs.Services.Noctalia

Item {
  property var devices: []

  Component.onCompleted: {
    const loadedPlugins = PluginService.loadedPlugins || ({});
    const key = Object.keys(loadedPlugins).find(function(candidate) {
      return loadedPlugins[candidate]?.manifest?.id === "extendable-battery";
    });
    const manager = key ? loadedPlugins[key].mainInstance : null;
    if (manager) {
      manager.registerBatteryProvider({
        id: "example",
        name: "Example Provider",
        getDevices: function() { return devices; },
        refresh: function() { /* update devices, then aggregate */ }
      });
    }
  }
}
```

After changing its device list, a live provider should call `manager.aggregateAllDevices()`.

### IPC registration

Requires a running `noctalia-shell` with **Extendable Battery** loaded:

```bash
qs -c noctalia-shell ipc call plugin:extendable-battery registerProvider \
  '{"id":"example","name":"Example Provider","devices":[{"id":"wireless-device-1","name":"Wireless Device","percent":85,"charging":false,"kind":"mouse"}]}'

qs -c noctalia-shell ipc call plugin:extendable-battery get
qs -c noctalia-shell ipc call plugin:extendable-battery refresh
```

If IPC fails, confirm the shell is running and the plugin is enabled (`get` is a good smoke test).

## Device schema

Providers return an array of device objects. The manager normalizes each entry.

**Minimum useful fields:** `id`, `name`, and `percent`. Everything else has defaults or is optional.

| Field                  | Type          | Description                                                  |
| ---------------------- | ------------- | ------------------------------------------------------------ |
| `id`                   | string        | **Required.** Stable physical-device id within the provider. |
| `name`                 | string        | User-visible device name.                                    |
| `percent`              | number        | Charge 0–100, or `-1` if unavailable.                        |
| `present`              | bool          | Device present / connected.                                  |
| `ready`                | bool          | Battery reading is ready.                                    |
| `charging`             | bool          | Actively charging.                                           |
| `pluggedIn`            | bool          | Externally powered but not actively charging.                |
| `timeToFull`           | number        | Seconds until full, or `0` if unknown.                       |
| `timeToEmpty`          | number        | Seconds until empty, or `0` if unknown.                      |
| `changeRate`           | number        | Charge/discharge rate in watts, or `0`.                      |
| `healthSupported`      | bool          | Battery health available.                                    |
| `healthPercentage`     | number        | Battery health percentage.                                   |
| `warningThreshold`     | number        | Provider-owned low-battery threshold.                        |
| `criticalThreshold`    | number        | Provider-owned critical threshold.                           |
| `notificationsEnabled` | bool          | Whether provider battery toasts are enabled.                 |
| `kind`                 | string        | e.g. `laptop`, `keyboard`, `mouse`, `headphones`.            |
| `protocol`             | string        | e.g. `bluez`, `nape`.                                        |
| `transport`            | string        | e.g. `bluetooth`, `hid`, `internal`.                         |
| `status`               | number/string | Provider-specific raw state.                                 |
| `error`                | string        | Reading error, if any.                                       |

`warningThreshold`, `criticalThreshold`, and `notificationsEnabled` may be set on each device or on the provider object; per-device values win. If omitted, defaults are **20%** warning, **5%** critical, and notifications **on**.

## Requirements

- Noctalia Shell **v4.7.7** or newer
- Optional: `power-profiles-daemon` or `power-profiles` for power-profile controls
