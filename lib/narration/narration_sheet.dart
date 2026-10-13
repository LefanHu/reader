import 'dart:async';

import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../preferences/reader_preferences_coordinator.dart';
import '../preferences/reader_settings.dart';
import '../text/text_position.dart';
import 'narration_voice.dart';
import 'session.dart';

/// Shows controls before loading or authenticating, so startup is never hidden.
/// A complete [start] begins playback there without committing reading progress.
Future<void> showNarrationSheet(
  BuildContext context,
  ReaderController controller,
  CatalogBook book, {
  TextPosition? start,
}) async {
  if (controller.narration == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Narration is not configured in this build.'),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        NarrationSheet(controller: controller, book: book, start: start),
  );
}

/// Themed listening controls borrowing the app-lifetime narration engine.
/// Only startup/action presentation is local; playback and preferences continue
/// to use the sole shared notifier, [ReaderController].
class NarrationSheet extends StatefulWidget {
  /// An optional [book] is attached after the sheet is visible. Only a cloud
  /// source registers it; on-device synthesis needs no account.
  /// Without it, controls use the already attached session.
  const NarrationSheet({
    super.key,
    required this.controller,
    this.book,
    this.start,
  });

  /// Shared owner of playback, global preferences, and account transactions.
  final ReaderController controller;

  /// Requested publication, also displayed while attachment is pending.
  final CatalogBook? book;

  /// Optional explicit playback start, never a committed reading anchor.
  final TextPosition? start;

  @override
  State<NarrationSheet> createState() => _NarrationSheetState();
}

class _NarrationSheetState extends State<NarrationSheet> {
  bool _opening = false;
  String? _activity;
  String? _actionError;
  Future<void> Function()? _retry;

  @override
  void initState() {
    super.initState();
    if (widget.book != null) {
      _opening = true;
      _activity = 'Preparing listening…';
      unawaited(_open());
    }
  }

