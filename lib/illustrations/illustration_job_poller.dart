import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catalog/catalog_book.dart';
import 'api.dart';
import 'illustration_job_result.dart';
import 'illustration_manifest.dart';
import 'illustration_scene.dart';
import 'store.dart';

/// Polls a book's server chapter jobs and merges their scenes into the
/// coordinator-owned manifests.
///
/// Network awaits never overwrite local decisions: results merge into the
/// newest manifest, and scenes removed locally while a poll was in flight stay
/// removed. Only real scene changes are saved and published.
class IllustrationJobPoller {
  /// Borrows the coordinator's authoritative [manifests] map.
  IllustrationJobPoller({
    required this.api,
    required this.store,
    required this.manifests,
    required this.currentBook,
    required this.changed,
    required this.replacementFailed,
  });

  /// Cloud job status boundary.
  final IllustrationApi api;

  /// Persists merged manifests.
  final IllustrationStore store;

  /// Authoritative manifests owned by the illustration coordinator.
  final Map<String, IllustrationManifest> manifests;

  /// The live catalog entry for a book, or null once it was deleted.
  final CatalogBook? Function(CatalogBook) currentBook;

  /// Publishes a committed manifest change.
  final VoidCallback changed;

  /// Reports that a regeneration failed while earlier art stays available.
  final VoidCallback replacementFailed;

  final Map<String, DateTime> _lastPoll = {};

  /// Whether each book's server jobs still await image generation; shortens the
  /// poll interval so inline placeholders turn into art promptly.
  final Map<String, bool> _active = {};

  /// Job IDs the server reported terminal. Their scenes change afterwards only
  /// through regeneration, so they are polled again only while a local scene
  /// of that job is still queued, generating or regenerating.
  final Set<String> _settled = {};

  /// Marks a book as having just-admitted server work to poll quickly.
  void markActive(String bookHash) => _active[bookHash] = true;

  /// Makes the next [pollIfDue] for the book poll immediately.
  void expedite(String bookHash) => _lastPoll.remove(bookHash);

  /// Drops polling state for a book and its jobs.
  void forget(String bookHash, Iterable<String> jobIds) {
    _settled.removeAll(jobIds);
    _active.remove(bookHash);
    _lastPoll.remove(bookHash);
  }

  /// Polls every 4 s while server work is in flight, otherwise every 15 s.
  Future<void> pollIfDue(CatalogBook book) async {
    final last = _lastPoll[book.hash];
    final interval = Duration(seconds: _active[book.hash] == true ? 4 : 15);
    if (last != null && DateTime.now().difference(last) <= interval) return;
    await _poll(book);
    _lastPoll[book.hash] = DateTime.now();
  }

  Future<void> _poll(CatalogBook book) async {
    final beforePolling = manifests[book.hash];
    if (beforePolling?.enabled != true || currentBook(book) == null) return;
    final unsettledJobs = {
      for (final scene in beforePolling!.scenes)
        if (scene.jobId != null &&
            (scene.regenerating ||
                scene.state == IllustrationSceneState.queued ||
                scene.state == IllustrationSceneState.generating))
          scene.jobId!,
    };
    final incomingScenes = <IllustrationScene>[];
    final results = <IllustrationJobResult>[];
    for (final jobId in beforePolling.chapterJobs.values) {
      if (_settled.contains(jobId) && !unsettledJobs.contains(jobId)) {
        continue;
      }
      final result = await api.getJob(jobId);
      results.add(result);
      incomingScenes.addAll(result.scenes);
      if (const {
        'complete',
        'failed',
        'insufficient_credits',
      }.contains(result.status)) {
        _settled.add(jobId);
      }
    }
    // The server keeps a job analyzing through image generation.
    _active[book.hash] = results.any(
      (result) => result.status == 'queued' || result.status == 'analyzing',
    );
    if (incomingScenes.isEmpty) return;
    // Polling awaits network IO; merge into the newest local path state.
    final current = manifests[book.hash];
    if (current?.enabled != true || currentBook(book) == null) return;
    final scenes = List<IllustrationScene>.of(current!.scenes);
    final positions = {for (var i = 0; i < scenes.length; i++) scenes[i].id: i};
    final previouslyKnown = {
      for (final scene in beforePolling.scenes) scene.id,
    };
    for (final incoming in incomingScenes) {
      final index = positions[incoming.id];
      if (index == null) {
        if (previouslyKnown.contains(incoming.id)) {
          continue; // Removed locally while this poll was awaiting network IO.
        }
        positions[incoming.id] = scenes.length;
        scenes.add(incoming);
      } else {
        scenes[index] = _merge(scenes[index], incoming);
      }
    }
    final manifest = current.copyWith(scenes: scenes);
    // Most polls observe no change; skip the sidecar write and the app-wide
    // rebuild unless a scene actually moved.
    if (jsonEncode(manifest.toJson()) == jsonEncode(current.toJson())) return;
    await store.saveManifest(book, manifest);
    manifests[book.hash] = manifest;
    changed();
  }

  /// Applies a polled server scene to the committed local one. Committed art
  /// is never replaced here: a newer ready generation only becomes pending,
  /// for the art committer to download and commit.
  IllustrationScene _merge(
    IllustrationScene committed,
    IllustrationScene incoming,
  ) {
    if (incoming.generation < committed.generation) {
      return committed;
    }
    final generating =
        incoming.regenerating ||
        incoming.state == IllustrationSceneState.generating ||
        incoming.state == IllustrationSceneState.queued;
    final ready = incoming.state == IllustrationSceneState.readyLocked;
    if (committed.localImagePath == null) {
      return committed.copyWith(
        state: incoming.state,
        generation: incoming.generation,
        regenerating: incoming.regenerating,
        pendingGeneration: null,
        failureCategory: incoming.failureCategory,
      );
    }
    if (generating) {
      return committed.copyWith(
        regenerating: true,
        pendingGeneration: null,
        failureCategory: null,
      );
    }
    if (ready && incoming.generation > committed.generation) {
      return committed.copyWith(
        regenerating: false,
        pendingGeneration:
            (committed.pendingGeneration ?? 0) > incoming.generation
            ? committed.pendingGeneration
            : incoming.generation,
        failureCategory: null,
      );
    }
    final failed =
        incoming.failureCategory != null ||
        incoming.state == IllustrationSceneState.failed ||
        incoming.state == IllustrationSceneState.skippedSafety;
    if (failed) replacementFailed();
    if (!failed && ready && committed.pendingGeneration != null) {
      // An older ready poll cannot discard a replacement already seen locally.
      return committed.copyWith(regenerating: false, failureCategory: null);
    }
    return committed.copyWith(
      regenerating: false,
      pendingGeneration: null,
      failureCategory: incoming.failureCategory,
    );
  }
}
