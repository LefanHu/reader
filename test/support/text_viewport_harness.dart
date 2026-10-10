import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/reader_navigation.dart';
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/viewport.dart';

import '../fixtures/text_documents.dart';
import 'memory_document_store.dart';

/// Keeps changes observable without replacing the viewport's element/state.
class TextViewportHarness {
  /// Uses a long multilingual paragraph unless a store is supplied.
  TextViewportHarness({MemoryDocumentStore? store, this.reducedMotion = false})
    : store = store ?? MemoryDocumentStore(sections: multilingualSections());

  /// Chapter source shared with the mounted viewport.
  final MemoryDocumentStore store;

  /// Whether the viewport bypasses animated page turns.
  final bool reducedMotion;

  /// Default navigation controller; replacements can be passed to [app].
  final navigation = TextReaderNavigation();

  /// Complete logical positions reported by the viewport.
  final reports = <text.TextPosition>[];

  /// Live settings used to exercise reflow and mode changes.
  final settings = ValueNotifier(
    const ReaderSettings(mode: ReadingMode.pageFlip),
  );

  /// Viewport dimensions applied on the next [app] rebuild.
  Size size = const Size(360, 260);

  /// Number of center taps forwarded by the viewport.
  int taps = 0;

  /// Rebuilds the same element hierarchy with optional replacement navigation.
  Widget app({TextReaderNavigation? navigation}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: ValueListenableBuilder(
            valueListenable: settings,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reducedMotion),
              child: TextViewport(
                document: store.document,
                sourcePath: '/memory/book',
                store: store,
                navigation: navigation ?? this.navigation,
                settings: value,
                foreground: Colors.black,
                background: const Color(0xfffffbf0),
                onPosition: (p, _, _) => reports.add(p),
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// Mounts and settles the viewport, clearing only initial position reports.
  Future<void> mount(WidgetTester tester) async {
    addTearDown(settings.dispose);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    reports.clear();
  }
}
