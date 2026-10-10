import 'text_position.dart';

/// Nested navigation target resolved to normalized text rather than HTML.
class TextContentsEntry {
  /// Container entries can have children without a readable target.
  const TextContentsEntry({
    required this.title,
    this.position,
    this.children = const [],
  });

  /// Reader-visible navigation label.
  final String title;

  /// Resolved paragraph target, if the source link is readable.
  final TextPosition? position;

  /// Nested navigation structure retained from EPUB navigation.
  final List<TextContentsEntry> children;

  /// Durable navigation tree.
  Map<String, dynamic> toJson() => {
    'title': title,
    if (position != null) 'position': position!.toJson(),
    'children': children.map((item) => item.toJson()).toList(),
  };

  /// Restores a navigation subtree.
  factory TextContentsEntry.fromJson(Map<String, dynamic> json) =>
      TextContentsEntry(
        title: json['title'] as String,
        position: json['position'] == null
            ? null
            : TextPosition.fromJson(
                (json['position'] as Map).cast<String, dynamic>(),
              ),
        children: (json['children'] as List)
            .map(
              (item) => TextContentsEntry.fromJson(
                (item as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
}
