/// Public-domain excerpt shown under one effect in the text effects preview.
class SamplePassage {
  /// [anchor] must occur verbatim in [text]; it marks the illustrated phrase.
  const SamplePassage(this.source, this.text, {required this.anchor});

  /// Book and author, shown under the passage.
  final String source;

  /// Paragraph laid out with the reader's body typography.
  final String text;

  /// Phrase an illustration hint decorates; gallery tiles show it alone.
  final String anchor;
}

/// Preview passage; see `source` for the book.
const callMeIshmael = SamplePassage(
  'Moby-Dick, Herman Melville',
  'Call me Ishmael. Some years ago—never mind how long precisely—having '
      'little or no money in my purse, and nothing particular to interest me '
      'on shore, I thought I would sail about a little and see the watery '
      'part of the world.',
  anchor: 'sail about a little and see the watery part of the world',
);

/// Preview passage; see `source` for the book.
const whiteRabbit = SamplePassage(
  "Alice's Adventures in Wonderland, Lewis Carroll",
  'Suddenly a White Rabbit with pink eyes ran close by her. There was '
      'nothing so very remarkable in that; nor did Alice think it so very '
      'much out of the way to hear the Rabbit say to itself, "Oh dear! Oh '
      'dear! I shall be late!"',
  anchor: 'a White Rabbit with pink eyes ran close by her',
);

/// Preview passage; see `source` for the book.
const admiralBenbow = SamplePassage(
  'Treasure Island, Robert Louis Stevenson',
  'I remember him as if it were yesterday, as he came plodding to the inn '
      'door, his sea-chest following behind him in a hand-barrow—a tall, '
      'strong, heavy, nut-brown man, his tarry pigtail falling over the '
      'shoulder of his soiled blue coat.',
  anchor: 'his tarry pigtail falling over the shoulder of his soiled blue coat',
);

/// Preview passage; see `source` for the book.
const marleyWasDead = SamplePassage(
  'A Christmas Carol, Charles Dickens',
  'Marley was dead: to begin with. There is no doubt whatever about that. '
      'The register of his burial was signed by the clergyman, the clerk, the '
      'undertaker, and the chief mourner.',
  anchor: 'The register of his burial was signed by the clergyman',
);

/// Preview passage; see `source` for the book.
const greenLight = SamplePassage(
  'The Great Gatsby, F. Scott Fitzgerald',
  'Involuntarily I glanced seaward—and distinguished nothing except a single '
      'green light, minute and far away, that might have been the end of a '
      'dock. When I looked once more for Gatsby he had vanished.',
  anchor: 'a single green light, minute and far away',
);

/// Preview passage; see `source` for the book.
const dreadfulNight = SamplePassage(
  'Frankenstein, Mary Shelley',
  'It was on a dreary night of November that I beheld the accomplishment of '
      'my toils. With an anxiety that almost amounted to agony, I collected '
      'the instruments of life around me.',
  anchor: 'I collected the instruments of life around me',
);

/// Preview passage; see `source` for the book.
const thornfield = SamplePassage(
  'Jane Eyre, Charlotte Brontë',
  'There was no possibility of taking a walk that day. We had been wandering, '
      'indeed, in the leafless shrubbery an hour in the morning; but since '
      'dinner the cold winter wind had brought with it clouds so sombre, and a '
      'rain so penetrating, that further out-door exercise was now out of the '
      'question.',
  anchor: 'the cold winter wind had brought with it clouds so sombre',
);

/// Preview passage; see `source` for the book.
const timeMachine = SamplePassage(
  'The Time Machine, H. G. Wells',
  'The Time Traveller (for so it will be convenient to speak of him) was '
      'expounding a recondite matter to us. His grey eyes shone and twinkled, '
      'and his usually pale face was flushed and animated.',
  anchor: 'His grey eyes shone and twinkled',
);

/// Preview passage; see `source` for the book.
const bennetSisters = SamplePassage(
  'Pride and Prejudice, Jane Austen',
  'It is a truth universally acknowledged, that a single man in possession of '
      'a good fortune, must be in want of a wife.',
  anchor: 'a single man in possession of a good fortune',
);

/// Preview passage; see `source` for the book.
const dorianStudio = SamplePassage(
  'The Picture of Dorian Gray, Oscar Wilde',
  'The studio was filled with the rich odour of roses, and when the light '
      'summer wind stirred amidst the trees of the garden, there came through '
      'the open door the heavy scent of the lilac.',
  anchor: 'the heavy scent of the lilac',
);

/// Preview passage; see `source` for the book.
const wonderlandCat = SamplePassage(
  "Alice's Adventures in Wonderland, Lewis Carroll",
  '"Would you tell me, please, which way I ought to go from here?" "That '
      'depends a good deal on where you want to get to," said the Cat.',
  anchor: 'which way I ought to go from here',
);

/// Preview passage; see `source` for the book.
const bestOfTimes = SamplePassage(
  'A Tale of Two Cities, Charles Dickens',
  'It was the best of times, it was the worst of times, it was the age of '
      'wisdom, it was the age of foolishness, it was the epoch of belief, it '
      'was the epoch of incredulity, it was the season of Light, it was the '
      'season of Darkness.',
  anchor: 'it was the season of Light',
);

/// Preview passage; see `source` for the book.
const wendy = SamplePassage(
  'Peter Pan, J. M. Barrie',
  'All children, except one, grow up. They soon know that they will grow up, '
      'and the way Wendy knew was this. One day when she was two years old '
      'she was playing in a garden, and she plucked another flower and ran '
      'with it to her mother.',
  anchor: 'she plucked another flower and ran with it to her mother',
);

/// Preview passage; see `source` for the book.
const messingAbout = SamplePassage(
  'The Wind in the Willows, Kenneth Grahame',
  'Believe me, my young friend, there is nothing—absolutely nothing—half so '
      'much worth doing as simply messing about in boats.',
  anchor: 'simply messing about in boats',
);

/// Preview passage; see `source` for the book.
const happyFamilies = SamplePassage(
  'Anna Karenina, Leo Tolstoy (tr. Constance Garnett)',
  'Happy families are all alike; every unhappy family is unhappy in its own '
      'way. Everything was in confusion in the Oblonskys\' house.',
  anchor: 'Happy families are all alike',
);

/// Preview passage; see `source` for the book.
const kansas = SamplePassage(
  'The Wonderful Wizard of Oz, L. Frank Baum',
  'Dorothy lived in the midst of the great Kansas prairies, with Uncle Henry, '
      'who was a farmer, and Aunt Em, who was the farmer\'s wife. Their house '
      'was small, for the lumber to build it had to be carried by wagon many '
      'miles.',
  anchor: 'the midst of the great Kansas prairies',
);

/// Preview passage; see `source` for the book.
const downTheHole = SamplePassage(
  "Alice's Adventures in Wonderland, Lewis Carroll",
  'Down, down, down. Would the fall never come to an end? "I wonder how '
      'many miles I\'ve fallen by this time?" she said aloud. "I must be '
      'getting somewhere near the centre of the earth."',
  anchor: 'Would the fall never come to an end?',
);
