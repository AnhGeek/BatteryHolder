import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/firmware_bundle.dart';
import 'esp_loader.dart';
import 'serial_console.dart';
import 'usb_serial_port.dart';

/// Where a USB session has got to.
enum UsbFlashPhase {
  idle,
  connecting,
  writing,
  verifying,

  /// Written and checksummed, still sitting in the ROM bootloader.
  ///
  /// The board deliberately stops here. Nothing has rebooted, so an image that
  /// failed to verify never gets a chance to run, and the result of the flash
  /// is on screen while the board is still connected and re-flashable.
  verified,

  rebooting,
  calibrating,
  checking,
  done,
  failed;

  String get displayName => switch (this) {
        UsbFlashPhase.idle => 'Ready',
        UsbFlashPhase.connecting => 'Connecting over USB…',
        UsbFlashPhase.writing => 'Writing firmware…',
        UsbFlashPhase.verifying => 'Verifying what the board stored…',
        UsbFlashPhase.verified => 'Firmware verified — board held in bootloader',
        UsbFlashPhase.rebooting => 'Rebooting the board…',
        UsbFlashPhase.calibrating => 'Sending calibration…',
        UsbFlashPhase.checking => 'Reading the board…',
        UsbFlashPhase.done => 'Board ready',
        UsbFlashPhase.failed => 'Failed',
      };

  bool get isActive =>
      this == UsbFlashPhase.connecting ||
      this == UsbFlashPhase.writing ||
      this == UsbFlashPhase.verifying ||
      this == UsbFlashPhase.rebooting ||
      this == UsbFlashPhase.calibrating ||
      this == UsbFlashPhase.checking;
}

/// One line of the on-screen trace.
class UsbFlashLogEntry {
  final DateTime at;
  final String message;
  final bool isError;

  UsbFlashLogEntry(this.message, {this.isError = false}) : at = DateTime.now();
}

/// Drives a brand-new board from bare metal to calibrated, over the cable.
///
/// A fresh board has no Bluetooth pairing and no Wi-Fi credentials, so USB is
/// the only way in. The sequence is deliberately split in two, with the board
/// parked in its ROM bootloader in between:
///
///  1. [flash] — reset into the bootloader, identify the chip, blank the saved
///     settings, write the bundled images and the calibration region, then read
///     every one of them back and compare checksums. **Nothing reboots.**
///  2. [rebootAndConfirm] — only once step 1 reported success: pulse EN, then
///     hand the same calibration over the serial console and read it back.
///
/// The split exists because a reset is the one irreversible thing in the
/// sequence. A board that rebooted straight after writing takes its USB port
/// with it on native-USB parts, which used to turn "flashed and verified" into
/// "lost connection, no idea what is on it".
class UsbFlashService extends ChangeNotifier {
  UsbFlashPhase _phase = UsbFlashPhase.idle;
  double _progress = 0;
  String? _error;
  final List<UsbFlashLogEntry> _log = [];

  List<UsbSerialDevice> _devices = [];
  UsbSerialDevice? _selected;

  /// The plan whose bytes are confirmed to be on the board right now.
  FlashPlan? _verifiedPlan;

  /// True once every image has been read back off the board and matched.
  bool _firmwareVerified = false;

  /// What the board reported about itself over the serial console.
  Map<String, dynamic>? _boardStatus;

  /// The calibration the board says it is holding.
  Map<String, dynamic>? _boardCalibration;

  UsbFlashPhase get phase => _phase;
  double get progress => _progress;
  String? get error => _error;
  List<UsbFlashLogEntry> get log => List.unmodifiable(_log);
  List<UsbSerialDevice> get devices => List.unmodifiable(_devices);
  UsbSerialDevice? get selectedDevice => _selected;
  Map<String, dynamic>? get boardStatus => _boardStatus;
  Map<String, dynamic>? get boardCalibration => _boardCalibration;

  /// The images on the board matched what was sent, byte for byte.
  bool get firmwareVerified => _firmwareVerified;

  /// A verified board is waiting in the bootloader for the reboot step.
  bool get awaitingReboot =>
      _phase == UsbFlashPhase.verified && _verifiedPlan != null;

