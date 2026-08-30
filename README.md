# Noctalia Extendable Battery

A Noctalia Shell **v5** plugin source providing a native-style battery widget for Keychron keyboards, mice, and receivers over HID or Bluetooth.

Noctalia v5 replaced QML plugins with sandboxed Luau entries. The previous provider plugin is therefore bundled into one v5 plugin; no installation order or second plugin is required.

## Install

1. Open **Settings → Plugins → Sources**, add this Git source, then refresh:

   ```text
   https://github.com/XYenon/noctalia-extendable-battery
   ```

2. Install and enable **Extendable Battery** (`xyenon/extendable-battery`).
3. Add its battery widget to the bar.
4. For USB or 2.4 GHz devices, install the [udev rule](extendable-battery/README.md#hid-permissions).

Left click keeps the extension's original interaction: it opens a combined battery panel with the system battery followed by Keychron and registered-provider devices. Other gestures retain Noctalia v5's native widget defaults (no right-click action; middle click opens widget settings).

See [the plugin README](extendable-battery/README.md) for settings, diagnostics, and local development.
