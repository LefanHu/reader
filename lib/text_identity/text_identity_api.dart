import '../catalog/catalog_book.dart';
import 'paragraph_fingerprints.dart';

/// The server's identification of one copy.
typedef TextIdentityResult = ({
  String cloudBookId,
  String textId,
  double score,
});

/// Content identity (`/api/texts/identify`). Background work: calls never
/// prompt sign-in and fail without an existing session.
abstract interface class TextIdentityApi {
  /// Resolves [book] to the shared text its [fingerprints] align with, or a
  /// new one. Only the fingerprints leave the device, never the text.
  Future<TextIdentityResult> identify(
    CatalogBook book,
    BookFingerprints fingerprints,
  );
}
