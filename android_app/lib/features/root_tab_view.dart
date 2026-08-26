import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../design_system/theme.dart';
import 'board_setup/board_setup_view.dart';
import 'devices/device_list_view.dart';
import 'flash/flash_view.dart';
import 'monitor/monitor_view.dart';

/// The four-tab shell, mirroring the SwiftUI `TabView`.
///
/// Each tab keeps its own navigation stack (an `IndexedStack` of `Navigator`s),
/// so pushing Pin config from Setup and switching tabs preserves the stack the
/// way `NavigationStack` per tab does on iOS.
class RootTabView extends StatefulWidget {
  const RootTabView({super.key});

  @override
  State<RootTabView> createState() => _RootTabViewState();
}

class _RootTabViewState extends State<RootTabView> {
  final _navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  static const _tabs = <_TabSpec>[
    _TabSpec('Monitor', Icons.bolt),
    _TabSpec('Devices', Icons.settings_input_antenna),
    _TabSpec('Setup', Icons.memory),
    _TabSpec('Flash', Icons.arrow_circle_down),
  ];

  Widget _rootFor(int index) => switch (index) {
        AppState.monitorTab => const MonitorView(),
        AppState.devicesTab => const DeviceListView(),
        AppState.setupTab => const BoardSetupView(),
        _ => const FlashView(),
      };

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    // The index lives in AppState so a screen inside one tab's stack can send
    // the user to another tab — "Generate BIN file" hands off to Flash.
    final appState = context.watch<AppState>();
    final index = appState.selectedTab;

    return Scaffold(
      backgroundColor: c.background,
      body: IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            Navigator(
              key: _navKeys[i],
              onGenerateRoute: (settings) => MaterialPageRoute(
                settings: settings,
                builder: (_) => _rootFor(i),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.border, width: 0.5)),
        ),
        child: BottomNavigationBar(
          currentIndex: index,
          // Tapping the active tab pops that tab to its root, like iOS.
          onTap: (i) {
            if (i == index) {
              _navKeys[i].currentState?.popUntil((r) => r.isFirst);
            } else {
              appState.selectedTab = i;
            }
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: c.brand,
          unselectedItemColor: c.textSecondary,
          selectedLabelStyle: AppTheme.font.caption,
          unselectedLabelStyle: AppTheme.font.caption,
          items: [
            for (final tab in _tabs)
              BottomNavigationBarItem(
                icon: Icon(tab.icon),
                label: tab.title,
              ),
          ],
        ),
      ),
    );
  }
}

class _TabSpec {
  final String title;
  final IconData icon;
  const _TabSpec(this.title, this.icon);
}
