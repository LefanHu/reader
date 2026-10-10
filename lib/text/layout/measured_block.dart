import 'package:flutter/painting.dart';

import '../text_block.dart' as text;

/// A normalized block borrowing its section-owned text painter.
class MeasuredBlock {
  /// Pairs normalized text with a painter owned by its section layout.
  MeasuredBlock(this.block, this.painter);

  /// Normalized source text and block identity.
  final text.TextBlock block;

  /// Borrowed measured painter; the section layout disposes it.
  final TextPainter painter;
}