  bool get isBusy => _phase.isActive;

  StreamSubscription<void>? _attachSub;

  /// How long an operation waits for a sleeping board to reappear on the port.
  final Duration deviceWait;

  UsbFlashService({this.deviceWait = const Duration(seconds: 90)}) {
    // A board that re-enumerates — after a reset, or after being unplugged and
    // plugged back in — must not leave the screen pointing at a device id that
    // no longer exists. That was the other half of "I can't retry".
    _attachSub = UsbSerialPort.deviceEvents.listen((_) => refreshDevices());
  }

  set selectedDevice(UsbSerialDevice? device) {
    _selected = device;
    notifyListeners();
  }

  /// Re-reads what is plugged into the OTG port.
  Future<void> refreshDevices() async {
    try {
      final found = await UsbSerialPort.list();
      _devices = found;
      // Device ids change across a re-enumeration, so match on what the
      // hardware is rather than on the id we were holding.
      final previous = _selected;
      if (previous != null) {
        _selected = found
            .where((d) =>
                d.deviceId == previous.deviceId ||
                (d.vendorId == previous.vendorId &&
                    d.productId == previous.productId))
            .firstOrNull;
      }
      _selected ??= found.firstOrNull;
    } on UsbSerialException catch (e) {
      _devices = const [];
      _error = e.message;
    }
    notifyListeners();
  }

  /// Writes [plan] and proves it landed. Leaves the board in the bootloader.
  Future<void> flash(FlashPlan plan) async {
    if (isBusy) return;

    _log.clear();
    _error = null;
    _boardStatus = null;
    _boardCalibration = null;
    _firmwareVerified = false;
    _verifiedPlan = null;
    _progress = 0;
    _setPhase(UsbFlashPhase.connecting);

    final port = UsbSerialPort.instance;
    final loader = EspLoader(port: port, onLog: _append);

    try {
      final device = await _claimDevice(wait: deviceWait);
      _append('Using ${device.title} (${device.idsDisplay}, ${device.driver}).');
      await port.open(device.deviceId, baudRate: 115200);

      await loader.connect();
      _assertChipMatches(loader.chip, plan.bundle);

      await loader.prepareFlash(flashSize: _flashSizeBytes(plan.bundle.flashSize));
      await loader.raiseBaudRate(460800);

      _setPhase(UsbFlashPhase.writing);
      await loader.writeSegments(
        plan.segments,
        onProgress: (fraction, _) {
          _progress = fraction;
          notifyListeners();
        },
      );
      _progress = 1;

      // Read everything back before anything is allowed to run.
      _setPhase(UsbFlashPhase.verifying);
      _firmwareVerified = await loader.verifyAll(plan.segments);
      _verifiedPlan = plan;

      _append(_firmwareVerified
          ? 'All ${plan.segments.length} images match what the board is '
              'holding, calibration included.'
          : 'Writing finished. This chip cannot checksum its own flash, so the '
              'write acknowledgements are the confirmation.');
      _append('The board is parked in its bootloader — nothing has rebooted '
          'yet, so you can flash again from here if anything looks wrong.');

      _setPhase(UsbFlashPhase.verified);
    } catch (e) {
      await _fail(e);
      rethrow;
    } finally {
      await loader.dispose();
      await port.close();
    }
  }

