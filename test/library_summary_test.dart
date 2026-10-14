import 'package:flutter_test/flutter_test.dart';
import 'package:reader/settings/counts.dart';
import 'package:reader/settings/library_summary.dart';

import 'fixtures/catalog_book.dart';

void main() {
  test('grouped counts insert thousands separators', () {
    expect(groupedCount(0), '0');
    expect(groupedCount(999), '999');
    expect(groupedCount(1000), '1,000');
    expect(groupedCount(1234567), '1,234,567');
  });

  test('compact counts round down so totals are never overstated', () {
    expect(compactCount(950), '950');
    expect(compactCount(1000), '1k');
    expect(compactCount(8490), '8.4k');
    expect(compactCount(184999), '184k');
    expect(compactCount(1250000), '1.2M');
  });

  test(
    'library summary counts finished books whole and others by progress',
    () {
      final summary = LibrarySummary.of([
        testBook(hash: 'a' * 64, progress: 1),
        testBook(hash: 'b' * 64, progress: .25),
        testBook(hash: 'c' * 64),
      ]);
      expect(summary.books, 3);
      expect(summary.finished, 1);
      expect(summary.wordsRead, 1250);
    },
  );
}
