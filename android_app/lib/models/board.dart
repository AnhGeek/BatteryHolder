import 'package:flutter/material.dart';

import 'pin.dart';

/// Supported chip families.
///
/// Shadows Material's `Chip` widget, which this app never uses; a file that
/// needs both should import material with `hide Chip`.
enum Chip {
  esp32('ESP32'),
  esp32c3('ESP32-C3'),
  esp32s3('ESP32-S3'),
  esp8266('ESP8266');

  const Chip(this.displayName);
  final String displayName;

  static Chip fromJson(String raw) =>
      Chip.values.firstWhere((c) => c.name == raw, orElse: () => Chip.esp32);
}

/// How the app can talk to / flash a board.
enum FlashTransport {
  ble('Bluetooth', Icons.bluetooth),
  wifi('Wi-Fi', Icons.wifi);

  const FlashTransport(this.displayName, this.icon);
  final String displayName;

  /// Material stand-in for the SF Symbol used on iOS
  /// (`dot.radiowaves.left.and.right` / `wifi`).
  final IconData icon;

  String get id => name;

  static FlashTransport fromJson(String raw) => FlashTransport.values
      .firstWhere((t) => t.name == raw, orElse: () => FlashTransport.ble);
}

/// A board definition loaded from `boards.json`.
class Board {
  final String id;
  final String name;
  final Chip chip;
  final String summary;

  /// ADC resolution in bits (12 on ESP32, 10 on ESP8266).
  final int adcResolutionBits;

  /// Full-scale reference voltage at the ADC pin.
  final double adcRefVoltage;

  /// Preferred default battery pin id.
  final String? recommendedBatteryPinId;

  /// How this board is usually wired, where that is known.
  ///
  /// Only ever a starting point: these are properties of the hardware in
  /// someone's hand, not of the catalog, so they are editable and a null here
  /// means "leave whatever the firmware was built with alone".
  final int? statusLedPin;
  final bool? statusLedActiveLow;
  final int? wakeButtonPin;

  final List<FlashTransport> supportedTransports;
  final List<Pin> pins;

  const Board({
    required this.id,
    required this.name,
    required this.chip,
    required this.summary,
    required this.adcResolutionBits,
    required this.adcRefVoltage,
    this.recommendedBatteryPinId,
    this.statusLedPin,
    this.statusLedActiveLow,
    this.wakeButtonPin,
    required this.supportedTransports,
    required this.pins,
  });

  /// Maximum raw ADC count (e.g. 4095 for 12-bit).
  int get adcMaxCount => (1 << adcResolutionBits) - 1;

  /// Pins the user may pick for battery sensing.
  List<Pin> get adcCapablePins => pins.where((p) => p.supportsADC).toList();

  Pin? get recommendedBatteryPin {
    final id = recommendedBatteryPinId;
    if (id == null) return null;
    return pinWithId(id);
  }

  Pin? pinWithId(String id) {
    for (final p in pins) {
      if (p.id == id) return p;
    }
    return null;
  }

  factory Board.fromJson(Map<String, dynamic> json) => Board(
        id: json['id'] as String,
        name: json['name'] as String,
        chip: Chip.fromJson(json['chip'] as String),
        summary: json['summary'] as String,
        adcResolutionBits: json['adcResolutionBits'] as int,
        adcRefVoltage: (json['adcRefVoltage'] as num).toDouble(),
        recommendedBatteryPinId: json['recommendedBatteryPinId'] as String?,
        statusLedPin: (json['statusLedPin'] as num?)?.toInt(),
        statusLedActiveLow: json['statusLedActiveLow'] as bool?,
        wakeButtonPin: (json['wakeButtonPin'] as num?)?.toInt(),
        supportedTransports: ((json['supportedTransports'] as List?) ?? const [])
            .map((e) => FlashTransport.fromJson(e as String))
            .toList(),
        pins: ((json['pins'] as List?) ?? const [])
            .map((e) => Pin.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  bool operator ==(Object other) => other is Board && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
