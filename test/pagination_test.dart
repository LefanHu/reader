import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/pagination.dart';
import 'package:reader/books.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scale in [1.0, 2.0]) {
    test('Pages fit and reproduce all text at scale $scale', () {
      final text =
          '${List.filled(100, 'A long paragraph with thoughtful words.').join(' ')}\n\nA final, short paragraph.';
      const style = TextStyle(fontSize: 30, height: 1.65);
      const size = Size(327, 300);
      final scaler = TextScaler.linear(scale);
      final pages = paginate(text, style, scaler, size);
      expect(pages.length, greaterThan(1));
      expect(pages.map((p) => text.substring(p.start, p.end)).join(), text);
      for (final page in pages) {
        final painter = TextPainter(
          text: TextSpan(
            text: text.substring(page.start, page.end),
            style: style,
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: size.width);
        expect(painter.height, lessThanOrEqualTo(size.height));
        expect(page.end, greaterThan(page.start));
        if (page.end < text.length) {
          expect(text.substring(page.end - 1, page.end), matches(r'\s'));
        }
        painter.dispose();
      }
    });
  }
  test('Oversized unbroken words split safely and empty chapters work', () {
    final text = List.filled(120, 'é').join();
    final pages = paginate(
      text,
      const TextStyle(fontSize: 20),
      TextScaler.noScaling,
      const Size(80, 60),
    );
    expect(pages.map((p) => text.substring(p.start, p.end)).join(), text);
    expect(pages.length, greaterThan(1));
    expect(
      paginate(
        '',
        const TextStyle(),
        TextScaler.noScaling,
        const Size(80, 60),
      ).single.end,
      0,
    );
  });
  test('Progress is clamped and settings are shared across books', () {
    final controller = ReaderController();
    controller.open(books.first);
    controller.save(books.first, 999, 99999);
    expect(controller.progress(books.first), 1);
    controller.configure(mode: ReadingMode.pages, fontSize: 24);
    controller.open(books.last);
    expect(controller.mode, ReadingMode.pages);
    expect(controller.fontSize, 24);
    expect(controller.progress(books.last), 0);
    expect(controller.currentBook, books.last);
    controller.dispose();
  });
}
