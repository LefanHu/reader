import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_section.dart' as text;

/// Mixed scripts and combining graphemes shared by viewport and raster cases.
const multilingualText = '中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀 ';

/// Returns the original long multilingual paragraph in section s0.
List<text.TextSection> multilingualSections() => [
  text.TextSection(
    id: 's0',
    blocks: [text.TextBlock(id: 'p0', text: multilingualText * 80)],
  ),
];

/// Returns the original long right-to-left paragraph in section s0.
List<text.TextSection> rtlSections() => [
  text.TextSection(
    id: 's0',
    blocks: [text.TextBlock(id: 'rtl', text: 'שלום עולם ' * 120)],
  ),
];

/// Returns three short chapters that each fit on a single viewport page.
List<text.TextSection> singlePageSections() => [
  const text.TextSection(
    id: 's0',
    blocks: [text.TextBlock(id: 'a', text: 'First page')],
  ),
  const text.TextSection(
    id: 's1',
    blocks: [text.TextBlock(id: 'b', text: 'Second page')],
  ),
  const text.TextSection(
    id: 's2',
    blocks: [text.TextBlock(id: 'c', text: 'Third page')],
  ),
];