  /// Second half: run what was written, then confirm the calibration on the
  /// board that is now running it.
  ///
  /// Only ever reached from a [UsbFlashPhase.verified] state. Losing the port
  /// during the reboot is expected on boards with native USB and is reported as
  /// such — it does not undo a verified flash.
  Future<void> rebootAndConfirm() async {
    final plan = _verifiedPlan;
    if (isBusy || plan == null) return;

    // Every action starts on a clean console, this one included: what matters
    // now is whether the board came back up, not how it was written.
    _log.clear();
    _error = null;
    _setPhase(UsbFlashPhase.rebooting);

    final port = UsbSerialPort.instance;
    final loader = EspLoader(port: port, onLog: _append);
    SerialConsole? console;

    try {
      final device = await _claimDevice();
      await port.open(device.deviceId, baudRate: 115200);
      await loader.hardReset();
      await loader.dispose();
      await port.setBaudRate(115200);

      _setPhase(UsbFlashPhase.calibrating);
      console = SerialConsole(port: port);
      await _handOverCalibration(console, plan);
      _setPhase(UsbFlashPhase.done);
    } catch (e) {
      // The firmware is already verified on the board; only the confirmation
      // failed. Say precisely that instead of throwing the flash away.
      _append(
        '${_describe(e)} The firmware and calibration were already verified in '
        'flash, so the board is running them — this step was only the '
        'read-back.',
        isError: true,
      );
      _append(
        'A board with native USB takes its serial port down when it resets, '
        'and a phone port can brown out as the radios start. Unplug it, plug '
        'it back in, and tap "Check board" to see what it is running.',
      );
      _setPhase(UsbFlashPhase.done);
    } finally {
      await console?.dispose();
      await loader.dispose();
      await port.close();
      await refreshDevices();
    }
  }

  /// Reads the board's flash back and compares it with [plan]. Writes nothing.
  ///
  /// The definitive answer to "is the right image actually on this board": it
  /// asks the chip for checksums of what it is holding, which works whether or
  /// not the firmware boots. It does enter the ROM bootloader to do that — so
  /// the board runs nothing at all while it is being audited — and leaves it
  /// parked there, ready to be rebooted deliberately.
  ///
  /// Blanked regions are skipped: NVS legitimately stops being blank the moment
  /// the board runs.
  Future<void> verifyFlash(FlashPlan plan) async {
    if (isBusy) return;

    _log.clear();
    _error = null;
    _firmwareVerified = false;
    _verifiedPlan = null;
    _progress = 0;
    _setPhase(UsbFlashPhase.connecting);

    final port = UsbSerialPort.instance;
    final loader = EspLoader(port: port, onLog: _append);

    try {
      final device = await _claimDevice(wait: deviceWait);
      await port.open(device.deviceId, baudRate: 115200);
      await loader.connect();
      _assertChipMatches(loader.chip, plan.bundle);
      await loader.prepareFlash(flashSize: _flashSizeBytes(plan.bundle.flashSize));

      _setPhase(UsbFlashPhase.verifying);
      final audited = plan.segments.where((s) => !s.blank).toList();
      _firmwareVerified = await loader.verifyAll(audited);
      _verifiedPlan = plan;

      _append(_firmwareVerified
          ? 'This board is holding exactly the images in the current build, '
              'calibration included. Nothing was written.'
          : 'This chip cannot checksum its own flash, so there is nothing to '
              'compare against.');
      _setPhase(UsbFlashPhase.verified);
    } catch (e) {
      await _fail(e);
    } finally {
      await loader.dispose();
      await port.close();
    }
  }

  /// Asks a board that is already running the firmware what it is and what
  /// calibration it holds. Touches nothing.
  ///
  /// This is the answer to "did that actually work": it needs no reset, no
  /// writing, and works whether or not this app was the one that flashed it.
  Future<void> checkBoard() async {
    if (isBusy) return;

    _log.clear();
    _error = null;
    _boardStatus = null;
    _boardCalibration = null;
    _setPhase(UsbFlashPhase.checking);

    final port = UsbSerialPort.instance;
    SerialConsole? console;
    try {
      final device = await _claimDevice(wait: deviceWait);
      await port.open(device.deviceId, baudRate: 115200);
      console = SerialConsole(port: port);

      final status = await console.waitForBoot();
      _boardStatus = status;
      _append('Running firmware ${status['fw']} · id ${status['id']} · '
          'mode ${status['mode']}');
      final name = status['name'];
      if (name != null) {
        _append(name == status['auto']
            ? 'Answers to $name (its automatic MAC-derived name).'
            : 'Named "$name".');
      }
      _append('Battery ${status['volts']} V (raw ${status['raw']}), '
          'reported ${status['soc']}%');
      final nextWake = status['nextWakeSec'];
      if (nextWake != null) {
        _append(status['usb'] == true
            ? 'Held awake by the USB cable; it would otherwise wake every '
                '${nextWake}s.'
            : 'Wakes every ${nextWake}s and deep sleeps in between.');
      }

      final stored = await console.request({'cmd': 'getcalib'});
      final calibration = stored['calib'];
      if (stored['ok'] == true && calibration is Map) {
        _boardCalibration = Map<String, dynamic>.from(calibration);
        _append('Calibration in flash: pin ${calibration['batteryPinId']}, '
            'divider ${calibration['dividerR1KOhm']}k/'
            '${calibration['dividerR2KOhm']}k, '
            'x${calibration['calibrationFactor']}');
      } else {
        _append('The board reports no calibration in its flash region.',
            isError: true);
      }
      _setPhase(UsbFlashPhase.done);
    } catch (e) {
      await _fail(e);
    } finally {
      await console?.dispose();
      await port.close();
    }
  }

