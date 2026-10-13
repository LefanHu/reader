import 'package:flutter_test/flutter_test.dart';
import 'package:reader/generation_fence.dart';

void main() {
  test('invalidate retires every earlier ticket but not later ones', () {
    final fence = GenerationFence();
    final first = fence.capture();
    final second = fence.capture();
    expect(first, second);
    fence.invalidate();
    final third = fence.capture();
    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isFalse);
    expect(third.isCurrent, isTrue);
    expect(third, isNot(first));
  });

  test('keyed fences invalidate only their own key', () {
    final fences = KeyedGenerationFence<String>();
    final a = fences.capture('a');
    final b = fences.capture('b');
    fences.invalidate('a');
    fences.invalidate('missing');
    expect(a.isCurrent, isFalse);
    expect(b.isCurrent, isTrue);
    expect(fences.capture('a').isCurrent, isTrue);
  });

  test('tickets from different fences are never equal', () {
    expect(GenerationFence().capture(), isNot(GenerationFence().capture()));
  });
}