  /// Session generations remain authoritative. Dismissing the sheet stops the
  /// startup chain at its next boundary, but never disposes or pauses playback.
  Future<void> _open() async {
    final session = widget.controller.narration!;
    final book = widget.book!;
    setState(() {
      _opening = true;
      _activity = 'Preparing listening…';
      _actionError = null;
      _retry = null;
    });
    try {
      await session.attach(book);
      if (!mounted) return;
      if (session.book?.hash != book.hash) {
        throw StateError('This book is no longer available for listening.');
      }
      if (session.source.requiresCloudRegistration &&
          session.manifest.cloudBookId == null) {
        if (!session.api.configured) {
          throw StateError('Narration is not configured in this build.');
        }
        setState(() => _activity = 'Connecting narration…');
        await widget.controller.registerNarration(book);
      }
      if (!mounted) return;
      if (session.book?.hash != book.hash || !session.ready) {
        throw StateError('This book is no longer available for listening.');
      }
      setState(() {
        _opening = false;
        _activity = null;
      });
      if (widget.start != null) await session.playFrom(widget.start!);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _activity = null;
        _actionError = error.toString();
        _retry = _open;
      });
    }
  }

  /// Surface action failures in the sheet without blocking local reading.
  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _actionError = null;
      _retry = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.toString();
        _retry = () => _perform(action);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final session = controller.narration!;
      final book = widget.book ?? session.book;
      final attached = book != null && session.book?.hash == book.hash;
      final ready = attached && !_opening && session.ready;
      final cloud = session.source.requiresCloudRegistration;
      final ownsPosition = attached && session.ownsPosition(book);
      final error = _actionError ?? (attached ? session.error : null);
      final loading =
          _opening ||
          (attached &&
              session.status == NarrationStatus.buffering &&
              session.error == null);
      final status =
          _activity ??
          (error != null
              ? 'Listening needs attention'
              : !attached
              ? 'Narration stopped'
              : switch (session.status) {
                  NarrationStatus.buffering => 'Loading audio…',
                  NarrationStatus.complete => 'Book complete',
                  NarrationStatus.playing => 'Listening',
                  _ => 'Paused',
                });
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
            maxWidth: 600,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        cloud ? 'AI narration' : 'On-device narration',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (cloud)
                      PopupMenuButton<bool>(
                        tooltip: 'Cloud account',
                        icon: const Icon(Icons.manage_accounts_outlined),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: false, child: Text('Sign out')),
                          PopupMenuItem(
                            value: true,
                            child: Text('Delete cloud account'),
                          ),
                        ],
                        onSelected: (delete) =>
                            _accountAction(context, controller, delete),
                      ),
                    IconButton(
                      tooltip: 'Close listening controls',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: Text(
                    book?.title ?? 'Listening',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (book?.authors.isNotEmpty ?? false) ...[
                  const SizedBox(height: 4),
                  Text(
                    book!.authors.join(', '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _ListeningStatus(
                  status: status,
                  cloud: cloud,
                  loading: loading,
                  error: error,
                  retry: error == null
                      ? null
                      : () {
                          final retry = _retry;
                          if (retry != null) {
                            unawaited(retry());
                          } else if (ready) {
                            unawaited(_perform(session.play));
                          }
                        },
                ),
                const SizedBox(height: 16),
                _TransportControls(
                  session: session,
                  ready: ready,
                  ownsPosition: ownsPosition,
                  perform: _perform,
                ),
                _ListeningPreferences(
                  preferences: controller.preferences,
                  voices: session.source.voices,
                  perform: _perform,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Chapter'),
                  isExpanded: true,
                  items: attached
                      ? session.document?.sections
                            .map(
                              (section) => DropdownMenuItem(
                                value: section.id,
                                child: Text(
                                  section.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList()
                      : null,
                  onChanged: !ready
                      ? null
                      : (id) {
                          if (id == null) return;
                          unawaited(
                            _perform(
                              () =>
                                  controller.narrateChapter(session.book!, id),
                            ),
                          );
                        },
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  !cloud
                      ? 'Speech is generated on this device using installed voices. No cloud account or allowance is needed.'
                      : attached && session.remaining != null
                      ? '${session.remaining} input characters remaining this UTC month'
                      : 'Cached replay is free. Connect to refresh allowance.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (cloud)
                      TextButton(
                        onPressed: !ready
                            ? null
                            : () => _perform(session.refreshAllowance),
                        child: const Text('Refresh allowance'),
                      ),
                    TextButton(
                      onPressed: !ready ? null : () => _perform(session.clear),
                      child: Text(
                        cloud
                            ? 'Clear downloaded audio'
                            : 'Clear narration audio',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Accessible status stays in the sheet through startup and recoverable errors.
class _ListeningStatus extends StatelessWidget {
  const _ListeningStatus({
    required this.status,
    required this.cloud,
    required this.loading,
    required this.error,
    required this.retry,
  });

  final String status;

  /// Local failures must not imply that on-device speech needs a connection.
  final bool cloud;
  final bool loading;
  final String? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('narration-status'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: error == null
              ? colors.surfaceContainerLow
              : colors.errorContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (loading)
                  const SizedBox(
                    key: ValueKey('narration-loading'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    error == null
                        ? Icons.headphones_outlined
                        : Icons.error_outline,
                    color: error == null
                        ? colors.primary
                        : colors.onErrorContainer,
                    size: 22,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    status,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: error == null
                          ? colors.onSurface
                          : colors.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: colors.onErrorContainer)),
              const SizedBox(height: 8),
              Text(
                cloud
                    ? 'Your book remains available to read. Cached audio can be '
                          'played offline; retry when connected.'
                    : 'Your book remains available to read. Choose an installed '
                          'voice and retry; on-device speech needs no connection.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('narration-retry'),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onErrorContainer,
                  ),
                  onPressed: retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Account deletion requires an explicit user action and preserves local books.
Future<void> _accountAction(
  BuildContext context,
  ReaderController controller,
  bool delete,
) async {
  if (delete) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete cloud account?'),
        content: const Text(
          'This deletes your cloud narration, illustrations and account, and clears downloaded narration. Your local books and reading positions remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  try {
    if (delete) {
      await controller.deleteCloudAccount();
    } else {
      await controller.signOutOfCloud();
    }
    if (context.mounted) Navigator.pop(context);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

/// Play/pause, ±15 s seek and stop for the attached publication.
class _TransportControls extends StatelessWidget {
  const _TransportControls({
    required this.session,
    required this.ready,
    required this.ownsPosition,
    required this.perform,
  });

  final NarrationSession session;

  /// Whether the sheet's book is attached, opened and ready to play.
  final bool ready;

  /// Whether listening currently owns the reading position (play vs pause).
  final bool ownsPosition;

  /// Runs an action, surfacing its failure in the sheet.
  final Future<void> Function(Future<void> Function()) perform;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(
        child: Tooltip(
          message: ownsPosition ? 'Pause narration' : 'Play narration',
          child: FilledButton.icon(
            key: const ValueKey('narration-transport'),
            onPressed: !ready
                ? null
                : () => perform(ownsPosition ? session.pause : session.play),
            icon: Icon(ownsPosition ? Icons.pause : Icons.play_arrow),
            label: Text(ownsPosition ? 'Pause' : 'Play'),
          ),
        ),
      ),
      const SizedBox(height: 8),
      // Wrap rather than shrink labels at narrow iOS widths or large
      // accessibility text; every transport target remains reachable.
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          Tooltip(
            message: 'Back 15 seconds',
            child: TextButton.icon(
              onPressed: ready && session.canSeek
                  ? () => perform(
                      () => session.seekBy(const Duration(seconds: -15)),
                    )
                  : null,
              icon: const Icon(Icons.replay),
              label: const Text('−15 sec'),
            ),
          ),
          Tooltip(
            message: 'Forward 15 seconds',
            child: TextButton.icon(
              onPressed: ready && session.canSeek
                  ? () => perform(
                      () => session.seekBy(const Duration(seconds: 15)),
                    )
                  : null,
              icon: const Icon(Icons.forward),
              label: const Text('+15 sec'),
            ),
          ),
          Tooltip(
            message: 'Stop narration',
            child: TextButton.icon(
              onPressed: ready ? () => perform(session.stop) : null,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Global voice and speed; writes the same preferences as Settings.
class _ListeningPreferences extends StatelessWidget {
  const _ListeningPreferences({
    required this.preferences,
    required this.voices,
    required this.perform,
  });

  /// Device-global preference owner shared with the settings screen.
  final ReaderPreferencesCoordinator preferences;

  /// Voices the active narration source can synthesize.
  final List<NarrationVoice> voices;

  /// Runs an action, surfacing its failure in the sheet.
  final Future<void> Function(Future<void> Function()) perform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selectedVoice = preferences.settings.narrationVoice;
    final selectedDescriptor = voices
        .where((voice) => voice.identifier == selectedVoice)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text('Listening preferences', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Voice and speed apply to all books.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(selectedVoice),
          initialValue: selectedVoice,
          isExpanded: true,
          isDense: false,
          itemHeight: null,
          menuMaxHeight: 360,
          decoration: InputDecoration(
            labelText: 'Voice · all books',
            helperText: selectedDescriptor == null
                ? 'Unavailable. Choose an installed voice for new audio.'
                : '${selectedDescriptor.language} · ${selectedDescriptor.quality}',
            helperMaxLines: 3,
          ),
          selectedItemBuilder: (context) => [
            if (selectedDescriptor == null)
              Text(
                'Unavailable: $selectedVoice',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            for (final voice in voices)
              Text(voice.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          items: [
            if (selectedDescriptor == null)
              DropdownMenuItem(
                value: selectedVoice,
                enabled: false,
                child: Text('Unavailable: $selectedVoice'),
              ),
            for (final voice in voices)
              DropdownMenuItem(
                value: voice.identifier,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(voice.name),
                      Text(
                        '${voice.language} · ${voice.quality}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
          onChanged: voices.isEmpty
              ? null
              : (voice) {
                  if (voice == null) return;
                  unawaited(
                    perform(() => preferences.configure(narrationVoice: voice)),
                  );
                },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<double>(
          key: ValueKey(preferences.settings.narrationSpeed),
          initialValue: preferences.settings.narrationSpeed,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Speed · all books'),
          items: narrationSpeeds
              .map(
                (speed) =>
                    DropdownMenuItem(value: speed, child: Text('$speed×')),
              )
              .toList(),
          onChanged: (speed) =>
              perform(() => preferences.configure(narrationSpeed: speed)),
        ),
      ],
    );
  }
}
