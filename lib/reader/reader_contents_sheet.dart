import 'package:flutter/material.dart';

import '../text/text_contents_entry.dart' as text;

/// Presents nested resolved contents and returns the original selected entry.
class ReaderContentsSheet extends StatelessWidget {
  /// Creates the contents presentation without owning viewport navigation.
  const ReaderContentsSheet({super.key, required this.contents});

  /// Original nested publication entries, including unresolved targets.
  final List<text.TextContentsEntry> contents;

  @override
  Widget build(BuildContext context) {
    final items = <({text.TextContentsEntry link, int depth})>[];
    // Flatten only for presentation, retaining resolved fragment targets.
    void add(List<text.TextContentsEntry> links, int depth) {
      for (final link in links) {
        items.add((link: link, depth: depth));
        add(link.children, depth + 1);
      }
    }

    add(contents, 0);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Contents',
                style: TextStyle(
                  fontFamily: 'Lora',
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: items
                    .map(
                      (item) => ListTile(
                        contentPadding: EdgeInsets.only(
                          left: 20 + item.depth * 20.0,
                          right: 20,
                        ),
                        title: Text(item.link.title),
                        onTap: item.link.position == null
                            ? null
                            : () => Navigator.pop(context, item.link),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
