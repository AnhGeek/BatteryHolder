import 'package:battery_holder/models/firmware_bundle.dart';
import 'package:battery_holder/services/usb_flash_service.dart';
import 'package:battery_holder/services/usb_serial_port.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything here is about the two things that must never happen: rebooting a
/// board before its firmware has been checked, and a failure leaving the screen
/// unable to try again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('store.lyhoanganh.battery_holder/usb_serial');
  const deviceEvents =
      MethodChannel('store.lyhoanganh.battery_holder/usb_serial/devices');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<Map<String, Object?>> attached = [];

  setUp(() {
    attached = [];
    messenger.setMockMethodCallHandler(method, (call) async {
      return switch (call.method) {
        'list' => attached,
        'close' => true,
        _ => null,
      };
    });
    // The attach/detach stream is a broadcast EventChannel; accepting listen
    // keeps it quiet in tests.
    messenger.setMockMethodCallHandler(deviceEvents, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockMethodCallHandler(deviceEvents, null);
  });

  FlashPlan planFor() => FlashPlan(
        bundle: const FirmwareBundle(
          boardId: 'esp32-wroom',
          name: 'ESP32 DevKitC (WROOM-32)',
          chip: 'esp32',
          sketch: 'battery_holder_node',
          fqbn: 'esp32:esp32:esp32',
          flashMode: 'dio',
          flashFreq: '80m',
          flashSize: '4MB',
          parts: [],
          calibration: FlashRegion(offset: 0x3D0000, size: 4096),
        ),
        segments: const [],
        calibrationPayload: const {'batteryPinId': 'gpio34', 'stamp': 1},
      );

  test('a board is never rebooted before a verified write', () async {
    final service = UsbFlashService(deviceWait: Duration.zero);
    addTearDown(service.dispose);

    expect(service.awaitingReboot, isFalse);
    await service.rebootAndConfirm();

    // Nothing to reboot into, so nothing happened at all.
    expect(service.phase, UsbFlashPhase.idle);
    expect(service.log, isEmpty);
  });

  test('a failed flash stays retryable and says what to do', () async {
    final service = UsbFlashService(deviceWait: Duration.zero);
    addTearDown(service.dispose);

    await expectLater(
      service.flash(planFor()),
      throwsA(isA<UsbSerialException>()),
    );

    expect(service.phase, UsbFlashPhase.failed);
    expect(service.isBusy, isFalse, reason: 'the buttons have to come back');
    expect(service.firmwareVerified, isFalse);
    expect(service.awaitingReboot, isFalse,
        reason: 'a failed write must not offer to reboot the board');
    expect(service.error, contains('OTG'));
  });

  test('a board that re-enumerates is picked up by what it is, not its id',
      () async {
    final service = UsbFlashService(deviceWait: Duration.zero);
    addTearDown(service.dispose);

    attached = [
      {
        'deviceId': 1001,
        'vid': 0x10C4,
        'pid': 0xEA60,
        'driver': 'cp210x',
        'hasPermission': true,
      }
    ];
    await service.refreshDevices();
    expect(service.selectedDevice?.deviceId, 1001);

    // Same board back after a reset, under a fresh device id.
    attached = [
      {
        'deviceId': 1002,
        'vid': 0x10C4,
        'pid': 0xEA60,
        'driver': 'cp210x',
        'hasPermission': true,
      }
    ];
    await service.refreshDevices();

    expect(service.selectedDevice?.deviceId, 1002,
        reason: 'the selection must follow the hardware, not the stale id');
  });

  test('unplugging clears the selection instead of holding a dead handle',
      () async {
    final service = UsbFlashService(deviceWait: Duration.zero);
    addTearDown(service.dispose);

    attached = [
      {
        'deviceId': 7,
        'vid': 0x1A86,
        'pid': 0x7523,
        'driver': 'ch34x',
        'hasPermission': false,
      }
    ];
    await service.refreshDevices();
    expect(service.selectedDevice, isNotNull);

    attached = [];
    await service.refreshDevices();
    expect(service.selectedDevice, isNull);
    expect(service.devices, isEmpty);
  });
}
