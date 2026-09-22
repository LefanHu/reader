// The small public boundary is documented on IllustrationGate itself.
// ignore_for_file: public_member_api_docs

import 'package:flureadium/flureadium.dart';

import 'models.dart';

/// Compares resolved Readium locators with scene-end anchors conservatively.
///
/// A same-resource locator without a DOM selector never unlocks a scene. The
/// next spine resource is the safe fallback, avoiding early reveals when a
/// publisher's markup cannot be mapped back to the local index.
class IllustrationGate {
  const IllustrationGate();

  bool hasPassed({
    required SceneAnchor anchor,
    required BookTextIndex index,
    required Locator locator,
  }) {
    final currentChapter = index.chapterForHref(locator.href);
    if (currentChapter == null) return false;
    if (currentChapter.spineOrdinal > anchor.spineOrdinal) return true;
    if (currentChapter.spineOrdinal < anchor.spineOrdinal) return false;

    final anchorChapter = index.chapters
        .where((chapter) => chapter.spineOrdinal == anchor.spineOrdinal)
        .firstOrNull;
    if (anchorChapter == null) return false;
    final anchorOrdinal = anchorChapter.paragraphs
        .where((paragraph) => paragraph.id == anchor.paragraphId)
        .firstOrNull
        ?.ordinal;
    if (anchorOrdinal == null) return false;

    final locations = locator.toJson()['locations'] as Map?;
    final selector = locations?['cssSelector'] as String?;
    if (selector == null || selector.isEmpty) return false;
    final currentOrdinal = _matchSelector(anchorChapter, selector)?.ordinal;
    return currentOrdinal != null && currentOrdinal > anchorOrdinal;
  }

  IndexedParagraph? _matchSelector(ChapterTextIndex chapter, String selector) {
    for (final paragraph in chapter.paragraphs) {
      if (paragraph.cssSelector == selector ||
          selector.startsWith('${paragraph.cssSelector} >') ||
          paragraph.cssSelector.startsWith('$selector >')) {
        return paragraph;
      }
    }
    return null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
