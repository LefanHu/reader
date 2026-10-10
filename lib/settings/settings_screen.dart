import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/reader_controller.dart';
import '../identity/cloud_identity_exception.dart';
import '../preferences/library_filter.dart';
import '../preferences/library_sort.dart';
import '../preferences/reading_mode.dart';
import '../preferences/reading_theme.dart';
import '../theme.dart';

import 'account_settings_section.dart';
import 'usage_settings_section.dart';
import 'storage_settings_section.dart';
import 'about_settings_section.dart';
import 'settings_choice_tile.dart';

enum _Section {
  account('Account', Icons.account_circle_outlined),
  appearance('Appearance', Icons.palette_outlined),
  reading('Reading', Icons.menu_book_outlined),
  narration('Narration', Icons.headphones_outlined),
  library('Library', Icons.library_books_outlined),
  usage('Usage & allowance', Icons.data_usage_outlined),
  storage('Storage & privacy', Icons.storage_outlined),
  about('About', Icons.info_outline);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Device-local preferences and account actions; browsing never stops audio.
class SettingsScreen extends StatefulWidget {
  /// Uses the app-lifetime controller so every book shares these preferences.
  const SettingsScreen({super.key, required this.controller});

  /// Shared persistence, account and narration boundary.
  final ReaderController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  _Section? _selected;
  bool _busy = false;
  Future<int>? _cacheSize;
  Future<PackageInfo>? _packageInfo;
  ReaderController get controller => widget.controller;

