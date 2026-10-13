/// Invalidation boundary for asynchronous work that must not act after its
/// owner moved on: an account action, a deletion, suspension or a newer run.
///
/// Work captures a [FenceTicket] before awaiting and checks
/// [FenceTicket.isCurrent] after every await; [invalidate] retires all
/// outstanding tickets at once, synchronously.
class GenerationFence {
  int _generation = 0;

  /// Retires every ticket captured so far.
  void invalidate() => _generation++;

  /// A ticket that stays current until the next [invalidate].
  FenceTicket capture() => FenceTicket._(this, _generation);
}

/// One captured generation of a [GenerationFence].
///
/// Tickets compare equal when they belong to the same fence and generation,
/// so a cached verification can be keyed by the ticket that produced it.
class FenceTicket {
  const FenceTicket._(this._fence, this._generation);

  final GenerationFence _fence;
  final int _generation;

  /// Whether the fence has not been invalidated since capture.
  bool get isCurrent => _fence._generation == _generation;

  @override
  bool operator ==(Object other) =>
      other is FenceTicket &&
      identical(other._fence, _fence) &&
      other._generation == _generation;

  @override
  int get hashCode => Object.hash(identityHashCode(_fence), _generation);
}

/// Independent [GenerationFence]s per key, such as one per book import.
///
/// A key's fence is created on first capture and kept for the owner's
/// lifetime, so invalidating it still retires tickets captured earlier.
class KeyedGenerationFence<K> {
  final Map<K, GenerationFence> _fences = {};

  /// A ticket for [key] that stays current until [invalidate] for that key.
  FenceTicket capture(K key) => (_fences[key] ??= GenerationFence()).capture();

  /// Retires every ticket captured for [key].
  void invalidate(K key) => _fences[key]?.invalidate();
}
