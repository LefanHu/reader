import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/grapheme_boundary.dart';
import 'package:reader/text/sentence_narration.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

TextSection section(String text) => TextSection(
  id: 's',
  blocks: [TextBlock(id: 'p', text: text)],
);

void main() {
  test(
    'all-whitespace blocks produce no silent unit and do not hide later speech',
    () {
      final document = TextSection(
        id: 's',
        blocks: [
          const TextBlock(id: 'p', text: ' \n\t  '),
          const TextBlock(id: 'next', text: 'Speech'),
        ],
      );
      final units = sentenceNarrationUnits(document, sentenceRanges: {});
      expect(units.single.chunk.text, 'Speech');
      expect(units.single.chunk.start.blockId, 'next');
      expect(
        sentenceNarrationUnits(section(' \n\t  '), sentenceRanges: {}),
        isEmpty,
      );
      expect(
        sentenceNarrationUnits(
          section(' \n\t  '),
          sentenceRanges: {
            'p': [(start: 0, end: 5)],
          },
        ),
        isEmpty,
      );
    },
  );

  test(
    'markerless punctuation-free and multilingual blocks remain one sentence',
    () {
      for (final text in [
        'No punctuation here',
        '中文没有句号',
        'العربية mixed RTL',
        'First line\nSecond line',
        '👩🏽‍🚀 e\u0301',
      ]) {
        final units = sentenceNarrationUnits(section(text), sentenceRanges: {});
        expect(units.single.chunk.text, text);
        expect(units.single.sentence.start.offset, 0);
        expect(units.single.sentence.end.offset, text.length);
      }
      const text = 'e\u0301 remainder';
      final units = sentenceNarrationUnits(
        section(text),
        sentenceRanges: {},
        from: const TextPosition(sectionId: 's', blockId: 'p', offset: 1),
      );
      expect(units.single.chunk.start.offset, 0);
      expect(units.single.chunk.text, text);
    },
  );

  test(
    'supplied native sentences retain punctuation and whitespace verbatim',
    () {
      const first = '  Dr. A paid 3.14. “Really…?”';
      const second = '中文 العربية\ne\u0301 👩🏽‍🚀';
      final text = '$first  \n$second  ';
      final ranges = {
        'p': [
          (start: 2, end: first.length),
          (start: first.length + 3, end: text.length - 2),
        ],
      };
      final units = sentenceNarrationUnits(
        section(text),
        sentenceRanges: ranges,
      );
      expect(units.map((u) => u.chunk.text).join(), text);
      expect(units.length, 2);
      expect(units.first.sentence.start.offset, 2);
      expect(units.first.sentence.end.offset, first.length);
      expect(units.last.chunk.end.offset, text.length);
      expect(units.every((u) => u.chunk.text.trim().isNotEmpty), isTrue);
      expect(appleSentenceNarrationPolicy, 'apple-sentence');
    },
  );

  test('native boundaries inside a grapheme expand and overlapping expansions merge', () {
    const text = 'e\u0301👩🏽‍🚀中文';
    final units = sentenceNarrationUnits(
      section(text),
      sentenceRanges: {
        'p': [(start: 0, end: 1), (start: 1, end: text.length)],
      },
    );
    expect(units.length, 1);
    expect(units.single.chunk.text, text);
    expect(units.single.sentence.end.offset, text.length);
  });

  test(
    'long sentence clips are bounded, exact and retain enclosing fallback',
    () {
      final text = '${'alpha, beta 中文 العربية e\u0301 👩🏽‍🚀 ' * 90}end.  ';
      final units = sentenceNarrationUnits(section(text), sentenceRanges: {});
      expect(units.length, greaterThan(2));
      expect(units.map((u) => u.chunk.text).join(), text);
      for (final unit in units) {
        expect(unit.chunk.text.length, lessThanOrEqualTo(300));
        expect(unit.chunk.text.trim(), isNotEmpty);
        expect(
          graphemeFloor(text, unit.chunk.start.offset),
          unit.chunk.start.offset,
        );
        expect(
          graphemeFloor(text, unit.chunk.end.offset),
          unit.chunk.end.offset,
        );
        expect(unit.sentence, units.first.sentence);
        expect(unit.chunk.start.sectionId, 's');
        expect(unit.chunk.start.blockId, 'p');
      }
    },
  );

  test('suffix resume and block end use complete section boundary rules', () {
    const text = 'Hello, world. Another sentence.';
    final document = TextSection(
      id: 's',
      blocks: [
        const TextBlock(id: 'p', text: text),
        const TextBlock(id: 'next', text: 'Next block'),
      ],
    );
    final ranges = {
      'p': [(start: 0, end: 13), (start: 14, end: text.length)],
    };
    final resumed = sentenceNarrationUnits(
      document,
      sentenceRanges: ranges,
      from: const TextPosition(sectionId: 's', blockId: 'p', offset: 7),
    );
    expect(resumed.first.chunk.text, 'world. ');
    expect(resumed.first.sentence.start.offset, 0);
    expect(
      resumed
          .where((u) => u.chunk.start.blockId == 'p')
          .map((u) => u.chunk.text)
          .join(),
      text.substring(7),
    );
    final next = sentenceNarrationUnits(
      document,
      sentenceRanges: ranges,
      from: const TextPosition(
        sectionId: 's',
        blockId: 'p',
        offset: text.length,
      ),
    );
    expect(next.single.chunk.start.blockId, 'next');
    final invalid = sentenceNarrationUnits(
      document,
      sentenceRanges: ranges,
      from: const TextPosition(sectionId: 'other', blockId: 'p', offset: 7),
    );
    expect(invalid.first.chunk.start.offset, 0);
  });

  test('whitespace is attached and pathological graphemes never split', () {
    const text = 'One.   Two.   ';
    final units = sentenceNarrationUnits(
      section(text),
      sentenceRanges: {
        'p': [
          (start: 0, end: 4),
          (start: 4, end: 7),
          (start: 7, end: 11),
          (start: 11, end: 14),
        ],
      },
    );
    expect(units.map((u) => u.chunk.text).join(), text);
    expect(units.length, 2);
    final grapheme = 'a${'\u0301' * 500}';
    expect(
      sentenceNarrationUnits(
        section(grapheme),
        sentenceRanges: {},
      ).single.chunk.text,
      grapheme,
    );
    expect(
      () => sentenceNarrationUnits(
        section('a${'\u0301' * 3001}'),
        sentenceRanges: {},
      ),
      throwsFormatException,
    );
    expect(
      () =>
          sentenceNarrationUnits(section('A${' ' * 3001}'), sentenceRanges: {}),
      throwsFormatException,
    );
  });

  test(
    'malformed native boundaries are rejected rather than losing source',
    () {
      for (final ranges in [
        [(start: -1, end: 2)],
        [(start: 0, end: 5)],
        [(start: 0, end: 0)],
        [(start: 0, end: 3), (start: 2, end: 4)],
      ]) {
        expect(
          () => sentenceNarrationUnits(
            section('Text'),
            sentenceRanges: {'p': ranges},
          ),
          throwsFormatException,
        );
      }
    },
  );
}
