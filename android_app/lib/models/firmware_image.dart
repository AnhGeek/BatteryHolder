enum FirmwareChannel {
  stable,
  beta;

  static FirmwareChannel fromJson(String raw) => FirmwareChannel.values
      .firstWhere((c) => c.name == raw, orElse: () => FirmwareChannel.stable);
}

/// A firmware build from the AWS catalog.
class FirmwareImage {
  final String buildId;
  final String boardId;
  final String version;
  final FirmwareChannel channel;
  final int sizeBytes;
  final String sha256;
  final String releaseNotes;
  final DateTime createdAt;

  /// Presigned download URL (populated by the detail endpoint).
  final Uri? downloadUrl;

  const FirmwareImage({
    required this.buildId,
    required this.boardId,
    required this.version,
    required this.channel,
    required this.sizeBytes,
    required this.sha256,
    required this.releaseNotes,
    required this.createdAt,
    this.downloadUrl,
  });

  String get id => buildId;

  /// Matches iOS `ByteCountFormatter(countStyle: .file)`: decimal units,
  /// no decimals below MB.
  String get sizeDisplay {
    const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
    var value = sizeBytes.toDouble();
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    if (unit == 0) return '$sizeBytes bytes';
    final digits = unit <= 1 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  factory FirmwareImage.fromJson(Map<String, dynamic> json) => FirmwareImage(
        buildId: json['buildId'] as String,
        boardId: json['boardId'] as String,
        version: json['version'] as String,
        channel: FirmwareChannel.fromJson(json['channel'] as String),
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        releaseNotes: json['releaseNotes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        downloadUrl: json['downloadUrl'] == null
            ? null
            : Uri.parse(json['downloadUrl'] as String),
      );
}

/// Phase of an over-the-air flash.
enum FlashPhase { idle, preparing, uploading, verifying, rebooting, done, failed }

/// Progress of an over-the-air flash, published by `FirmwareFlasher`.
class FlashProgress {
  final FlashPhase phase;

  /// 0...1 for the upload portion.
  final double fraction;
  final String message;

  /// Failure text when [phase] is [FlashPhase.failed].
  final String? failureMessage;

  const FlashProgress({
    this.phase = FlashPhase.idle,
    this.fraction = 0,
    this.message = '',
    this.failureMessage,
  });

  bool get isActive => switch (phase) {
        FlashPhase.idle || FlashPhase.done || FlashPhase.failed => false,
        _ => true,
      };

  FlashProgress copyWith({
    FlashPhase? phase,
    double? fraction,
    String? message,
    String? failureMessage,
  }) =>
      FlashProgress(
        phase: phase ?? this.phase,
        fraction: fraction ?? this.fraction,
        message: message ?? this.message,
        failureMessage: failureMessage ?? this.failureMessage,
      );
}
