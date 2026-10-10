import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import 'settings_screen.dart';

/// Opens one settings route per navigator, including native menu requests.
class SettingsNavigation {
  static final Map<NavigatorState, Future<void>> _routes = {};

  /// Repeated requests keep the current page and its in-progress actions intact.
  static Future<void> open(
    NavigatorState navigator,
    ReaderController controller,
  ) {
    final existing = _routes[navigator];
    if (existing != null) return existing;
    final route = navigator.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/settings'),
        builder: (_) => SettingsScreen(controller: controller),
      ),
    );
    final completion = route.then<void>((_) {}).whenComplete(() {
      _routes.remove(navigator);
    });
    _routes[navigator] = completion;
    return completion;
  }
}
