/// Whether one board warns when its pack runs low, below what voltage, and how
/// often it is allowed to say so.
///
/// Kept per board rather than per configuration, because "warn me about this
/// one" is a fact about a board sitting somewhere in the world — the shed door,
/// the boat, the test bench — and not about the calibration that was flashed
/// into it. Two boards off the same image routinely deserve different answers,
/// and a board that is on the bench being poked at should be able to go quiet
/// without changing what the pack is.
///
/// Nothing here reaches the firmware. The board advertises a voltage; deciding
/// that the voltage is bad news, and saying so, is the phone's job.
class DeviceAlertSetting {
  final bool enabled;
  final double thresholdVolts;

  /// How long after a warning before this board may warn again.
  ///
  /// A flat pack stays flat, so without a window every wake below the line
  /// would be another notification and the whole feature would be something to
  /// switch off. One warning per window is the useful reading of "tell me":
  /// the reminder keeps coming until the pack is dealt with, at a rate nobody
  /// would call spam.
  final Duration repeatAfter;

  /// Two hours: long enough that a pack left low overnight produces a handful
  /// of reminders rather than a screenful, short enough that a warning missed
  /// in a meeting comes back the same afternoon.
  static const defaultRepeatAfter = Duration(hours: 2);

  /// What the interval row offers. Wide spread on purpose — a boat checked at
  /// the weekend and a bench board are the same feature at different scales.
  static const repeatChoices = <Duration>[
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
  ];

  const DeviceAlertSetting({
    required this.enabled,
    required this.thresholdVolts,
    this.repeatAfter = defaultRepeatAfter,
  });

  /// What a board the app has never been told about gets: the warning on, at
  /// [thresholdVolts] taken from the configured pack, repeating every two
  /// hours.
  ///
  /// On rather than off, because a board is bought to be left somewhere and
  /// forgotten about — an alert nobody switched on is the alert nobody gets.
  factory DeviceAlertSetting.defaults(double thresholdVolts) =>
      DeviceAlertSetting(enabled: true, thresholdVolts: thresholdVolts);

  DeviceAlertSetting copyWith({
    bool? enabled,
    double? thresholdVolts,
    Duration? repeatAfter,
  }) =>
      DeviceAlertSetting(
        enabled: enabled ?? this.enabled,
        thresholdVolts: thresholdVolts ?? this.thresholdVolts,
        repeatAfter: repeatAfter ?? this.repeatAfter,
      );

  /// "every 2 hours" as the row shows it.
  static String describe(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} d';
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'volts': thresholdVolts,
        'repeatMinutes': repeatAfter.inMinutes,
      };

  factory DeviceAlertSetting.fromJson(Map<String, dynamic> json) {
    final minutes = (json['repeatMinutes'] as num?)?.toInt();
    return DeviceAlertSetting(
      enabled: json['enabled'] as bool? ?? true,
      thresholdVolts: (json['volts'] as num?)?.toDouble() ?? 0,
      repeatAfter: minutes != null && minutes > 0
          ? Duration(minutes: minutes)
          : defaultRepeatAfter,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceAlertSetting &&
      other.enabled == enabled &&
      other.thresholdVolts == thresholdVolts &&
      other.repeatAfter == repeatAfter;

  @override
  int get hashCode => Object.hash(enabled, thresholdVolts, repeatAfter);
}