  /// Sends the calibration to a board that is already running the firmware —
  /// no reflash, no reset, just the cable.
  Future<void> sendCalibration(FlashPlan plan) async {
    if (isBusy) return;

    _log.clear();
    _error = null;
    _boardStatus = null;
    _progress = 0;
    _setPhase(UsbFlashPhase.calibrating);

    final port = UsbSerialPort.instance;
    SerialConsole? console;
    try {
      final device = await _claimDevice();
      await port.open(device.deviceId, baudRate: 115200);
      console = SerialConsole(port: port);
      await _handOverCalibration(console, plan, expectReboot: false);
      _setPhase(UsbFlashPhase.done);
    } catch (e) {
      await _fail(e);
      rethrow;
    } finally {
      await console?.dispose();
      await port.close();
    }
  }

  void reset() {
    if (isBusy) return;
    _phase = UsbFlashPhase.idle;
    _progress = 0;
    _error = null;
    _firmwareVerified = false;
    _verifiedPlan = null;
    _log.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _attachSub?.cancel();
    super.dispose();
  }

  // MARK: - Steps

  Future<void> _fail(Object error) async {
    _error = _describe(error);
    _append(_error!, isError: true);
    if (_phase == UsbFlashPhase.writing || _phase == UsbFlashPhase.verifying) {
      // A link that dies mid-transfer is usually the port, not the protocol:
      // phones are stingy with OTG current and an ESP draws bursts.
      _append(
        'If the link dropped mid-transfer, try a powered OTG hub or a board '
        'with its own supply — a phone port often cannot hold up an ESP '
        'through a write.',
      );
    }
    _setPhase(UsbFlashPhase.failed);
    // Whatever went wrong, the next attempt needs a current device list — the
    // board may have re-enumerated under a new id.
    await refreshDevices();
  }

  /// Finds the board, optionally waiting for it to turn up.
  ///
  /// A board that is already running the firmware sleeps between wakes, and on
  /// a chip with native USB that takes the whole USB device down with it — the
  /// port literally disappears from the phone and comes back on the next wake.
  /// Waiting a couple of wake cycles and pouncing the moment it enumerates is
  /// far kinder than telling someone to time a button press. Once it is in the
  /// ROM bootloader it stops sleeping, so catching it once is enough.
  Future<UsbSerialDevice> _claimDevice({
    Duration wait = Duration.zero,
  }) async {
    await refreshDevices();
    if (_selected == null && wait > Duration.zero) {
      _append('No board on the port yet — waiting up to ${wait.inSeconds}s for '
          'it to wake up. Tapping RESET on the board makes it appear now.');
      final deadline = DateTime.now().add(wait);
      while (_selected == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refreshDevices();
      }
    }
    final device = _selected;
    if (device == null) {
      throw const UsbSerialException(
          'No board found on the USB port. Connect it with an OTG adapter and '
          'a cable that carries data, then tap Rescan. A board that is already '
          'running sleeps between wakes and only appears while it is awake — '
          'press RESET on it and try again.');
    }
    if (!device.hasPermission) {
      _append('Asking Android for access to the USB device…');
      final granted = await UsbSerialPort.requestPermission(device.deviceId);
      if (!granted) {
        throw const UsbSerialException('Access to the USB device was declined.');
      }
    }
    return device;
  }

