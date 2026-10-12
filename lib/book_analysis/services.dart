import '../text/document_store.dart';
import 'api.dart';
import 'store.dart';

/// App-lifetime preprocessing dependencies; absent graphs remain entirely local.
/// Tests can inject an exact normalized-document boundary without cloud plugins.
typedef BookAnalysisServices = ({
  BookAnalysisApi api,
  AnalysisStore store,
  TextDocumentStore? documents,
});
