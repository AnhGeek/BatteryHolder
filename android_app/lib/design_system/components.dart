import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/board.dart';
import '../models/pin.dart';
import 'theme.dart';

// MARK: - Card

/// Surface container carrying the `card` elevation token — the SwiftUI `Card`.
class AppCard extends StatelessWidget {
  final Widget child;

  const AppCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius.lg),
        // Dark mode leans on surface lightness instead of shadow.
        boxShadow: c.isDark ? null : AppTheme.elevation.card,
      ),
      child: child,
    );
  }
}

// MARK: - Buttons

/// Full-width filled button — port of `PrimaryButtonStyle`.
class PrimaryButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  /// Mirrors the Swift style's `enabled` flag: dims to 40% without changing
  /// layout. A null [onPressed] disables the button too.
  final bool enabled;

  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.enabled = true,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final active = widget.enabled && widget.onPressed != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: active ? (_) => setState(() => _pressed = true) : null,
      onTapUp: active ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: active ? () => setState(() => _pressed = false) : null,
      onTap: active ? widget.onPressed : null,
      child: Opacity(
        opacity: active ? 1 : 0.4,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.md),
          decoration: BoxDecoration(
            color: _pressed ? c.brandPressed : c.brand,
            borderRadius: BorderRadius.circular(AppTheme.radius.md),
          ),
          child: DefaultTextStyle(
            style: AppTheme.font.headline.copyWith(color: c.textOnBrand),
            textAlign: TextAlign.center,
            child: IconTheme(
              data: IconThemeData(color: c.textOnBrand, size: 20),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tinted low-emphasis button — port of `SecondaryButtonStyle`.
class SecondaryButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const SecondaryButton({
    super.key,
    required this.onPressed,
    required this.child,
  });

  @override
  State<SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<SecondaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final active = widget.onPressed != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: active ? (_) => setState(() => _pressed = true) : null,
      onTapUp: active ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: active ? () => setState(() => _pressed = false) : null,
      onTap: widget.onPressed,
      child: Opacity(
        opacity: active ? 1 : 0.4,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.md),
          decoration: BoxDecoration(
            color: c.brand.withValues(alpha: _pressed ? 0.2 : 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radius.md),
          ),
          child: DefaultTextStyle(
            style: AppTheme.font.headline.copyWith(color: c.brand),
            textAlign: TextAlign.center,
            child: IconTheme(
              data: IconThemeData(color: c.brand, size: 20),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The SwiftUI `Label` pairing: icon leading, text trailing.
class LabelRow extends StatelessWidget {
  final String text;
  final IconData icon;

  const LabelRow({super.key, required this.text, required this.icon});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          SizedBox(width: AppTheme.spacing.sm),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
        ],
      );
}

// MARK: - Section header

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const SectionHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title,
            style: AppTheme.font.headline.copyWith(color: c.textPrimary)),
        if (subtitle != null) ...[
          SizedBox(height: AppTheme.spacing.xxs),
          Text(subtitle!,
              style: AppTheme.font.footnote.copyWith(color: c.textSecondary)),
        ],
      ],
    );
  }
}

// MARK: - Stat pill

class StatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color? tint;

  const StatPill({
    super.key,
    required this.label,
    required this.value,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final color = tint ?? c.brand;
    return Container(
      padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radius.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.font.mono.copyWith(color: color)),
          SizedBox(height: AppTheme.spacing.xxs),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.font.caption.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }
}

// MARK: - Pin chip

class PinChip extends StatelessWidget {
  final Pin pin;
  final bool isSelected;

