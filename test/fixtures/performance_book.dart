import 'dart:typed_data';

import 'epub.dart';

/// Paragraph count and navigation target stay fixed across profiling runs.
const performanceParagraphCount = 300;

/// Builds the same imported EPUB used for scrolling, turns, and chapter jumps.
/// It exercises real normalization and font fallback, not a second text pipeline.
Uint8List performanceBookFixture() => epubFixture(
  timestamp: 315532800, // ZIP's 1980 epoch, independent of the host clock.
  body:
      '<h1 id="chapter">Chapter One</h1>'
      '${List.generate(performanceParagraphCount, (i) => '<p${i == 150 ? ' id="passage"' : ''}>Paragraph $i. The reader walks beneath the trees and watches the evening light. 中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀. The path continues beyond the river, with conversation, questions, and an unhurried return home.</p>').join()}',
);
