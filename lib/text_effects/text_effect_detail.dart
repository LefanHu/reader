import 'package:flutter/material.dart';

import 'effect_canvas.dart';
import 'text_effect_catalog.dart';

/// Pages through every effect at full reading size. Illustration hints answer
/// taps on the passage; narration effects can be paused.
class TextEffectDetail extends StatefulWidget {
  /// Opens on [initialIndex] into [textEffects].
  const TextEffectDetail({
    super.key,
    required this.initialIndex,
    required this.style,
  });

  /// Effect shown first.
  final int initialIndex;

  /// Reader body style.
  final TextStyle style;

  @override
  State<TextEffectDetail> createState() => _TextEffectDetailState();
}

class _TextEffectDetailState extends State<TextEffectDetail> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(textEffects[_index].name),
      actions: [
        // Buttons as well as swipes: desktop pointers do not drag pages.
        IconButton(
          tooltip: 'Previous effect',
          icon: const Icon(Icons.chevron_left),
          onPressed: _index > 0 ? () => _go(_index - 1) : null,
        ),
        IconButton(
          tooltip: 'Next effect',
          icon: const Icon(Icons.chevron_right),
          onPressed: _index < textEffects.length - 1
              ? () => _go(_index + 1)
              : null,
        ),
      ],
    ),
    body: SafeArea(
      child: PageView.builder(
        controller: _pages,
        itemCount: textEffects.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (_, index) =>
            _EffectPage(entry: textEffects[index], style: widget.style),
      ),
    ),
  );
}

class _EffectPage extends StatefulWidget {
  const _EffectPage({required this.entry, required this.style});

  final TextEffectEntry entry;
  final TextStyle style;

  @override
  State<_EffectPage> createState() => _EffectPageState();
}

class _EffectPageState extends State<_EffectPage> {
  bool _playing = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final entry = widget.entry;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          // The leading gutter leaves room for marks drawn in the margin.
          padding: const EdgeInsetsDirectional.fromSTEB(32, 24, 24, 48),
          children: [
            Text(
              entry.description,
              style: theme.textTheme.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 32),
            EffectCanvas(
              text: entry.passage.text,
              anchor: entry.passage.anchor,
              effect: entry.effect,
              style: widget.style,
              narration: entry.narration,
              interactive: !entry.narration,
              playing: _playing,
              activationDuration: entry.activation,
            ),
            const SizedBox(height: 10),
            Text(
              entry.passage.source,
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                fontFamily: 'Lora',
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 32),
            if (entry.narration)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _playing = !_playing),
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  label: Text(_playing ? 'Pause narration' : 'Play narration'),
                ),
              )
            else
              Text(
                'Tap the passage to see how it responds.',
                style: TextStyle(color: muted),
              ),
          ],
        ),
      ),
    );
  }
}
