# Reader

An offline Flutter reader prototype for phones and tablets, with a warm editorial library and six original sample books.

- Search by title or author; filter All / Reading / Finished; sort by recent activity or title.
- Resume reading with shared chapter and text-offset progress.
- Switch between vertically scrolling chapters and measured, horizontally paged text in reading settings.
- Adjust typeface, font size, and paper/sepia/dark colors. Hide controls for focused reading.
- Adapt to window width, orientation, split view, and accessibility text sizes.

Run with `flutter run`. Validate with `flutter analyze` and `flutter test`.

## Organization

`lib/main.dart` wires the app and shared theme. `books.dart` holds sample content, models, and the single `ChangeNotifier` controller. `library.dart` and `reader.dart` contain the two screens; `pagination.dart` measures page boundaries; `theme.dart` defines shared colors.

No backend or state-management packages are required. Reading progress and preferences last for the current app session; file import, persistent storage, sync, and annotations are outside this prototype.

Lora and DM Sans are bundled for offline typography under the SIL Open Font License. Their licenses are in `assets/fonts/`.