  void _select(_Section section) {
    setState(() => _selected = section);
    if (section == _Section.usage) controller.refreshAccountUsage();
    if (section == _Section.about) _packageInfo ??= PackageInfo.fromPlatform();
    if (section == _Section.storage) {
      _cacheSize = controller.narrationCacheBytes();
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _preference(action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Preference events must all reach the controller queue, including the final
  // slider event while earlier writes are pending. Only destructive actions lock.
  Future<void> _preference(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (error is CloudIdentityException && error.cancelled) return;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<bool> _confirm(String title, String message, String button) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(button),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        // Large type falls back to one pane rather than squeezing essential labels.
        final wide =
            Theme.of(context).platform == TargetPlatform.macOS &&
            constraints.maxWidth >= 700 &&
            MediaQuery.textScalerOf(context).scale(16) <= 24;
        final selected = _selected ?? (wide ? _Section.account : null);
        return Scaffold(
          appBar: AppBar(
            title: Text(wide || selected == null ? 'Settings' : selected.label),
            leading: BackButton(
              onPressed: () {
                if (!wide && _selected != null) {
                  setState(() => _selected = null);
                } else {
                  Navigator.pop(context);
                }
              },
            ),
          ),
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      SizedBox(
                        width: 240,
                        child: _sections(selected, sidebar: true),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _detail(selected!)),
                    ],
                  )
                : selected == null
                ? _sections(null)
                : _detail(selected),
          ),
        );
      },
    ),
  );

  Widget _sections(_Section? selected, {bool sidebar = false}) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.account_circle_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                controller.cloudEmail ?? 'Your reading room',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                controller.cloudEmail == null
                    ? 'Reading stays offline and account-free.'
                    : 'Preferences are saved on this device.',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      for (final section in _Section.values)
        ListTile(
          // Icon-sized leading slots keep category words intact at narrow/large type.
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          minLeadingWidth: 24,
          horizontalTitleGap: sidebar ? 12 : 8,
          leading: Icon(section.icon),
          title: Text(section.label),
          selected: section == selected,
          trailing: sidebar ? null : const Icon(Icons.chevron_right),
          onTap: () => _select(section),
        ),
    ],
  );

  Widget _detail(_Section section) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (section) {
              _Section.account => [
                AccountSettingsSection(
                  controller: controller,
                  busy: _busy,
                  onSignInOrOut: _signInOrOut,
                  onDeleteAccount: _deleteAccount,
                ),
              ],
              _Section.appearance => _appearance(),
              _Section.reading => _reading(),
              _Section.narration => _narration(),
              _Section.library => _library(),
              _Section.usage => [UsageSettingsSection(controller: controller)],
              _Section.storage => [
                StorageSettingsSection(
                  cacheSize: _cacheSize,
                  busy: _busy,
                  onClearCache: _clearCache,
                ),
              ],
              _Section.about => [
                AboutSettingsSection(
                  packageInfo: _packageInfo,
                  busy: _busy,
                  onResetPreferences: _resetPreferences,
                ),
              ],
            },
          ),
        ),
      ),
    ],
  );

  List<Widget> _appearance() => [
    const Text('Your theme applies throughout the app.'),
    const SizedBox(height: 16),
    for (final value in ReadingTheme.values)
      SettingsChoiceTile<ReadingTheme>(
        value: value,
        selected: controller.preferences.settings.theme,
        title: Text(_title(value.name)),
        preview: buildReaderTheme(value).colorScheme,
        subtitle: Text(switch (value) {
          ReadingTheme.paper => 'Ivory paper · dark ink',
          ReadingTheme.sepia => 'Warm paper · brown ink',
          ReadingTheme.dark => 'Dark surface · light ink',
        }),
        onChanged: (value) {
          _preference(() => controller.preferences.configure(theme: value));
        },
      ),
  ];

  List<Widget> _reading() => [
    for (final value in ReadingMode.values)
      SettingsChoiceTile<ReadingMode>(
        value: value,
        selected: controller.preferences.settings.mode,
        title: Text(
          value == ReadingMode.pageFlip ? 'Page Flip' : _title(value.name),
        ),
        onChanged: (value) {
          _preference(() => controller.preferences.configure(mode: value));
        },
      ),
    SwitchListTile(
      title: const Text('Serif font'),
      subtitle: const Text('Turn off for Sans'),
      value: controller.preferences.settings.serif,
      onChanged: (value) =>
          _preference(() => controller.preferences.configure(serif: value)),
    ),
    Text('Font scale: ${controller.preferences.settings.fontSize}%'),
    Slider(
      value: controller.preferences.settings.fontSize.toDouble(),
      min: 80,
      max: 180,
      divisions: 20,
      label: '${controller.preferences.settings.fontSize}%',
      onChanged: (value) => _preference(
        () => controller.preferences.configure(fontSize: value.round()),
      ),
    ),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'The quiet room held a thousand stories. Outside, the afternoon light settled softly on the leaves.',
          style: TextStyle(
            fontFamily: controller.preferences.settings.serif
                ? 'Lora'
                : 'DM Sans',
            fontSize: 18 * controller.preferences.settings.fontSize / 100,
            height: 1.6,
          ),
        ),
      ),
    ),
  ];

  List<Widget> _narration() => [
    const Text('Voice and speed apply to all books on this device.'),
    const SizedBox(height: 12),
    for (final voice in ['marin', 'cedar'])
      SettingsChoiceTile<String>(
        value: voice,
        selected: controller.preferences.settings.narrationVoice,
        title: Text(_title(voice)),
        onChanged: (value) {
          _preference(
            () => controller.preferences.configure(narrationVoice: value),
          );
        },
      ),
    const Text(
      'Changing voice pauses narration. Press Play to continue; uncached audio consumes allowance.',
    ),
    const SizedBox(height: 20),
    const Text('Playback speed'),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final speed in [.75, 1.0, 1.25, 1.5, 1.75, 2.0])
          ChoiceChip(
            label: Text('$speed×'),
            selected: controller.preferences.settings.narrationSpeed == speed,
            onSelected: (_) => _preference(
              () => controller.preferences.configure(narrationSpeed: speed),
            ),
          ),
      ],
    ),
    const SizedBox(height: 12),
    const Text('Speed changes apply immediately and reuse existing audio.'),
  ];

  List<Widget> _library() => [
    const Text('Default filter'),
    for (final value in LibraryFilter.values)
      SettingsChoiceTile<LibraryFilter>(
        value: value,
        selected: controller.preferences.settings.libraryFilter,
        title: Text(_title(value.name)),
        onChanged: (value) {
          _preference(
            () => controller.preferences.configure(libraryFilter: value),
          );
        },
      ),
    const SizedBox(height: 16),
    const Text('Default sort'),
    for (final value in LibrarySort.values)
      SettingsChoiceTile<LibrarySort>(
        value: value,
        selected: controller.preferences.settings.librarySort,
        title: Text(_title(value.name)),
        onChanged: (value) {
          _preference(
            () => controller.preferences.configure(librarySort: value),
          );
        },
      ),
  ];

  void _signInOrOut() => _action(
    controller.cloudEmail == null
        ? controller.signInToCloud
        : controller.signOutOfCloud,
  );

  void _deleteAccount() => _action(() async {
    if (await _confirm(
      'Delete cloud account?',
      'Reauthenticate with the same Google account to delete cloud data and identity. Your local books and reading positions remain.',
      'Delete cloud account',
    )) {
      await controller.deleteCloudAccount();
    }
  });

  void _clearCache() => _action(() async {
    if (!await _confirm(
      'Clear narration cache?',
      'Playback will stop and downloaded narration will be removed. Books, reading positions and consent remain.',
      'Clear cache',
    )) {
      return;
    }
    await controller.clearNarrationCache();
    if (mounted) {
      // setState must not receive the Future returned by the size lookup.
      setState(() {
        _cacheSize = controller.narrationCacheBytes();
      });
    }
  });

  void _resetPreferences() => _action(() async {
    if (await _confirm(
      'Reset preferences?',
      'Restore device preferences to their defaults. Books, account, consent and caches remain. Narration pauses if its voice changes.',
      'Reset preferences',
    )) {
      await controller.preferences.reset();
    }
  });

  String _title(String value) =>
      '${value[0].toUpperCase()}${value.substring(1)}';
}