  /// Whether the USB session also provisions the board into Bluetooth mode.
  bool provisionAsBle = true;

  /// Writes the calibration over the console and reads it back.
  Future<void> _handOverCalibration(
    SerialConsole console,
    FlashPlan plan, {
    bool expectReboot = true,
  }) async {
    if (expectReboot) {
      _append('Waiting for the board to come up…');
      // The sketch prints its boot log first; give it room before asking.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    final hello = await console.waitForBoot();
    _boardStatus = hello;
    _append('Board says: ${hello['name'] ?? hello['id']} · fw ${hello['fw']} · '
        'mode ${hello['mode']}');

    final payload = Map<String, dynamic>.from(plan.calibrationPayload);
    final stamp = payload.remove('stamp');
    final reply = await console.request({
      'cmd': 'calib',
      'stamp': stamp,
      'config': payload,
    });
    if (reply['ok'] != true) {
      throw SerialConsoleException(
          'The board rejected the calibration: ${reply['detail'] ?? 'no reason given'}');
    }
    _append('Calibration accepted and stored in flash.');

    final stored = await console.request({'cmd': 'getcalib'});
    final calibration = stored['calib'];
    if (stored['ok'] == true && calibration is Map) {
      _boardCalibration = Map<String, dynamic>.from(calibration);
      _append('Board confirms pin ${calibration['batteryPinId']}, '
          'divider ${calibration['dividerR1KOhm']}k/'
          '${calibration['dividerR2KOhm']}k, '
          'x${calibration['calibrationFactor']}.');
    }

    if (provisionAsBle) await _provisionOverConsole(console);

    _boardStatus = await console.request({'cmd': 'status'});
  }

  /// Claims the board into Bluetooth mode over the cable.
  ///
  /// The same handler the BLE provisioning characteristic runs, reached through
  /// the serial console — so a board comes out of the USB session already set
  /// up, instead of sitting in pairing mode waiting to be asked the one
  /// question the cable could have asked itself.
  Future<void> _provisionOverConsole(SerialConsole console) async {
    try {
      final reply = await console.request({'cmd': 'prov', 'mode': 'ble'});
      if (reply['ok'] != true) {
        _append('The board did not take Bluetooth mode over USB; set it up '
            'from the Devices tab instead.');
        return;
      }
      _append('Set to Bluetooth mode — no Devices setup needed.');
    } on SerialConsoleException {
      _append('Could not set the run mode over USB; the Devices tab still '
          'can.');
    }
  }

  void _assertChipMatches(EspChip detected, FirmwareBundle bundle) {
    final expected = switch (bundle.chip) {
      'esp32' => EspChip.esp32,
      'esp32c3' => EspChip.esp32c3,
      'esp32s3' => EspChip.esp32s3,
      'esp8266' => EspChip.esp8266,
      _ => EspChip.unknown,
    };
    if (expected == EspChip.unknown || detected == expected) return;
    throw EspLoaderException(
      'This is a ${detected.displayName}, but the selected board is a '
      '${bundle.name}. Pick the matching board on the Setup tab — flashing the '
      'wrong image would leave it unbootable. Nothing was written.',
    );
  }

  static int _flashSizeBytes(String size) {
    final match = RegExp(r'(\d+)\s*MB', caseSensitive: false).firstMatch(size);
    final megabytes = int.tryParse(match?.group(1) ?? '') ?? 4;
    return megabytes * 1024 * 1024;
  }

  static String _describe(Object error) => switch (error) {
        EspLoaderException e => e.message,
        UsbSerialException e => e.message,
        SerialConsoleException e => e.message,
        _ => error.toString(),
      };

  void _append(String message, {bool isError = false}) {
    _log.add(UsbFlashLogEntry(message, isError: isError));
    if (_log.length > 200) _log.removeAt(0);
    notifyListeners();
  }

  void _setPhase(UsbFlashPhase phase) {
    _phase = phase;
    notifyListeners();
  }
}
