import 'package:battery_holder/services/ble_manager.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredDevice deviceSeen(String id, Duration ago) => DiscoveredDevice(
      id: id,
      name: 'BH-$id',
      rssi: -60,
      device: BluetoothDevice.fromId(id),
      hasAdvData: true,
      provisioned: true,
      lastSeen: DateTime.now().subtract(ago),
    );

/// The device list must only show boards that are actually there: a board that
/// stopped advertising is asleep or out of range, and a row for it is a lie.
void main() {
  test('a board advertising right now is reachable and kept', () {
    final device = deviceSeen('aa', Duration.zero);
    expect(device.isReachable, isTrue);
    expect(device.isStale, isFalse);
    expect(BLEManager.keepsDevice(device, null), isTrue);
  });

  test('a board that just went quiet reads asleep before it is dropped', () {
    final device = deviceSeen('bb', const Duration(seconds: 12));
    expect(device.isReachable, isFalse);
    expect(device.isStale, isFalse);
    expect(BLEManager.keepsDevice(device, null), isTrue);
  });

  test('a board quiet past the stale window is dropped from the list', () {
    final device = deviceSeen('cc', const Duration(seconds: 25));
    expect(device.isStale, isTrue);
    expect(BLEManager.keepsDevice(device, null), isFalse);
  });

  // A board stops advertising the moment it accepts a connection, so ageing it
  // out would delete the row the user is working with.
  test('the connected board is kept however long it has been quiet', () {
    final device = deviceSeen('dd', const Duration(minutes: 5));
    expect(device.isStale, isTrue);
    expect(BLEManager.keepsDevice(device, 'dd'), isTrue);
  });
}
