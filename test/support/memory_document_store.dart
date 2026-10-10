import 'package:reader/text/document.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/section_summary.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_contents_entry.dart';
import 'package:reader/text/text_section.dart';

/// In-memory normalized document store for real viewport widget tests.
class MemoryDocumentStore extends TextDocumentStore {
  MemoryDocumentStore({List<TextSection>? sections, this.contents})
    : sections =
          sections ??
          [
            const TextSection(
              id: 's0',
              blocks: [
                TextBlock(id: 'p0', text: 'A test paragraph.'),
                TextBlock(id: 'p1', text: 'A second paragraph.'),
              ],
            ),
          ];
  final List<TextSection> sections;
  final List<TextContentsEntry>? contents;
  TextDocument get document => TextDocument(
    title: 'Test Book',
    authors: const ['Test Author'],
    sections: [
      for (final section in sections)
        SectionSummary(
          id: section.id,
          title: 'Section ${sections.indexOf(section) + 1}',
          source: section.id,
          length: section.length,
        ),
    ],
    contents:
        contents ??
        [
          for (final section in sections)
            TextContentsEntry(title: section.id, position: section.start),
        ],
  );
  @override
  Future<TextDocument> load(String sourcePath) async => document;
  @override
  Future<TextSection> loadSection(String sourcePath, String id) async =>
      sections.firstWhere((section) => section.id == id);
}
