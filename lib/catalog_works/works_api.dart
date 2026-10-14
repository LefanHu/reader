import '../catalog/catalog_book.dart';
import 'work_link.dart';
import 'work_text.dart';

/// A confirmed link between the caller's book and a catalog work.
typedef WorkLinkResult = ({String cloudBookId, WorkSummary work, double score});

/// Search results; [degraded] means Open Library was unreachable and only
/// works already in the catalog were searched.
typedef WorkSearch = ({List<WorkSummary> works, bool degraded});

/// Global catalog of works (`/api/works`): a text-free index searched through
/// Open Library. Every call is an explicit user action and may prompt sign-in.
abstract interface class WorksApi {
  /// Up to 20 works matching [query]'s title and author words.
  Future<WorkSearch> search(String query);

  /// Links [book] to the work titled [title] by [author]. Only the
  /// fingerprints of [text] are sent. The first copy linked becomes the
  /// work's reference; a later copy that does not align with it fails with
  /// HTTP 422.
  Future<WorkLinkResult> link(
    CatalogBook book,
    WorkText text, {
    required String title,
    required String author,
    int? firstPublishYear,
  });

  /// The server's current link for [book], or null when it has none.
  Future<WorkLinkResult?> current(CatalogBook book);

  /// Removes [book]'s link; the work itself stays in the catalog.
  Future<void> unlink(CatalogBook book);
}
