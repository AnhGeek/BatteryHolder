import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/board.dart';
import '../../models/firmware_image.dart';
import '../../services/firmware_flasher.dart';

/// Flash firmware to the board over the air — from the cloud catalog or a local file.
class FlashView extends StatefulWidget {
  const FlashView({super.key});

  @override
  State<FlashView> createState() => _FlashViewState();
}

class _FlashViewState extends State<FlashView> {
  List<FirmwareImage> _firmware = [];
  String? _loadError;
  bool _isLoading = false;
  String? _flashError;

  /// The board the current catalog belongs to, so switching boards refetches.
  String? _loadedBoardId;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final board = appState.selectedBoard;

    // The SwiftUI `.task { await loadFirmware(board:) }` equivalent.
    if (board != null && board.id != _loadedBoardId) {
      _loadedBoardId = board.id;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadFirmware(appState, board));
    }

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Flash')),
      body: board == null
          ? const ContentUnavailable(
              title: 'No board selected',
              message: 'Choose a board on the Setup tab first.',
              icon: Icons.arrow_circle_down,
            )
          : _content(context, appState, board),
    );
  }

  Widget _content(BuildContext context, AppState appState, Board board) {
    final c = AppTheme.colorOf(context);

    return SingleChildScrollView(
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FlashProgressCard(
            flasher: appState.flasher,
            transport: appState.activeTransport,
          ),
          SizedBox(height: AppTheme.spacing.lg),

          SectionHeader(
            title: 'Cloud builds',
            subtitle: 'Firmware for ${board.name}',
          ),
          SizedBox(height: AppTheme.spacing.lg),

          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_loadError != null)
            Callout(
              text: _loadError!,
              tint: c.warning,
              icon: Icons.cloud_off,
            )
          else if (_firmware.isEmpty)
            Callout(
              text: 'No builds found. Configure your backend in AppConfig, '
                  'or flash a local file below.',
              tint: c.brand,
              icon: Icons.info,
            )
          else
            for (final image in _firmware) ...[
              _firmwareRow(context, appState, image),
              SizedBox(height: AppTheme.spacing.lg),
            ],

          Padding(
            padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.sm),
            child: const Divider(),
          ),
          SizedBox(height: AppTheme.spacing.lg),

          const SectionHeader(
            title: 'Local file',
            subtitle: 'Flash a .bin from your phone',
          ),
          SizedBox(height: AppTheme.spacing.lg),
          SecondaryButton(
            onPressed: () => _pickAndFlash(appState),
            child: const LabelRow(text: 'Choose .bin file', icon: Icons.folder),
          ),

          if (_flashError != null) ...[
            SizedBox(height: AppTheme.spacing.lg),
            Callout(text: _flashError!, tint: c.danger, icon: Icons.cancel),
          ],
        ],
      ),
    );
  }

  Widget _firmwareRow(
    BuildContext context,
    AppState appState,
    FirmwareImage image,
  ) {
    final c = AppTheme.colorOf(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('v${image.version}',
                  style:
                      AppTheme.font.headline.copyWith(color: c.textPrimary)),
              SizedBox(width: AppTheme.spacing.sm),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: AppTheme.spacing.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radius.pill),
                ),
                child: Text(image.channel.name,
                    style: AppTheme.font.caption.copyWith(color: c.accent)),
              ),
              const Spacer(),
              Text(image.sizeDisplay,
                  style:
                      AppTheme.font.caption.copyWith(color: c.textSecondary)),
            ],
          ),
          if (image.releaseNotes.isNotEmpty) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Text(image.releaseNotes,
                style:
                    AppTheme.font.footnote.copyWith(color: c.textSecondary)),
          ],
          SizedBox(height: AppTheme.spacing.sm),
          ListenableBuilder(
            listenable: appState.flasher,
            builder: (context, _) => PrimaryButton(
              onPressed: appState.flasher.progress.isActive
                  ? null
                  : () => _flashCloud(appState, image),
              child: Text(
                  'Flash over ${appState.activeTransport.displayName}'),
            ),
          ),
        ],
      ),
    );
  }

  // MARK: Actions

  Future<void> _loadFirmware(AppState appState, Board board) async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final images = await appState.firmwareRepo.listFirmware(board.id);
      if (!mounted) return;
      setState(() => _firmware = images);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError =
          "Couldn't reach the firmware catalog. ${describeError(e)}");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _flashCloud(AppState appState, FirmwareImage image) async {
    setState(() => _flashError = null);
    try {
      await appState.flash(image);
    } catch (e) {
      if (!mounted) return;
      setState(() => _flashError = describeError(e));
    }
  }

  Future<void> _pickAndFlash(AppState appState) async {
    setState(() => _flashError = null);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      final file = result?.files.firstOrNull;
      if (file == null) return;

      // `withData` covers content-URI picks; the path is the fallback.
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        setState(() => _flashError = "Couldn't read the selected file.");
        return;
      }

      await appState.flashLocal(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _flashError = describeError(e));
    }
  }
}

/// Observes the flasher and renders live OTA progress.
class _FlashProgressCard extends StatelessWidget {
  final FirmwareFlasher flasher;
  final FlashTransport transport;

  const _FlashProgressCard({required this.flasher, required this.transport});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return ListenableBuilder(
      listenable: flasher,
      builder: (context, _) {
        final p = flasher.progress;
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SectionHeader(
                      title: 'Update status',
                      subtitle: _statusText(p),
                    ),
                  ),
                  TransportBadge(transport: transport),
                ],
              ),
              if (p.isActive || p.fraction > 0) ...[
                SizedBox(height: AppTheme.spacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTheme.radius.pill),
                  child: LinearProgressIndicator(
                    value: p.fraction,
                    minHeight: 4,
                    color: c.brand,
                    backgroundColor: c.border,
                  ),
                ),
                SizedBox(height: AppTheme.spacing.sm),
                Text('${(p.fraction * 100).round()}%',
                    style: AppTheme.font.caption
                        .copyWith(color: c.textSecondary)),
              ],
            ],
          ),
        );
      },
    );
  }

  String _statusText(FlashProgress p) => switch (p.phase) {
        FlashPhase.idle => 'Idle',
        FlashPhase.preparing => 'Preparing…',
        FlashPhase.uploading => 'Uploading…',
        FlashPhase.verifying => 'Verifying…',
        FlashPhase.rebooting => 'Rebooting…',
        FlashPhase.done => 'Complete',
        FlashPhase.failed => p.failureMessage ?? 'Failed',
      };
}
