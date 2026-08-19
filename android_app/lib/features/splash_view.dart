import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../design_system/app_logo.dart';
import '../design_system/theme.dart';

/// Launch/splash screen shown while the app warms up and fetches initial data.
///
/// The duration is *not* fixed: it stays visible until `AppState.bootstrap()`
/// finishes (a real network warm-up with a soft timeout), so it lasts a few
/// seconds at most and disappears as soon as data is ready.
class SplashView extends StatefulWidget {
  const SplashView({super.key});

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, String>((s) => s.bootstrapStatus);
    // The splash is always dark, matching the iOS gradient regardless of theme.
    const brand = Color(0xFF0A84FF);

    return Scaffold(
      backgroundColor: const Color(0xFF03060F),
      body: Stack(
        children: [
          // Background: vertical gradient plus a brand-tinted radial glow.
          const Positioned.fill(child: _SplashBackground()),

          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(AppTheme.spacing.xl),
                child: Column(
                  children: [
                    const Spacer(),
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, child) {
                        final t = Curves.easeInOut.transform(_pulse.value);
                        return Transform.scale(
                          // 0.98 → 1.04, the SwiftUI `logoPulse` range.
                          scale: 0.98 + 0.06 * t,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: brand.withValues(
                                      alpha: 0.2 + 0.35 * t),
                                  blurRadius: 22 + 22 * t,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: child,
                          ),
                        );
                      },
                      child: const AppLogo(size: 132),
                    ),
                    SizedBox(height: AppTheme.spacing.xl),
                    const Text(
                      'BatteryHolder',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: AppTheme.spacing.xs),
                    Text(
                      'ESP32 · ESP8266 battery tools',
                      style: AppTheme.font.footnote.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const Spacer(),
                    const _LoadingDots(),
                    SizedBox(height: AppTheme.spacing.md),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        status,
                        key: ValueKey(status),
                        style: AppTheme.font.subheadline.copyWith(
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    SizedBox(height: AppTheme.spacing.xxxl),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SplashBackground extends StatelessWidget {
  const _SplashBackground();

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0E2052), Color(0xFF091438), Color(0xFF03060F)],
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              // Centered slightly above the middle, like the SwiftUI version.
              center: const Alignment(0, -0.2),
              radius: 0.9,
              colors: [
                const Color(0xFF0A84FF).withValues(alpha: 0.35),
                const Color(0x000A84FF),
              ],
            ),
          ),
        ),
      );
}

/// An indeterminate three-dot loader that animates continuously while data loads.
class _LoadingDots extends StatefulWidget {
  const _LoadingDots();

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // One cycle covers the 0.6s pulse plus the largest 0.36s stagger.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF30D158);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Builder(builder: (context) {
              // Each dot lags the previous by 0.18s, as in SwiftUI's `.delay`.
              final phase = (_controller.value - i * 0.15) % 1.0;
              // Triangle wave 0 → 1 → 0, eased, so the dot swells and fades.
              final t = Curves.easeInOut
                  .transform(phase <= 0.5 ? phase * 2 : (1 - phase) * 2);
              return Opacity(
                opacity: 0.4 + 0.6 * t,
                child: Transform.scale(
                  scale: 0.4 + 0.6 * t,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent,
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
