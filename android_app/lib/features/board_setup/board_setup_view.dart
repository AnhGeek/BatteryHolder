import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/board.dart';
import '../pin_config/pin_config_view.dart';

/// Pick the board you're using and the transport you'll talk to it over.
class BoardSetupView extends StatelessWidget {
  const BoardSetupView({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final board = appState.selectedBoard;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Setup')),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(AppTheme.spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Choose your board',
              subtitle: 'Pick the module you wired the battery to.',
            ),
            SizedBox(height: AppTheme.spacing.lg),
            for (final b in appState.boards) ...[
              _BoardCard(
                board: b,
                isSelected: board?.id == b.id,
                onTap: () => appState.selectBoard(b),
              ),
              SizedBox(height: AppTheme.spacing.lg),
            ],
            if (board != null) ...[
              _TransportSection(board: board),
              SizedBox(height: AppTheme.spacing.lg + AppTheme.spacing.sm),
              PrimaryButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PinConfigView()),
                ),
                child: const Text('Configure'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BoardCard extends StatelessWidget {
  final Board board;
  final bool isSelected;
  final VoidCallback onTap;

  const _BoardCard({
    required this.board,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(board.name,
                      style: AppTheme.font.headline
                          .copyWith(color: c.textPrimary)),
                  SizedBox(height: AppTheme.spacing.xs),
                  Text(board.chip.displayName,
                      style: AppTheme.font.caption.copyWith(color: c.brand)),
                  SizedBox(height: AppTheme.spacing.xs),
                  Text(board.summary,
                      style: AppTheme.font.footnote
                          .copyWith(color: c.textSecondary)),
                  SizedBox(height: AppTheme.spacing.xs + AppTheme.spacing.xxs),
                  Wrap(
                    spacing: AppTheme.spacing.xs,
                    runSpacing: AppTheme.spacing.xs,
                    children: [
                      for (final t in board.supportedTransports)
                        TransportBadge(transport: t),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: AppTheme.spacing.md),
            Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? c.brand : c.border,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportSection extends StatelessWidget {
  final Board board;

  const _TransportSection({required this.board});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Transport',
          subtitle: 'How the app talks to this board.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        SegmentedPicker<FlashTransport>(
          options: board.supportedTransports,
          selection: board.supportedTransports.contains(appState.activeTransport)
              ? appState.activeTransport
              : board.supportedTransports.first,
          labelOf: (t) => t.displayName,
          onChanged: (t) => appState.activeTransport = t,
        ),
      ],
    );
  }
}
