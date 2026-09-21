import 'package:flutter/material.dart';

enum ReadingMode { scroll, pages }

enum ReadingTheme { paper, sepia, dark }

enum LibraryFilter { all, reading, finished }

class Chapter {
  const Chapter(this.title, this.text);
  final String title;
  final String text;
}

class Book {
  const Book(
    this.id,
    this.title,
    this.author,
    this.category,
    this.color,
    this.chapters,
  );
  final String id, title, author, category;
  final Color color;
  final List<Chapter> chapters;
}

class ReadingPosition {
  const ReadingPosition({this.chapter = 0, this.offset = 0});
  final int chapter, offset;
}

class ReaderController extends ChangeNotifier {
  ReadingMode mode = ReadingMode.scroll;
  ReadingTheme theme = ReadingTheme.paper;
  double fontSize = 20;
  bool serif = true;
  final Map<String, ReadingPosition> _positions = {};
  final List<String> _recent = [];

  ReadingPosition position(Book book) =>
      _positions[book.id] ?? const ReadingPosition();
  bool started(Book book) => _positions.containsKey(book.id);
  Book? get currentBook =>
      _recent.isEmpty ? null : books.firstWhere((b) => b.id == _recent.first);
  int recentIndex(Book book) =>
      _recent.contains(book.id) ? _recent.indexOf(book.id) : books.length;
  double progress(Book book) {
    final p = position(book);
    final total = book.chapters.fold<int>(0, (sum, c) => sum + c.text.length);
    final before = book.chapters
        .take(p.chapter)
        .fold<int>(0, (sum, c) => sum + c.text.length);
    return ((before + p.offset) / total).clamp(0, 1);
  }

  void open(Book book) {
    _positions.putIfAbsent(book.id, () => const ReadingPosition());
    _recent.remove(book.id);
    _recent.insert(0, book.id);
    notifyListeners();
  }

  void save(Book book, int chapter, int offset) {
    final safeChapter = chapter.clamp(0, book.chapters.length - 1);
    final safeOffset = offset.clamp(0, book.chapters[safeChapter].text.length);
    final old = position(book);
    if (old.chapter == safeChapter &&
        old.offset == safeOffset &&
        started(book)) {
      return;
    }
    _positions[book.id] = ReadingPosition(
      chapter: safeChapter,
      offset: safeOffset,
    );
    notifyListeners();
  }

  void configure({
    ReadingMode? mode,
    ReadingTheme? theme,
    double? fontSize,
    bool? serif,
  }) {
    this.mode = mode ?? this.mode;
    this.theme = theme ?? this.theme;
    this.fontSize = fontSize ?? this.fontSize;
    this.serif = serif ?? this.serif;
    notifyListeners();
  }
}

