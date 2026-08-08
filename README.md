# Noctalia Extendable Battery

Custom plugin source for Noctalia Shell **v4.7.7+**:

- [**Extendable Battery**](extendable-battery/README.md) — provider manager, bar widget, panel, and power-profile controls.
- [**Keychron Battery Provider**](keychron-battery-provider/README.md) — Keychron HID and Bluetooth battery backend.

## Install

1. Open **Settings → Plugins → Sources**, add this URL, then refresh plugin sources:

   ```text
   https://github.com/XYenon/noctalia-extendable-battery
   ```

2. Install and enable plugins **in this order** (Noctalia v4 records dependencies but does not install them automatically):

   1. **Extendable Battery**
   2. **Keychron Battery Provider** (optional; only if you use Keychron devices)

3. Add the **Extendable Battery** widget to the bar.

4. For Keychron over USB / 2.4 GHz receiver, install the [udev rule](keychron-battery-provider/README.md#hid-permissions) so your user can open `/dev/hidraw*`.

### Verify

- The bar shows the Extendable Battery widget (or stays hidden if _Hide if not detected_ is on and no battery is present).
- Opening the panel lists the laptop battery (UPower) and any registered provider devices.
- With Keychron: after udev + the provider plugin, run the [CLI diagnostics](keychron-battery-provider/README.md#cli-diagnostics) or check the panel for keyboard/mouse entries.

## Repository layout

```text
registry.json                 # indexes both plugins for Noctalia
extendable-battery/           # plugin id: extendable-battery
keychron-battery-provider/    # plugin id: keychron-battery-provider
```

Directory names match each plugin’s manifest `id`, so Noctalia can install either plugin independently (sparse checkout). See each plugin README for local development, settings, and APIs.
