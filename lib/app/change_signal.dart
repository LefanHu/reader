import 'package:flutter/foundation.dart';

/// A payload-free notifier for one narrow, high-frequency kind of change.
///
/// [ReaderController] owns these beside its general notification so frequent
/// updates (spoken-word highlights, reading-position saves) rebuild only the
/// widgets that present them instead of the whole app.
class ChangeSignal extends ChangeNotifier {
  /// Notifies listeners that the signalled state changed.
  void notify() => notifyListeners();
}