  const PinChip({super.key, required this.pin, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final fg = isSelected ? c.textOnBrand : c.textPrimary;

    return Opacity(
      opacity: pin.supportsADC ? 1 : 0.35,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: AppTheme.spacing.md,
          vertical: AppTheme.spacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? c.brand : c.surfaceElevated,
          borderRadius: BorderRadius.circular(AppTheme.radius.sm),
          // Pins whose ADC stops working with Wi-Fi on get a warning hairline.
          border: Border.all(
            color: pin.wifiSafeADC
                ? Colors.transparent
                : c.warning.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              pin.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.font.caption
                  .copyWith(fontWeight: FontWeight.w600, color: fg),
            ),
            if (pin.adcChannel != null) ...[
              const SizedBox(height: 2),
              Text(
                pin.adcChannel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: fg.withValues(alpha: 0.7)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// MARK: - Battery gauge

/// Ring gauge with a rounded progress cap, sweeping clockwise from 12 o'clock.
class BatteryGauge extends StatelessWidget {
  /// 0...1
  final double fraction;
  final Color color;

  const BatteryGauge({super.key, required this.fraction, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction.clamp(0.001, 1.0)),
      duration: Motion.standard,
      curve: Curves.easeOut,
      builder: (context, value, _) => CustomPaint(
        painter: _GaugePainter(fraction: value, color: color, track: c.border),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color track;

  const _GaugePainter({
    required this.fraction,
    required this.color,
    required this.track,
  });

  static const _lineWidth = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      _lineWidth / 2,
      _lineWidth / 2,
      size.width - _lineWidth,
      size.height - _lineWidth,
    );

    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _lineWidth
        ..color = track,
    );

    canvas.drawArc(
      rect,
      -math.pi / 2, // start at 12 o'clock, like `.rotationEffect(-90°)`
      math.pi * 2 * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _lineWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

// MARK: - Sparkline

class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color? color;

  const Sparkline({super.key, required this.values, this.color});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return CustomPaint(
      painter: _SparklinePainter(values: values, color: color ?? c.brand),
      child: const SizedBox.expand(),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  const _SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final pts = _points(size);
    if (pts.isEmpty) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  List<Offset> _points(Size size) {
    if (values.length < 2) return const [];
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final range = math.max(0.0001, maxV - minV);
    final stepX = size.width / (values.length - 1);
    return [
      for (var i = 0; i < values.length; i++)
        Offset(i * stepX, size.height * (1 - (values[i] - minV) / range)),
    ];
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color || old.values != values;
}

// MARK: - Transport badge

class TransportBadge extends StatelessWidget {
  final FlashTransport transport;

  const TransportBadge({super.key, required this.transport});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppTheme.spacing.sm,
        vertical: AppTheme.spacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(transport.icon, size: 12, color: c.brand),
          SizedBox(width: AppTheme.spacing.xs),
          Text(
            transport.displayName,
            style: AppTheme.font.caption
                .copyWith(fontWeight: FontWeight.w600, color: c.brand),
          ),
        ],
      ),
    );
  }
}

// MARK: - Callout

/// Tinted inline note — port of the SwiftUI `Callout`.
class Callout extends StatelessWidget {
  final String text;
  final Color? tint;
  final IconData icon;

  const Callout({
    super.key,
    required this.text,
    this.tint,
    this.icon = Icons.info,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final color = tint ?? c.brand;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(AppTheme.spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: AppTheme.spacing.sm),
          Expanded(
            child: Text(text,
                style: AppTheme.font.footnote.copyWith(color: c.textPrimary)),
          ),
        ],
      ),
    );
  }
}

// MARK: - Empty state

/// Port of the iOS `ContentUnavailableViewCompat`.
class ContentUnavailable extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;

  const ContentUnavailable({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppTheme.spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: c.textSecondary),
            SizedBox(height: AppTheme.spacing.md),
            Text(title,
                style: AppTheme.font.headline.copyWith(color: c.textPrimary)),
            SizedBox(height: AppTheme.spacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// MARK: - Segmented picker

/// iOS-style segmented control, standing in for `.pickerStyle(.segmented)`.
class SegmentedPicker<T> extends StatelessWidget {
  final List<T> options;
  final T selection;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  const SegmentedPicker({
    super.key,
    required this.options,
    required this.selection,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.isDark ? c.surfaceElevated : const Color(0xFFE3E3E8),
        borderRadius: BorderRadius.circular(AppTheme.radius.sm),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(option),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: Motion.quick,
                  padding:
                      EdgeInsets.symmetric(vertical: AppTheme.spacing.sm - 2),
                  decoration: BoxDecoration(
                    color: option == selection ? c.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppTheme.radius.sm - 2),
                    boxShadow: option == selection && !c.isDark
                        ? AppTheme.elevation.card
                        : null,
                  ),
                  child: Text(
                    labelOf(option),
                    textAlign: TextAlign.center,
                    style: AppTheme.font.subheadline.copyWith(
                      color: c.textPrimary,
                      fontWeight: option == selection
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
