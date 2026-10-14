import 'package:flutter/material.dart';

import '../preferences/reader_settings.dart';
import '../text/reader_text_style.dart';
import 'effect_canvas.dart';
import 'text_effect_catalog.dart';
import 'text_effect_detail.dart';

/// Development gallery of candidate text effects, set in the reader's own
/// typography and theme. Each tile runs its effect on a short phrase and
/// opens the full passage in the detail view.
class TextEffectsScreen extends StatelessWidget {
  /// Uses saved typography; theme comes from the ambient [Theme].
  const TextEffectsScreen({super.key, required this.settings});

  /// Device-global reading settings supplying font family and size.
  final ReaderSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = readerTextStyle(settings, theme.colorScheme.onSurface);
    // Tiles show a phrase, not a page, so they set it a little smaller.
    final tileStyle = style.copyWith(fontSize: style.fontSize! * .8);

    void open(TextEffectEntry entry) => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TextEffectDetail(
          initialIndex: textEffects.indexOf(entry),
          style: style,
        ),
      ),
    );

    Widget heading(String title, String note) => SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'Lora',
              ),
            ),
            const SizedBox(height: 4),
            Text(note),
          ],
        ),
      ),
    );

    Widget grid(List<TextEffectEntry> entries) => SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 280,
          mainAxisExtent: 210,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: entries.length,
        itemBuilder: (_, index) => _EffectTile(
          entry: entries[index],
          style: tileStyle,
          onOpen: () => open(entries[index]),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Text effects')),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            heading(
              'Illustration here',
              'Marks a passage that can become a picture.',
            ),
            grid(illustrationEffects),
            heading('Narration', 'Follows the word being read aloud.'),
            grid(narrationEffects),
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ),
      ),
    );
  }
}

/// A framed plate running one effect on its phrase, named underneath.
class _EffectTile extends StatelessWidget {
  const _EffectTile({
    required this.entry,
    required this.style,
    required this.onOpen,
  });

  final TextEffectEntry entry;
  final TextStyle style;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The plate keeps the page color: effects that dim with `surface` must
    // match what is behind them.
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                // The wider leading inset leaves room for marks drawn in the
                // margin, such as the margin leaf.
                padding: const EdgeInsetsDirectional.fromSTEB(26, 16, 18, 4),
                child: Center(
                  child: EffectCanvas(
                    text: entry.passage.anchor,
                    anchor: entry.passage.anchor,
                    effect: entry.effect,
                    style: style,
                    narration: entry.narration,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(entry.name, style: theme.textTheme.titleSmall),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
