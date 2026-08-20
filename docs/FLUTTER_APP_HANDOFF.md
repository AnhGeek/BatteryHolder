# Handoff to the Flutter session — device protocol v2

**Firmware changed. The app's connection model has to change with it.**
Read [DEVICE_PROTOCOL.md](DEVICE_PROTOCOL.md) first; this document says what
that means for `android_app/` specifically.

Firmware `2.0.0` (both sketches in [`firmware/`](../firmware)) and the backend
routes in [`backend/src/handler.mjs`](../backend/src/handler.mjs) are already
implemented against the contract below — the app is the remaining half.

---

## 1. The one thing that breaks the current app

**The board is asleep almost all the time.**

`lib/services/ble_manager.dart` today assumes a board that advertises forever,
stays connected until the user leaves, and treats a dropped link as a failure.
None of that holds any more:

- In `ble` mode the board advertises for ~20 s per wake, then deep sleeps for
  `bleWakeSec` (default 5 min). A 15-second `startScan()` that finds nothing is
  now a *normal* result, not an error.
- The board disconnects on its own once the wake window closes. `ConnectionState.failed`
  is the wrong state for that — it needs to read as "board went to sleep".
- Nothing stays connected while the user reads a chart unless the app explicitly
  asks it to (session command `0x01 STAY_AWAKE`).

Everything else in this document follows from those three facts.

---

## 2. Changes to `BLEManager`

### 2.1 New characteristics

Add to `BLEUUID`:

```dart
static final provisioning = Guid('A1B2C3D4-0007-4A5B-8C6D-000000000000');
static final status       = Guid('A1B2C3D4-0008-4A5B-8C6D-000000000000');
static final session      = Guid('A1B2C3D4-0009-4A5B-8C6D-000000000000');
```

### 2.2 Parse the advertisement

The scan result now carries battery + pairing state in manufacturer data
(company `0xFFFF`), so the device list can show a battery pill and an
"Unclaimed" badge before connecting. `DiscoveredDevice` should gain:

```dart
final bool provisioned;   // flags & 0x01
final bool wifiMode;      // flags & 0x02
final bool pairingMode;   // flags & 0x04
final bool wifiOnline;    // flags & 0x08
final double? volts;      // bytes 3..4 uint16 LE / 1000
final int? soc;           // byte 5
```

Layout is in DEVICE_PROTOCOL.md §2.1. Guard on `bytes[0] == 0x42` before
trusting the rest; older v1 boards send no manufacturer data at all.

### 2.3 Subscribe to status, and act on it

Subscribe to `status` on connect and decode each notification as JSON into a
new `DeviceStatus` model (`ev`, `detail`, `id`, `fw`, `mode`, `prov`, `raw`,
`volts`, `soc`, `wifi`, `ip`, `rssi`, `ssid`, `cloud`, `sleepInMs`,
`nextWakeSec`). Expose it as `ValueNotifier<DeviceStatus?>` / a stream —
several screens need it.

Two behaviours hang off it:

1. `ev == "sleeping"` → set a new `ConnectionStatus.sleeping`, **not** `failed`.
2. `sleepInMs` counts down the current wake. Surface it so a screen that needs
   time can top it up.

### 2.4 Session control — the power contract

```dart
Future<void> stayAwake({int seconds = 0}) => _writeSession([0x01, ...uint16LE(seconds)]);
Future<void> sleepNow({int? intervalSec}) => _writeSession([0x02, ...uint32LE(intervalSec ?? 0)]);
Future<void> factoryReset()               => _writeSession([0x03]);
Future<void> setMode(int mode)            => _writeSession([0x04, mode]);
Future<void> forgetWifi()                 => _writeSession([0x05]);
Future<void> identify()                   => _writeSession([0x06]);
```

Rule for the whole app: **any screen that needs a live board calls
`stayAwake(seconds: 0)` on entry and `sleepNow()` on exit.** Monitor, pin
config, and flash screens all qualify. Forgetting the `sleepNow()` leaves the
board burning current until its idle timeout — correct, but wasteful.

Subscribing to the voltage/raw notifications also holds the wake open on its
own (the firmware watches the CCCD), so a monitor screen that calls
`setNotifying(true)` will not be cut off mid-chart. `stayAwake` is still the
explicit contract for screens that read and write without streaming — pin
config and OTA.

Wrap it so it is hard to get wrong:

```dart
Future<T> withAwakeBoard<T>(Future<T> Function() body) async {
  await stayAwake();
  try { return await body(); } finally { await sleepNow(); }
}
```

`uploadFirmware` should use this internally — an OTA that starts 2 seconds
before the wake window closes currently dies mid-transfer.

### 2.5 Provisioning write

```dart
Future<void> provision({
  required String mode,            // 'ble' | 'wifi'
  String? ssid,
  String? password,
  String? backendUrl,
  String? deviceToken,
  int? reportIntervalSec,
}) async { /* write JSON to BLEUUID.provisioning, withoutResponse: false */ }
```

