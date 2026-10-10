import 'dart:io';

import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';

/// Displays a cached publication cover or a deterministic typographic cover.
class BookCover extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const BookCover({super.key, required this.book, this.thumbnail = false});

  /// Book whose catalog metadata is presented.
  final CatalogBook book;
  // Resume thumbnails use an icon instead of unreadably compressed titles.
  /// Whether to use an icon for the fallback at thumbnail sizes.
  final bool thumbnail;
  @override
  Widget build(BuildContext context) {
    final path = book.coverPath;
    if (path != null && File(path).existsSync()) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final colors = [
      const Color(0xFF315E60),
      const Color(0xFF77534F),
      const Color(0xFF725F35),
      const Color(0xFF555D7D),
    ];
    final color =
        colors[book.hash.codeUnits.fold<int>(0, (a, b) => a + b) %
            colors.length];
    return ColoredBox(
      color: color,
      child: thumbnail
          ? const Center(
              child: Icon(
                Icons.menu_book_outlined,
                size: 20,
                color: Colors.white,
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Text(
                  book.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 18,
                    height: 1.2,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
    );
  }
}
