import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A lightning-bolt shape matching the app icon, drawn as a vector so it stays
/// crisp at any size (used by the splash and anywhere a brand mark is needed).
class BoltShape {
  /// Normalized silhouette (0...1) mirroring tools/generate_appicon.py.
  static const List<Offset> points = [
    Offset(0.563, 0.02),
    Offset(0.269, 0.558),
    Offset(0.466, 0.558),
    Offset(0.374, 0.98),
    Offset(0.744, 0.414),
    Offset(0.525, 0.414),
    Offset(0.718, 0.02),
  ];

  static Path path(Rect rect) {
    final pts = points
        .map((p) => Offset(rect.left + p.dx * rect.width,
            rect.top + p.dy * rect.height))
        .toList();
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }
}

/// Paints the bolt: an outer glow, a white→amber gradient fill, and a hairline
/// white stroke — the three layers the SwiftUI `AppLogo` composes.
class _BoltPainter extends CustomPainter {
  final double logoSize;

  const _BoltPainter(this.logoSize);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = BoltShape.path(rect);

    // Glow — SwiftUI `.shadow(radius:)` ≈ a Gaussian with sigma radius/2.
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFC246).withValues(alpha: 0.7)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, logoSize * 0.09 / 2),
    );

    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Color(0xFFFFCA3C)],
        ).createShader(rect),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (logoSize * 0.008).clamp(1.0, double.infinity)
        ..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_BoltPainter old) => old.logoSize != logoSize;
}

/// The BatteryHolder brand mark: a glossy glass battery with a green charge
/// level and a glowing lightning bolt. Scales to whatever frame it's given.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    final bodyRadius = BorderRadius.circular(size * 0.16);

    return SizedBox(
      width: size,
      height: size * 1.12,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Terminal nub
          Transform.translate(
            offset: Offset(0, -size * 0.51),
            child: Container(
              width: size * 0.26,
              height: size * 0.10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.03),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFD0E6FF), Color(0xFF24417A)],
                ),
              ),
            ),
          ),

          // Glass body
          Container(
            width: size * 0.78,
            height: size,
            decoration: BoxDecoration(
              borderRadius: bodyRadius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFFD0E6FF).withValues(alpha: 0.85),
                  const Color(0xFF24417A).withValues(alpha: 0.75),
                  const Color(0xFF121E42).withValues(alpha: 0.9),
                ],
              ),
              border: Border.all(
                color: const Color(0xFF96BEFF).withValues(alpha: 0.85),
                width: (size * 0.012).clamp(1.0, double.infinity),
              ),
            ),
          ),

          // Green energy fill (lower portion)
          Transform.translate(
            offset: Offset(0, size * 0.16),
            child: Container(
              width: size * 0.66,
              height: size * 0.56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.11),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF4AE88C), Color(0xFF12965A)],
                ),
              ),
            ),
          ),

          // Top glass sheen, clipped to the body silhouette
          ClipRRect(
            borderRadius: bodyRadius,
            child: SizedBox(
              width: size * 0.78,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.translate(
                    offset: Offset(0, -size * 0.3),
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                          sigmaX: size * 0.05, sigmaY: size * 0.05),
                      child: Container(
                        width: size * 0.7,
                        height: size * 0.28,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(
                              Radius.elliptical(size * 0.35, size * 0.14)),
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Lightning bolt with glow
          CustomPaint(
            size: Size(size * 0.5, size * 0.82),
            painter: _BoltPainter(size),
          ),
        ],
      ),
    );
  }
}