// Original, offline sample stories. No external fonts, images, or services.
final books = <Book>[
  Book(
    'tide',
    'The Shape\nof a Tide',
    'Clara Ellis',
    'FICTION',
    const Color(0xFF315E60),
    [
      Chapter(
        'The house at the edge',
        '''The house stood where the road gave up. Beyond its little gate, the grass sloped toward a strip of pale stones, and beyond the stones the sea moved with the patience of something that had never needed a clock. Mara arrived in the late afternoon carrying a suitcase, a loaf of bread, and a key she had not used in twenty years.

Inside, everything was smaller than she remembered. The kitchen table could hardly have held the elaborate breakfasts of her childhood. The window above the sink framed only a fragment of the bay. Yet when she opened it, the whole coast seemed to enter: salt, wet timber, the sharp green smell of rain on the garden.

A note lay beneath a blue cup. Her aunt had written only two lines. The back door sticks in wet weather. The tide will tell you when to walk. Mara read them twice, then set the kettle on the stove. For the first time that day, she took off her coat.

While the water warmed, she went from room to room without switching on a light. She recognized a scratch on the banister and a small uneven patch in the hallway floor. These were things no photograph would have thought to preserve. They had waited without making anything of the waiting.

At dusk she carried her tea down to the stones. A fishing boat moved across the opening of the bay, leaving a line that disappeared almost as soon as it was made. She stayed until the cup was cold. Somewhere behind her, the house settled into the evening.''',
      ),
      Chapter(
        'A map in the sand',
        '''By morning the water had retreated, revealing a path between two dark shelves of rock. Mara followed it with her shoes in one hand. Small pools held the sky so perfectly that she felt she was stepping between pieces of another world.

Near the old landing, a man was repairing a wooden sign. He introduced himself as the keeper of the ferry, although no ferry had crossed the bay in years. Someone had to keep the landing, he said. It was easier to explain that way.

He showed her the marks the winter storms had left on the posts. Each one told a different story of water and wind. Mara wondered how many things she had mistaken for damage because she did not know how to read them.

They walked back before the tide turned. At the garden gate he gave her a small pear from his pocket, as naturally as if they had been neighbors all their lives. She ate it standing in the kitchen, looking out at the path already beginning to disappear.''',
      ),
      Chapter(
        'What the water keeps',
        '''For a week Mara made no plans. She mended the curtain in the spare room. She learned which window caught the earliest light. Every afternoon she walked a little farther along the shore, and every evening she returned before the sea covered her footprints.

On the seventh day she found a tin of seeds in the shed. Most were too old to name. She planted them anyway, in a narrow bed beside the kitchen wall, and marked the rows with pieces of driftwood.

That night she wrote a letter to a friend. There was very little news to tell. The kettle worked. The back door needed lifting before it would close. Something might grow beneath the window. She read the letter over and realized that she was describing a life.

Outside, the water reached the stones and slipped away again. Mara left the window open a little. In the dark, the sound was neither an arrival nor a departure, but something large enough to hold them both.''',
      ),
    ],
  ),
  Book(
    'quiet',
    'A Field Guide\nto Quiet',
    'Samuel Park',
    'ESSAYS',
    const Color(0xFF80876A),
    [
      Chapter(
        'Paying attention',
        '''On my walk to the station there is a tree growing through a fence. I passed it for three years before I noticed. The trunk has taken the shape of the iron, or the iron has taken the shape of the trunk; at this point it is difficult to say which thing is holding the other.

Attention often begins this way, with a small interruption in what we believe we already know. We do not need to travel very far to find something unfamiliar. Sometimes we need only to stop at the corner we usually hurry around.

This is not a guide to perfect silence. The world is full of sounds worth keeping: a spoon against a bowl, a bicycle crossing loose stones, someone laughing in the next room. Quiet is the space in which those ordinary sounds become themselves again.

Tomorrow I will pass the tree. It will not have changed in any way I can measure. I hope to notice it anyway.''',
      ),
      Chapter(
        'The unhurried hour',
        '''An unhurried hour is not an empty one. It may contain washing dishes, answering a letter, or walking to the shop for milk. What distinguishes it is the absence of a second, imaginary hour in which we think we ought to be doing something else.

One afternoon I repaired the handle of a drawer. It took longer than I expected. The wood was soft and the screw would not hold. I found a little scrap of timber, trimmed it to fit, and began again. When I finished, the drawer opened cleanly.

For once I had nothing to show except a thing that worked. This seemed enough. The afternoon had not vanished; it was there in the small resistance of the handle, and in the pleasure of opening it.''',
      ),
      Chapter(
        'Leaving room',
        '''The shelf beside my desk used to be full. Then I lent three books to a friend, and the space they left changed the whole room. The remaining books seemed more deliberate. A little bowl became visible again.

We tend to think of space as something waiting to be filled. But space can be useful in its own right. It lets a sentence settle. It gives a visitor somewhere to put a bag. It allows us to change our minds.

My friend eventually returned the books. I put them on another shelf. The little bowl is still there, holding nothing, doing its quiet work.''',
      ),
    ],
  ),
  Book(
    'atlas',
    'An Atlas of\nSmall Places',
    'Noah Bennett',
    'TRAVEL',
    const Color(0xFFBE7859),
    [
      Chapter(
        'The unnamed square',
        '''The square did not appear on my map. I found it because I took the wrong turning after the bakery, following the smell of warm bread instead of the street signs. There were four trees, a fountain without water, and a bench painted a determined shade of blue.

A woman was sweeping the steps of a building whose purpose I could not guess. She nodded when I sat down. After a while a boy arrived with a football, examined the empty fountain, and decided against it.

Nothing remarkable happened. I ate the bread while it was still warm. The trees moved a little. When I finally left, I marked the square on my map with a dot, which seemed the right amount of information.''',
      ),
      Chapter(
        'Room above the station',
        '''My room looked onto the railway platforms. Every hour a train arrived, bringing a brief collection of voices and wheels. Then the doors closed and the town returned to the sound of pigeons walking along the roof.

The owner had left a jug of water and a timetable on the desk. In the margin of the timetable someone had drawn a tiny mountain. I asked about it at breakfast. That train has the best view, she said, pointing with her spoon.

I took it the next morning without knowing where I would get off. For several miles the track followed a river. The mountain appeared just once, between two warehouses, and was gone before I could reach for my camera.''',
      ),
      Chapter(
        'A place to return to',
        '''We remember some places by the route we took to reach them. Others remain as a color, a meal, a particular quality of afternoon light. The village at the end of the bus line stayed with me as the sound of a door being opened.

I had arrived in the rain. The café was closed, but the owner saw me beneath the awning and let me in. He was counting the day's coins. I sat by the stove while he made a pot of tea.

There is no useful recommendation to make about that village. I cannot promise that the café will be open or that the rain will stop. Only that, once, a door opened there, and for an hour I needed nothing else.''',
      ),
    ],
  ),
  Book(
    'orchard',
    'The Last\nOrchard',
    'Ada Wren',
    'FICTION',
    const Color(0xFF77534F),
    [
      Chapter(
        'September fruit',
        '''Every September, June counted the trees. There were thirty-seven now, though the orchard had once held fifty. She recorded the number in a notebook along with the first frost, the rainfall, and any birds she did not recognize.

Her neighbor suggested planting new varieties. June said she would think about it. What she meant was that she did not yet know how to replace a tree she remembered climbing.

That afternoon a child from the village arrived with an empty basket. She asked which apples were ready. June showed her how to lift the fruit and turn it gently. If it wants to come, she said, you will not need to pull.''',
      ),
      Chapter(
        'Windfall',
        '''The storm came during the night. In the morning, apples covered the grass like an unexpected second harvest. June walked between the rows, picking up the sound fruit and leaving the bruised ones for the birds.

The oldest tree had lost a branch. Beneath the torn wood she could see the pale grain, fresh as something newly made. She placed her hand against it and felt, absurdly, that she should apologize.

By noon three neighbors had come to help. They worked without discussing the future of the orchard. Someone brought soup. Someone sharpened the saw. The day became manageable in the way that difficult days sometimes do, one small task at a time.''',
      ),
      Chapter(
        'New roots',
        '''In November June ordered four young trees. They arrived wrapped in cloth, their roots curled together like sleeping animals. She laid them beside the shed and went inside to find her notebook.

The child came back to help with the planting. Together they measured the spaces, dug the holes, and carried water from the tap. The new trees looked improbably small beneath the wide autumn sky.

How long until there are apples? the child asked. A few years, June said. They stood for a moment considering this. Then the child took the empty watering can and went to fill it again.''',
      ),
    ],
  ),
  Book(
    'light',
    'Notes on\nLight',
    'Elena Sol',
    'OBSERVATIONS',
    const Color(0xFFB29353),
    [
      Chapter(
        'East-facing window',
        '''At seven in the morning, the light reaches the far wall of my room. By eight it has crossed the table. At nine it rests on the floor beside the door, a bright rectangle with one imperfect edge where the window frame has warped.

I used to think of the room as a fixed thing. Now I understand that it is remade every hour. The blue cup becomes gray. The white wall turns gold. A glass of water casts a shape that seems more solid than the glass itself.

There is no lesson in this, except perhaps that looking twice is rarely a waste of time.''',
      ),
      Chapter(
        'Weather indoors',
        '''Clouds pass over the city and the room answers. A moment ago the shelves were sharp and separate; now they have softened into a single dark shape. The change takes less than a second, yet the whole afternoon feels different.

On rainy days I leave the lamp off for as long as possible. I like the slow gathering of shadows. Objects become less certain at their edges, as if they are being allowed to rest.

Eventually I turn the lamp on. Its small circle of light does not defeat the dark. It simply makes a place within it.''',
      ),
      Chapter(
        'The blue hour',
        '''There is a brief time after sunset when the windows hold more color than the walls. Outside, everything is blue; inside, everything waits. I often stop working then, even if I have not finished.

Across the street, lamps appear in one room and then another. Someone closes a curtain. Someone carries a plate past a window. The city becomes a collection of small interiors, each containing a life I cannot see.

Then the blue deepens and the glass begins to reflect my own room. I return to the table. For a little while, the page seems to retain some of the sky.''',
      ),
    ],
  ),
  Book(
    'moon',
    'Under a\nPaper Moon',
    'Theo Lane',
    'SHORT STORIES',
    const Color(0xFF555D7D),
    [
      Chapter(
        'The night shop',
        '''The shop opened at ten in the evening. It sold ordinary things: string, envelopes, batteries, biscuits in a green tin. Its customers were people who had remembered something too late.

Luca worked behind the counter, reading a book with a missing cover. He liked the hours. At night, people explained their purchases. The string was for a school project. The batteries were for a radio belonging to someone's father. The biscuits needed no explanation.

One Tuesday a woman came in asking for a map of the stars. Luca did not have one. But he found a sheet of dark paper and a pencil, and together they drew the constellations they could remember.''',
      ),
      Chapter(
        'A borrowed umbrella',
        '''The umbrella appeared beside the door on a Thursday. It was yellow, with a wooden handle and one bent spoke. Nobody claimed it, though everyone seemed to recognize it.

When the rain started, Luca lent it to a man who promised to return it the next day. He did. The following week it went home with a student. Then with a nurse. Then with a woman carrying a cake.

By winter, Luca had stopped thinking of the umbrella as a lost thing. It belonged to the shop in the same way the light above the door did: by being there when someone needed it.''',
      ),
      Chapter(
        'Morning inventory',
        '''Just before dawn, the street became quiet enough to hear the refrigerator humming. Luca counted the coins, straightened the envelopes, and wrote a list of things to order. String. Tea. More of the biscuits in the green tin.

On the wall behind the counter, the paper sky had acquired new stars. Customers added them when they remembered a name or a shape. Some were probably in the wrong place. Luca had decided that this was all right.

He switched off the sign and stepped outside. Above the roofs, the real stars were fading. He locked the door, put the key in his pocket, and walked home through the first light.''',
      ),
    ],
  ),
];