Do **not** await a result from the write itself. The board answers on the
status characteristic, asynchronously: `wifi/connecting` →
`wifi/connected` | `wifi/failed` → `cloud/registered` | `cloud/unreachable` →
`prov/done`. Drive the setup UI off that event stream, and time out after ~40 s.

### 2.6 Scanning

- Raise the scan timeout to at least 30 s, and offer a "keep looking" mode that
  rescans on a loop — the user may have to wait out one sleep cycle.
- Empty result copy: *"No board found. Boards wake up every few minutes — press
  the pairing button on the board to wake it now."* Never "Bluetooth error".

---

## 3. New: `CloudService` (backend client)

New file `lib/services/cloud_service.dart`, using the Cognito JWT the app
already needs for the firmware catalog. Endpoints in DEVICE_PROTOCOL.md §5.

```dart
Future<ClaimResult> claimDevice({required String deviceId, String? name, String? boardId});
Future<List<CloudDevice>> listDevices();
Future<CloudDeviceDetail> getDevice(String deviceId, {int limit = 200});
Future<void> queueCommand(String deviceId, Map<String, dynamic> command);
Future<void> releaseDevice(String deviceId);
```

`ClaimResult` carries `deviceId`, `deviceToken`, `backendUrl`,
`reportIntervalSec`. **The token is returned once and must never be persisted
by the app** — it goes straight into the provisioning write and is then dropped.
Do not log it.

New model `CloudDevice`: `deviceId`, `name`, `boardId`, `transport`,
`reportIntervalSec`, `fw`, `lastSeen`, `online`, `latest` (raw/volts/soc/rssi/ip).

---

## 4. The setup flow (this is the Tuya flow)

> **Superseded as the default path.** A board is set up *before* it is flashed:
> the Configuration screen asks for the run mode, the wake timer and any Wi-Fi
> credentials, and they travel in the calibration region (DEVICE_PROTOCOL.md §6)
> so the board applies them on its first boot and advertises as provisioned.
> Flash → reset → done. The wizard below is the fallback for a board that
> genuinely has no mode: one flashed with "Decide later", one whose pairing
> button was held, or one somebody else flashed. Scanning is otherwise how you
> find a running board to *change* it, not how you bring one up.

One wizard, five steps, from the device list's "Add board":

1. **Scan** — BLE scan, list boards, highlight ones advertising the pairing flag.
2. **Connect** — connect, read `status`, show `id` / `fw` / current battery.
   Call `stayAwake()` immediately: setup must not race the sleep window.
3. **Choose how it reports** — the mode picker:
   - **Bluetooth** — "Readings when your phone is nearby. Longest battery life."
   - **Wi-Fi + cloud** — "Readings even when you're away. Needs your Wi-Fi password."
4. **Wi-Fi branch only** — ask for SSID + password, then:
   ```
   claim  = await cloud.claimDevice(deviceId: status.id, name: userName);
   await ble.provision(
     mode: 'wifi',
     ssid: ssid, password: password,
     backendUrl: claim.backendUrl, deviceToken: claim.deviceToken,
     reportIntervalSec: reportInterval,
   );
   // then follow status events until prov/done or a failure
   ```
   Claim **before** provisioning — the board needs the token in the same write.
   On `wifi/failed`, keep the BLE link open and let the user retype the password;
   the board stays in its previous mode, so nothing is lost.
   For the BLE branch: `await ble.provision(mode: 'ble')`, no cloud call.
5. **Done** — push the `PinConfiguration`, then `sleepNow()` and land on the
   device's detail screen.

SSID entry: on Android you can prefill the currently-connected SSID, but only
with location permission granted and only on the 2.4 GHz network the board can
actually join. Warn when the phone is on a 5 GHz-only network (ESP32/ESP8266
are 2.4 GHz only) — this is the single most common provisioning failure.

---

## 5. Home screen: one list, two kinds of device

The device list should merge:

- **Cloud devices** from `GET /devices` — always present once claimed, showing
  `latest.volts`, `soc`, and `lastSeen`.
- **Nearby BLE devices** from the scan — matched to cloud devices by
  `deviceId` (advertised name suffix ↔ `deviceId` suffix) so one board never
  appears twice.

Per-row state, in priority order:

| State | Condition | Copy |
|---|---|---|
| Nearby | seen in the current BLE scan | "Nearby · 3.94 V" |
| Reporting | `online == true` | "Reporting · 3.94 V · 4 min ago" |
| Asleep | claimed, `lastSeen` within a few cycles | "Asleep · last seen 12 min ago" |
| Silent | `lastSeen` older than ~3 cycles | "Not reporting since 09:14" |
| Unclaimed | advertising with `provisioned == false` | "Unclaimed" — rare, since the image claims the board |

**Never render a sleeping board as an error.**

---

## 6. Monitor screen: three data sources, not one

