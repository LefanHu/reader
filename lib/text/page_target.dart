import 'text_section.dart' as text;
import 'layout/section_layout.dart';

/// A resolved page owns no textures and shares the bounded section layout.
class PageTarget {
  /// Resolves a page within a borrowed section layout.
  PageTarget(this.ordinal, this.section, this.layout, this.page);

  /// Section ordinal and page index in logical reading order.
  final int ordinal, page;

  /// Normalized section containing the resolved page.
  final text.TextSection section;

  /// Borrowed layout retained by the viewport cache.
  final SectionLayout layout;
}
