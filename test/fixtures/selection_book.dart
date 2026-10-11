import 'dart:convert';
import 'dart:typed_data';

/// A dictionary word and passage whose exact clipboard contents are unambiguous.
const selectionOpening = 'Dictionary lookup keeps every selected word intact.';

/// A second normalized paragraph for cross-block selection boundary assertions.
const selectionSecondParagraph =
    'Second paragraph preserves its own boundary when copied.';

/// Builds TXT input for the real parser with enough prose to make accidental
/// page turns, end-of-book completion, and scrolling observable in every mode.
Uint8List selectionBookFixture() => Uint8List.fromList(
  utf8.encode(
    [
      selectionOpening,
      selectionSecondParagraph,
      'Unicode café e\u0301 👩🏽‍🚀 العربية שלום हिन्दी ไทย 中文 remains selectable.',
      for (var index = 0; index < 80; index++)
        'Passage $index keeps the reading anchor stable while words are selected. '
            'Turning a page must remain an explicit reading action.',
    ].join('\n\n'),
  ),
);