| Mode | Source | Cadence |
|---|---|---|
| `ble`, board nearby | BLE notifications (existing path) | live, while `stayAwake` is held |
| `wifi`, board on the LAN | `WiFiOTAService` HTTP poll (existing path) | live, only while the board is awake |
| `wifi`, board anywhere | `GET /devices/{id}` history | one point per `reportIntervalSec` |

The cloud path is a **chart of history**, not a live gauge — draw it as stepped
points with real timestamps, and label the gap ("readings every 15 min"). Do not
run a 1-second poll against the cloud; it returns the same row until the board
next wakes.

`WiFiOTAService` needs one fix: its `_pollOnce` currently swallows every error
silently, which makes an asleep board look identical to a network fault. Track
consecutive failures and flip to "board asleep" after a couple of misses, then
back off the timer instead of polling every second into the void.

---

## 7. New screen: Power

Reads/writes the power block (DEVICE_PROTOCOL.md §4) over BLE (via the
provisioning payload's `power` field) or over the cloud (`setPower` command).
Expose in plain language:

- **Reporting interval** — `wifiReportSec` / `bleWakeSec`, as a picker over
  `PowerConfig.intervalOptions` (30 s → 24 h), with an honest battery-life hint.
  The Configuration screen offers the same twelve values before the flash: a
  board must never hold an interval its own settings screen cannot show back.
- **Keep awake while I'm using the app** — `sleepEnabled`, defaulted on.
- **Advanced** — `bleWindowMs`, `bleIdleMs`, `wifiWindowMs`, `bleInWifi`.

Plus destructive actions: **Forget Wi-Fi** (`0x05`), **Factory reset** (`0x03`,
confirm first), **Identify** (`0x06`).

`identify()` resolves to `false` when the board answers `identify/no-led` —
report that instead of a checkmark, or the user stares at hardware that was
never going to light up. `DeviceStatus.hasLed` carries the same fact up front.

---

## 8. Flashing: three paths now

| Path | When | Mechanism |
|---|---|---|
| BLE OTA | board nearby, `ble` mode | existing chunked write — now wrapped in `withAwakeBoard` |
| Local HTTP | board on the same LAN and awake | existing multipart POST |
| **Cloud OTA** | board in `wifi` mode, user anywhere | `queueCommand(deviceId, {'type': 'ota', 'buildId': build.buildId})` |

Cloud OTA is fire-and-forget: the backend mints the presigned URL, the board
pulls it on its next check-in. The UI must say so — *"Update queued. Your board
will install it within 15 minutes."* — and then poll `GET /devices/{id}` for the
`fw` field to change. There is no progress bar for this path; do not fake one.

---

## 9. Commands the app can queue (cloud mode)

`POST /devices/{deviceId}/commands` — `setConfig`, `setPower`, `setMode`,
`identify`, `stayAwake`, `ble`, `ota`. All are deferred to the next check-in;
the response's `deliverWithinSec` is what the UI should quote.

`{"type":"ble","seconds":120}` is worth surfacing as **"Prepare for Bluetooth"**:
it makes a Wi-Fi-mode board open a BLE window at its next wake, which is how the
user reconfigures a board that is out of Wi-Fi range without touching hardware.

---

## 10. Checklist

- [ ] `BLEUUID` gains provisioning / status / session
- [ ] Manufacturer-data parsing in the scan path
- [ ] `DeviceStatus` model + status subscription
- [ ] `ConnectionStatus.sleeping` and its UI treatment everywhere
- [ ] Session commands + `withAwakeBoard` wrapper, applied to monitor/config/OTA
- [ ] `provision()` write + status-event-driven setup wizard
- [ ] `CloudService` + `CloudDevice` model
- [ ] Claim-then-provision order in the Wi-Fi branch; token never persisted
- [ ] Merged device list (cloud ∪ nearby) with the five row states
- [ ] Monitor screen: three sources, honest cadence labels
- [ ] `WiFiOTAService` failure tracking + backoff
- [ ] Power screen
- [ ] Cloud OTA path + "queued" UI
- [ ] 5 GHz-network warning on the SSID step

## 11. ESP8266 boards

The ESP8266 has no Bluetooth, so none of §2 applies to it. It provisions
through an open SoftAP instead: the board hosts `BH-XXXX`, the phone joins that
network, and the app POSTs **the same JSON** to `http://192.168.4.1/api/provision`,
then `POST /api/session` for the session commands. Everything after
provisioning — telemetry, cloud commands, the device list — is identical.

If you are not shipping ESP8266 support in the first release, say so in the
board picker rather than letting the user pick a board the setup flow cannot
finish.

## 12. Compatibility

v1 boards (firmware 1.x) have no `0007`/`0008`/`0009` characteristics and never
sleep. Treat those characteristics as optional: if they are missing after
service discovery, hide the mode picker and the power screen and drive the board
exactly the way the app does today. `BLEException.missingCharacteristic` should
not be thrown for them.
