import 'package:reader/text/book_word_counter.dart';

/// Default test backfill keeps widget scenarios independent of filesystem work.
class FakeWordCounter implements BookWordCounter {
  @override
  Future<int> count(String sourcePath) async => 42;
}
