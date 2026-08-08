# Keychron Launcher Protocol Specifications

Reverse-engineered protocol specifications checked against [Keychron Launcher](https://launcher.keychron.cn/) V1.4.3 and its production JS bundle [`main.e1c0b6933e403941.js`](https://launcher.keychron.cn/main.e1c0b6933e403941.js) on 2026-07-31. The bundle's SHA-256 digest was `7c3b68e67ebb6e6d5c329818b59f4a22ecef9fc8d01cecd640aa4cb1e02c44b2`.

Unless marked as a live capture, the command layouts below are derived from that bundle. Live captures document behavior observed from a Keychron M6 and Keychron Link receiver that the current Launcher bundle does not explicitly decode.

## Transport & Platform Interface

- **Browser WebHID**: Uses `navigator.hid.requestDevice`, `HIDDevice.sendReport`, and `inputreport` event listeners.
- **Linux Native (`/dev/hidraw*`)**:
  - `write()` maps `sendReport(reportId, data)` to `[reportId, ...data]`.
    Linux requires the first byte to be the report-ID selector, including a
    zero byte for an unnumbered report; the WebHID body starts at byte 1.
  - `HIDIOCSFEATURE` and `HIDIOCGFEATURE` use the same leading report-ID
    convention, so their ioctl buffer length is one byte longer than the
    WebHID Feature Report body.

## Device Identification & Filters

Keychron USB Vendor ID: `0x3434`

WebHID device filters:

```js
filters: [
  { usage: 97, usagePage: 65376 }, // 0xFF60 : 0x61  Keyboard Raw HID / NAPE
  { usage: 1, usagePage: 140 }, // 0x008C : 0x01  Mouse RF / Receiver vendor interface
  { usage: 1, usagePage: 65473 }, // 0xFFC1 : 0x01  Mouse vendor collection
  { usage: 1, usagePage: 65290 }, // 0xFF0A : 0x01  Mouse 4K vendor collection
];
```

---

## 1. Keyboard Protocol (NAPE Battery)

NAPE command enumeration:

| Command Name                      | Value (Hex) | Value (Dec) | Description                    |
| --------------------------------- | ----------- | ----------- | ------------------------------ |
| `KC_USER_CMD_NAPE_BAT_REPORT`     | `0x30`      | 48          | Passive / Watch battery report |
| `KC_USER_CMD_NAPE_GET_BAT_REPORT` | `0x31`      | 49          | Query battery status report    |

### Polling Battery Status

Send 32-byte report:

```text
sendReport(reportId = 0, data[32]):
  data[0] = 0xA7
  data[1] = 0x31   (KC_USER_CMD_NAPE_GET_BAT_REPORT)
  data[2..31] = 0x00
```

Response structure:

```text
Filter: response[0] == 0xA7 && response[1] == 0x31
  response[2] = Battery percentage (0 - 100)
  response[3] = Charging status flags
```

---

## 2. Dongle Paired Devices

Launcher uses different commands for keyboard and mouse receiver collections.
For a keyboard Raw HID collection, it sends:

```text
sendReport(reportId = 0, data[32]):
  data[0] = 0xB2
  data[1..31] = 0x00
```

For a mouse or mouse-4K collection, it sends:

```text
sendReport(reportId = 0xB5, data[20]):
  data[0] = 0x03
  data[1..19] = 0x00
```

Response structure:

```text
Filter: response[0] == 0xB2 or response[0] == 0x03
Contains three 5-byte device slots starting at offsets 2, 7, and 12:
  Slot 1: VID = bytes [3, 2],  PID = bytes [5, 4],   status = byte [6]
  Slot 2: VID = bytes [8, 7],  PID = bytes [10, 9],  status = byte [11]
  Slot 3: VID = bytes [13, 12], PID = bytes [15, 14], status = byte [16]
```

VID and PID are stored little-endian in each slot. The byte pairs above show
the high-byte-first order used by Launcher to reconstruct each numeric value.
Slots with a zero status are discarded.

---

## 3. Mouse Protocols

### A. 1K Feature Report (`0x51`)

Send Feature Report `0x51`:

```js
const payload = new Uint8Array(20);
payload[0] = 0x06;
sendFeatureReport(0x51, payload);
```

Response body (when `response[0] == 0x06`):

- `battery_percent` = `response[10]`
- `charging_state` = `response[11] & 0x03`

### B. Mouse Monitor Frames

The current Launcher bundle explicitly decodes the following standard monitor frame:

- **Standard Launcher Monitor Frame (`0xE2`)**:

  ```js
  workMode: report[1]
  connected: report[2]
  power: { state: report[3], value: report[4] }
  dpi: { level: report[5], levelNum: report[7] }
  pollingRate: { level: report[6] }
  ```

- **Keychron Link Receiver Frame (`0xE3`, live M6 capture)**:

  ```text
  E3 00 02 02 4E 00 06 30 2E 31 2E 37 ...   (Discharging: 78%)
  E3 00 02 02 50 01 06 30 2E 31 2E 37 ...   (Charging: 80%)
  │        │  │  │
  │        │  │  └─ Charging flag (0x00 = discharging, 0x01 = charging)
  │        │  └──── Battery percentage (0x4E = 78%, 0x50 = 80%)
  │        └─────── Connection status indicator
  └──────────────── Frame type header (0xE3)
  ```

  The provider uses Feature Report `0x51` with payload `[0x0C, 0x02, 0x11]` as
  a compatibility probe. This sequence was adopted from lightfex's
  [`keychron_battery_display`](https://github.com/lightfex/keychron_battery_display/blob/master/keychron_battery_display.c#L956-L978),
  where the complete command `51 0C 02 11` is named `prepare_24g_cmd` and is
  followed by status command `51 06`, wake command `51 07`, and another
  `51 06`. The names are reverse-engineered semantics from that project, not
  labels from an official Keychron specification. On the tested Keychron Link,
  `51 0C 02 11` elicits the `0xE3` live-capture frame above. The current
  Launcher bundle does not contain or document this exact payload.

### C. 64-Byte Mouse `getPower`

Launcher uses this protocol only for the mouse-4K collection (`usagePage
0xFF0A`). Its detection response identifies 8K Nordic when bytes 6 and 7 are
ASCII `"44"` or `"-6"`; other matching responses use the 4K layout.

Send 64-byte report:

```js
const buffer = new Uint8Array(64);
buffer[0] = 0x01;
buffer[2] = 0x81;
buffer[3] = 0x01;

// If operating in wireless mode:
buffer[0] |= 1 << 6;

// Calculate checksum into buffer[63]:
buffer[63] = (161 - (sum(buffer[0..62]) & 0xff)) & 0xff;
```

Both current layouts filter responses with:

```text
Filter: response[0] == (workMode ? 65 : 1) && response[3] == 1
```

The battery fields depend on the protocol detected for the device:

```text
4K:
  response[5] = Charging state
  response[6] = Battery percentage (0 - 100)

8K Nordic:
  response[10] = Charging state (3 is normalized to 0 by Launcher)
  response[11] = Battery percentage (0 - 100)
```

### D. 8K Feature Report (`0xB3`)

The default 8K protocol uses a 63-byte Feature Report body rather than the
64-byte `getPower` response layout. Launcher uses it for the standard mouse
collection (`usagePage 0xFFC1`) and follows the send with
`receiveFeatureReport(0xB3)`:

```js
const payload = new Uint8Array(63);
payload[0] = 0x06;
sendFeatureReport(0xb3, payload);
```

For a response body with `response[0] == 0x06`, byte 19 packs both fields:

```js
const batteryPercent = response[19] & 0x7f;
const chargingState = (response[19] >> 7) & 0x01;
```

The provider also accepts interrupt responses prefixed with `0xB3`, `0xB4`,
or `0x00 0xB4` for compatibility with devices and Linux hidraw framing. These
prefixes are not response-body layouts decoded by Launcher V1.4.3 itself.

---

## 4. Bluetooth Connection (BlueZ D-Bus)

When connected over Bluetooth Low Energy (BLE), devices export battery level via standard GATT specifications.

- **D-Bus Interface**: `org.bluez.Battery1`
- **Property**: `Percentage` (byte value 0-100)

> **Note**: RF 2.4G communication may time out or fail to respond to NAPE commands when the keyboard or mouse enters sleep mode. Waking up the device by pressing a key before requesting status is recommended. Bluetooth battery reporting via BlueZ is typically available even during partial sleep states if connected.

---

## 5. Product Classification & Metadata Resolution

Device metadata matching works in two stages (mirroring Keychron Launcher logic):

1. **HID Collection Categorization**:
   - `(0x61, 0xFF60)` → Keyboard
   - `(0x01, 0xFFC1)` / `(0x01, 0xFF0A)` → Mouse / Mouse 4K
   - `(0x01, 0x008C)` → Bridge (Receiver / Dongle)

2. **Metadata Catalog Mapping**:
   The bundled catalog is generated from Launcher static JSON assets:
   - Primary: `https://launcher.keychron.cn/static/device/{vpid}/json/v3.json`
   - Fallback: `https://launcher.keychron.cn/static/device/{vpid}/json/v2.json`
     where `vpid = (vid << 16) | pid`.

   Extracted fields are `name` and `type`. Current catalog values for `type`
   are `mouse`, `mouse3`, `trackball`, or an empty string. Launcher commonly
   omits `type` for keyboards, so the provider classifies those by product name.

   Runtime detection reads [`data/launcher-devices.json`](data/launcher-devices.json)
   locally and does not fetch metadata over the network.
