import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app_state.dart';
import 'design_system/theme.dart';
import 'features/root_tab_view.dart';
import 'features/splash_view.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const BatteryHolderApp(),
    ),
  );
}

class BatteryHolderApp extends StatelessWidget {
  const BatteryHolderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BatteryHolder',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      // iOS follows the system appearance; so does this.
      themeMode: ThemeMode.system,
      home: const RootView(),
    );
  }
}

/// Shows the animated splash while the app fetches initial data, then crossfades
/// into the main tab UI once `AppState.bootstrap()` completes.
class RootView extends StatefulWidget {
  const RootView({super.key});

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  @override
  void initState() {
    super.initState();
    // The SwiftUI `.task { await appState.bootstrap() }` equivalent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().bootstrap();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isBootstrapping =
        context.select<AppState, bool>((s) => s.isBootstrapping);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      child: isBootstrapping
          ? const SplashView(key: ValueKey('splash'))
          : const RootTabView(key: ValueKey('root')),
    );
  }
}
