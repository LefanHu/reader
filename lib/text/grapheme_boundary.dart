import 'package:characters/characters.dart';

/// Snaps backward so restoration and pagination never bisect a grapheme.
int graphemeFloor(String text, int offset) {
  final target = offset.clamp(0, text.length);
  var boundary = 0;
  for (final cluster in text.characters) {
    final next = boundary + cluster.length;
    if (next > target) break;
    boundary = next;
  }
  return boundary;
}
