import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'cloud_identity.dart';
import 'controller.dart';
import 'models.dart';
import 'theme.dart';
import 'account/api.dart';

/// Opens one settings route per navigator, including native menu requests.
class SettingsNavigation {
  static final Map<NavigatorState, Future<void>> _routes = {};

  /// Repeated requests keep the current page and its in-progress actions intact.
  static Future<void> open(
    NavigatorState navigator,
    ReaderController controller,
  ) {
    final existing = _routes[navigator];
    if (existing != null) return existing;
    final route = navigator.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/settings'),
        builder: (_) => SettingsScreen(controller: controller),
      ),
    );
    final completion = route.then<void>((_) {}).whenComplete(() {
      _routes.remove(navigator);
    });
    _routes[navigator] = completion;
    return completion;
  }
}

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
              _Section.account => _account(),
              _Section.appearance => _appearance(),
              _Section.reading => _reading(),
              _Section.narration => _narration(),
              _Section.library => _library(),
              _Section.usage => _usage(),
              _Section.storage => _storage(),
              _Section.about => _about(),
            },
          ),
        ),
      ),
    ],
  );

  List<Widget> _account() => [
    Text(
      controller.cloudEmail ?? 'You are signed out',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 12),
    const Text(
      'Sign in to use cloud features. Importing and reading never require an account.',
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy || controller.cloudAccountBusy
          ? null
          : () => _action(
              controller.cloudEmail == null
                  ? controller.signInToCloud
                  : controller.signOutOfCloud,
            ),
      child: Text(
        controller.cloudEmail == null ? 'Sign in with Google' : 'Sign out',
      ),
    ),
    if (controller.cloudEmail != null) ...[
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed:
            _busy ||
                controller.cloudAccountBusy ||
                !(controller.narration?.api.configured == true ||
                    controller.illustrationsConfigured)
            ? null
            : () => _action(() async {
                if (await _confirm(
                  'Delete cloud account?',
                  'Reauthenticate with the same Google account to delete cloud data and identity. Your local books and reading positions remain.',
                  'Delete cloud account',
                )) {
                  await controller.deleteCloudAccount();
                }
              }),
        child: const Text('Delete cloud account'),
      ),
      if (!(controller.narration?.api.configured == true ||
          controller.illustrationsConfigured))
        const Text(
          'Cloud account deletion requires a configured service connection.',
        ),
    ],
  ];

  List<Widget> _appearance() => [
    const Text('Your theme applies throughout the app.'),
    const SizedBox(height: 16),
    for (final value in ReadingTheme.values)
      _choice<ReadingTheme>(
        value: value,
        selected: controller.settings.theme,
        title: Text(_title(value.name)),
        preview: buildReaderTheme(value).colorScheme,
        subtitle: Text(switch (value) {
          ReadingTheme.paper => 'Ivory paper · dark ink',
          ReadingTheme.sepia => 'Warm paper · brown ink',
          ReadingTheme.dark => 'Dark surface · light ink',
        }),
        onChanged: (value) {
          _preference(() => controller.configure(theme: value));
        },
      ),
  ];

  List<Widget> _reading() => [
    for (final value in ReadingMode.values)
      _choice<ReadingMode>(
        value: value,
        selected: controller.settings.mode,
        title: Text(
          value == ReadingMode.pageFlip ? 'Page Flip' : _title(value.name),
        ),
        onChanged: (value) {
          _preference(() => controller.configure(mode: value));
        },
      ),
    SwitchListTile(
      title: const Text('Serif font'),
      subtitle: const Text('Turn off for Sans'),
      value: controller.settings.serif,
      onChanged: (value) =>
          _preference(() => controller.configure(serif: value)),
    ),
    Text('Font scale: ${controller.settings.fontSize}%'),
    Slider(
      value: controller.settings.fontSize.toDouble(),
      min: 80,
      max: 180,
      divisions: 20,
      label: '${controller.settings.fontSize}%',
      onChanged: (value) =>
          _preference(() => controller.configure(fontSize: value.round())),
    ),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'The quiet room held a thousand stories. Outside, the afternoon light settled softly on the leaves.',
          style: TextStyle(
            fontFamily: controller.settings.serif ? 'Lora' : 'DM Sans',
            fontSize: 18 * controller.settings.fontSize / 100,
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
      _choice<String>(
        value: voice,
        selected: controller.settings.narrationVoice,
        title: Text(_title(voice)),
        onChanged: (value) {
          _preference(() => controller.configure(narrationVoice: value));
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
            selected: controller.settings.narrationSpeed == speed,
            onSelected: (_) =>
                _preference(() => controller.configure(narrationSpeed: speed)),
          ),
      ],
    ),
    const SizedBox(height: 12),
    const Text('Speed changes apply immediately and reuse existing audio.'),
  ];

  List<Widget> _library() => [
    const Text('Default filter'),
    for (final value in LibraryFilter.values)
      _choice<LibraryFilter>(
        value: value,
        selected: controller.settings.libraryFilter,
        title: Text(_title(value.name)),
        onChanged: (value) {
          _preference(() => controller.configure(libraryFilter: value));
        },
      ),
    const SizedBox(height: 16),
    const Text('Default sort'),
    for (final value in LibrarySort.values)
      _choice<LibrarySort>(
        value: value,
        selected: controller.settings.librarySort,
        title: Text(_title(value.name)),
        onChanged: (value) {
          _preference(() => controller.configure(librarySort: value));
        },
      ),
  ];

  List<Widget> _usage() {
    final usage = controller.accountUsage;
    return [
      const Text('Usage & allowance', style: TextStyle(fontSize: 22)),
      const SizedBox(height: 12),
      if (controller.cloudEmail == null)
        const Text('Sign in to view your allowance.')
      else if (controller.accountApi?.configured != true)
        const Text('Usage service is not configured in this build.')
      else if (controller.usageLoading)
        const Center(child: CircularProgressIndicator())
      else if (controller.usageError != null) ...[
        Text(switch (controller.usageFailure) {
          AccountUsageFailureKind.offline => 'You are offline',
          AccountUsageFailureKind.attestation => 'App verification required',
          _ => 'Usage service unavailable',
        }, style: Theme.of(context).textTheme.titleMedium),
        Text(controller.usageError!),
      ] else if (usage != null) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Narration characters remaining'),
          subtitle: Text(
            '${usage.narrationRemaining} of ${usage.narrationMonthlyLimit}\nResets ${usage.narrationResetAt.toUtc().toIso8601String().split('T').first} UTC',
          ),
        ),
        Text(
          usage.narrationEnabled
              ? 'Narration is available'
              : 'Narration is currently disabled',
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Illustration credits'),
          subtitle: Text(
            usage.illustrationCreditsRemaining == null
                ? 'Not activated'
                : '${usage.illustrationCreditsRemaining} remaining · ${usage.illustrationCreditsReserved ?? 0} reserved',
          ),
        ),
        Text(
          usage.illustrationsEnabled
              ? 'Illustrations are available'
              : 'Illustrations are currently disabled',
        ),
        const SizedBox(height: 12),
        Text('Updated ${usage.asOf.toLocal()}'),
      ],
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed:
            controller.usageLoading ||
                controller.cloudEmail == null ||
                controller.accountApi?.configured != true
            ? null
            : controller.refreshAccountUsage,
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh allowance'),
      ),
    ];
  }

  List<Widget> _storage() => [
    FutureBuilder<int>(
      future: _cacheSize,
      builder: (context, snapshot) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Downloaded narration'),
        subtitle: Text(
          snapshot.hasError
              ? 'Cache size unavailable'
              : snapshot.hasData
              ? '${(snapshot.data! / (1024 * 1024)).toStringAsFixed(1)} MiB'
              : 'Calculating…',
        ),
      ),
    ),
    OutlinedButton(
      onPressed: _busy
          ? null
          : () => _action(() async {
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
            }),
      child: const Text('Clear narration cache'),
    ),
    const SizedBox(height: 24),
    const Text('Cloud processing', style: TextStyle(fontSize: 20)),
    const SizedBox(height: 8),
    const Text(
      'Narration requires consent for each book before prose is sent to OpenAI. AI-generated speech may contain mistakes. Cloud audio is private and retained for 30 days; temporary prose is removed after generation, with abandoned input cleaned up after 24 hours. Cached replay is free and works offline. Local audio uses a 250 MiB cache.',
    ),
  ];

  List<Widget> _about() => [
    const Text('Reader', style: TextStyle(fontSize: 24)),
    FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) => Text(
        snapshot.hasData
            ? 'Version ${snapshot.data!.version} (${snapshot.data!.buildNumber})'
            : snapshot.hasError
            ? 'Version unavailable'
            : 'Loading version…',
      ),
    ),
    const SizedBox(height: 16),
    OutlinedButton(
      onPressed: () => showLicensePage(
        context: context,
        applicationName: 'Reader',
        applicationVersion: null,
      ),
      child: const Text('Open-source licenses'),
    ),
    const SizedBox(height: 24),
    OutlinedButton(
      onPressed: _busy
          ? null
          : () => _action(() async {
              if (await _confirm(
                'Reset preferences?',
                'Restore device preferences to their defaults. Books, account, consent and caches remain. Narration pauses if its voice changes.',
                'Reset preferences',
              )) {
                await controller.resetPreferences();
              }
            }),
      child: const Text('Reset preferences'),
    ),
  ];

  // Selection belongs to the actionable tile, not an unlabeled semantics parent.
  Widget _choice<T>({
    required T value,
    required T selected,
    required Widget title,
    Widget? subtitle,
    ColorScheme? preview,
    required void Function(T) onChanged,
  }) => ListTile(
    selected: value == selected,
    leading: Icon(
      value == selected ? Icons.radio_button_checked : Icons.radio_button_off,
    ),
    title: title,
    subtitle: subtitle,
    trailing: preview == null
        ? null
        : Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: preview.surface,
              border: Border.all(color: preview.outline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Aa', style: TextStyle(color: preview.onSurface)),
          ),
    onTap: () => onChanged(value),
  );

  String _title(String value) =>
      '${value[0].toUpperCase()}${value.substring(1)}';
}
