import 'package:flutter/material.dart';

class TextPage {
  const TextPage(this.start, this.end);
  final int start, end;
}

/// Every code unit belongs to exactly one page. Measure the actual substring,
/// since starting a new page can change wrapping and trailing line metrics.
List<TextPage> paginate(
  String text,
  TextStyle style,
  TextScaler scaler,
  Size size,
) {
  if (text.isEmpty) return const [TextPage(0, 0)];
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  );
  final boundaries = RegExp(r'\s+').allMatches(text).map((m) => m.end).toList();
  if (boundaries.isEmpty || boundaries.last != text.length) {
    boundaries.add(text.length);
  }
  final result = <TextPage>[];
  var start = 0;
  while (start < text.length) {
    final candidates = boundaries.where((end) => end > start).toList();
    var low = 0;
    var high = candidates.length - 1;
    var end = start;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      painter.text = TextSpan(
        text: text.substring(start, candidates[mid]),
        style: style,
      );
      painter.layout(maxWidth: size.width);
      if (painter.height <= size.height) {
        end = candidates[mid];
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (end == start) {
      // A word can exceed a page at extreme sizes; split only at graphemes.
      for (final character
          in text.substring(start, candidates.first).characters) {
        final next = end + character.length;
        painter.text = TextSpan(
          text: text.substring(start, next),
          style: style,
        );
        painter.layout(maxWidth: size.width);
        if (painter.height > size.height && end > start) break;
        end = next;
      }
    }
    result.add(TextPage(start, end));
    start = end;
  }
  painter.dispose();
  return result;
}
