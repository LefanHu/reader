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

/// Sorted UTF-16 grapheme-cluster boundaries of one string.
///
/// Binary searches keep clipping linear in text size rather than rescanning
/// previously visited graphemes for every native range or clip.
class GraphemeBoundaries {
  /// Segments [text] once; offsets start at 0 and end at `text.length`.
  GraphemeBoundaries(String text) : offsets = _segment(text);

  /// Boundary offsets in ascending order.
  final List<int> offsets;

  static List<int> _segment(String text) {
    final result = <int>[0];
    for (final cluster in text.characters) {
      result.add(result.last + cluster.length);
    }
    return result;
  }

  /// Index of the last boundary at or before [offset], clamped to the list.
  int floorIndex(int offset) => _index(offset, ceiling: false);

  /// Last boundary at or before [offset], clamped to the text.
  int floor(int offset) => offsets[floorIndex(offset)];

  /// First boundary at or after [offset], clamped to the text.
  int ceil(int offset) => offsets[_index(offset, ceiling: true)];

  /// Whether [offset] lies exactly on a grapheme boundary.
  bool contains(int offset) {
    final index = _index(offset, ceiling: false);
    return offsets[index] == offset;
  }

  int _index(int value, {required bool ceiling}) {
    var low = 0;
    var high = offsets.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (offsets[middle] == value) return middle;
      if (offsets[middle] < value) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return ceiling
        ? low.clamp(0, offsets.length - 1)
        : high.clamp(0, offsets.length - 1);
  }
}
