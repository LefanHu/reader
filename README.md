# Reader

An offline-first Flutter EPUB reader for iPhone and iPad. It imports reflowable, non-DRM EPUB 2 and EPUB 3 books and renders them with Readium through [`flureadium`](https://pub.dev/packages/flureadium).

- Import several EPUB files from the native document picker, up to 100 MB each.
- Search by title or author; filter All / Reading / Finished; sort by recent activity or title.
- Resume from a complete Readium locator and switch between Pages and Scroll without losing the passage.
- Use nested tables of contents, internal links, images, SVG, RTL content, and publisher semantics handled by Readium.
- Adjust serif/sans-serif text, size, and paper/sepia/dark colors. Hide controls for focused reading.
- Persist the catalog under Application Support and global reading settings in SharedPreferences.

Scripted, remote-resource, fixed-layout, and DRM-protected publications are rejected. Web links show their destination domain and require consent before opening outside the app.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <ios-device-id>
```

Check package updates with:

```sh
flutter pub outdated
flutter pub upgrade --dry-run
```

This project disables Flutter's Swift Package Manager integration because Flureadium 0.19.3 does not provide a compatible macOS Swift package. Native Apple dependencies are resolved through CocoaPods. Install and validate them with:

```sh
cd ios && pod install --repo-update && cd ..
cd macos && pod install --repo-update && cd ..
flutter build ios --simulator --no-codesign
```

Flureadium's published macOS plugin currently contains only a platform stub and does not implement publication loading or its reader view. The macOS shell builds, but EPUB import and reading are intentionally limited to iPhone and iPad until the package ships a functional macOS implementation.

Validate every EPUB fixture separately with the official EPUBCheck release:

```sh
java -jar /path/to/epubcheck.jar path/to/book.epub
```

The iOS deployment target is 15.0. App Transport Security permits local networking only for Readium's loopback content server; arbitrary network loads are not enabled.

## Organization

- `lib/models.dart` contains versioned catalog records and reader settings.
- `lib/storage.dart` contains atomic catalog and preferences persistence.
- `lib/epub_service.dart` contains picker, validation, hashing, copying, and the Readium adapter.
- `lib/controller.dart` is the single shared `ChangeNotifier`.
- `lib/library.dart` and `lib/reader.dart` contain the adaptive library and reader shell.

Lora and DM Sans are bundled under the SIL Open Font License. Flureadium and Readium notices are recorded in `THIRD_PARTY_NOTICES.md`. Distribution builds require an LGPL compliance review.
