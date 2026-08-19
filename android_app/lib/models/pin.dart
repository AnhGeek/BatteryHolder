/// A capability a physical pin can perform.
enum PinCapability {
  adc,
  digitalIn,
  digitalOut,
  touch,
  dac,
  pwm,
  i2c,
  spi,
  uart,
  strapping;

  static PinCapability? fromJson(String raw) {
    for (final c in PinCapability.values) {
      if (c.name == raw) return c;
    }
    return null; // unknown capabilities in boards.json are ignored, not fatal
  }
}

/// A single physical pin on a board, with the metadata the app needs to let the
/// user pick an ADC pin intuitively and safely.
class Pin {
  /// Stable identifier, e.g. "gpio34" or "a0".
  final String id;

  /// Human label, e.g. "GPIO34" or "A0 (ADC0)".
  final String name;

  /// GPIO number when applicable (null for analog-only pins like ESP8266 A0).
  final int? gpio;

  /// ADC channel label, e.g. "ADC1_CH6".
  final String? adcChannel;

  /// ADC unit (1 or 2 on ESP32). ADC2 conflicts with Wi-Fi.
  final int? adcUnit;

  /// True if the pin can only be an input (e.g. GPIO34-39 on ESP32).
  final bool inputOnly;

  /// True if this pin's ADC works while Wi-Fi is active. ESP32 ADC2 pins are false.
  final bool wifiSafeADC;

  /// Everything this pin can do.
  final List<PinCapability> capabilities;

  /// Optional caveat surfaced in the UI (strapping pin, ADC2 note, ...).
  final String? note;

  const Pin({
    required this.id,
    required this.name,
    this.gpio,
    this.adcChannel,
    this.adcUnit,
    required this.inputOnly,
    required this.wifiSafeADC,
    required this.capabilities,
    this.note,
  });

  bool get supportsADC => capabilities.contains(PinCapability.adc);

  factory Pin.fromJson(Map<String, dynamic> json) => Pin(
        id: json['id'] as String,
        name: json['name'] as String,
        gpio: json['gpio'] as int?,
        adcChannel: json['adcChannel'] as String?,
        adcUnit: json['adcUnit'] as int?,
        inputOnly: json['inputOnly'] as bool? ?? false,
        wifiSafeADC: json['wifiSafeADC'] as bool? ?? false,
        capabilities: ((json['capabilities'] as List?) ?? const [])
            .map((e) => PinCapability.fromJson(e as String))
            .whereType<PinCapability>()
            .toList(),
        note: json['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (gpio != null) 'gpio': gpio,
        if (adcChannel != null) 'adcChannel': adcChannel,
        if (adcUnit != null) 'adcUnit': adcUnit,
        'inputOnly': inputOnly,
        'wifiSafeADC': wifiSafeADC,
        'capabilities': capabilities.map((c) => c.name).toList(),
        if (note != null) 'note': note,
      };

  @override
  bool operator ==(Object other) => other is Pin && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
