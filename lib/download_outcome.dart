// Pure decision table for one chapter download attempt, shared by the
// download isolate (`lib/download_manager.dart`) and its tests. No
// `package:flutter/...`, drift, or network imports so it stays unit-testable.
//
// The rule the download manager implements (bug: it used to dequeue chapters
// on *any* failure, silently emptying a queue when a site served bot
// challenges or a transient 429/5xx hit):
//
//  1. An anti-bot challenge page (Cloudflare *or* Anubis — Anubis arrives
//     with HTTP 200, so it must be detected by body, and checked *first*)
//     means "blocked, not gone": keep the queue, back off slowly.
//  2. Only a genuine gone-for-good status (404/410) may drop a chapter.
//  3. A successfully parsed chapter is saved.
//  4. A 2xx page that failed to parse (and is not a challenge) will never
//     parse on retry either: dequeue that one chapter.
//  5. Everything transient (429, 5xx, unknown/timeout status) stays queued
//     with backoff.

import 'package:story_reader/sh_toc.dart';

/// What the download manager should do with a queued chapter after one fetch
/// attempt.
enum DownloadOutcome {
  /// Content parsed: save it.
  save,

  /// The chapter is gone for good (404/410) or its page can never parse:
  /// drop it from the queue.
  dequeue,

  /// Transient failure (5xx, other non-success, timeout): keep queued, short
  /// backoff.
  retrySoon,

  /// Rate limit (429) or an anti-bot challenge: keep queued, long backoff.
  retrySlow,
}

/// Decides the fate of one queued chapter from its raw fetch result.
///
/// [status] is the HTTP status (`null` when no response arrived at all —
/// timeout/connection error). [body] is the raw response body (may be null
/// or empty when the transport failed). [parsed] is whether the chapter
/// content was successfully extracted from that body.
DownloadOutcome classifyChapterFetch(
    int? status, String? body, bool parsed) {
  // Blocked, not gone — and Anubis arrives with HTTP 200, so this must be
  // checked before any status-based rule.
  if (isBotChallenge(status, body)) {
    return DownloadOutcome.retrySlow;
  }
  // Gone for good: the only statuses that may drop a chapter.
  if (status == 404 || status == 410) {
    return DownloadOutcome.dequeue;
  }
  if (parsed) {
    return DownloadOutcome.save;
  }
  if (status != null && status >= 200 && status < 300) {
    // A real page that failed to parse: retrying the same HTML can never
    // succeed — dequeue just this chapter, keep the rest of the queue.
    return DownloadOutcome.dequeue;
  }
  if (status == 429) {
    // Rate limited: long backoff, queue untouched.
    return DownloadOutcome.retrySlow;
  }
  // 5xx, other non-success, or no response at all (timeout): transient.
  return DownloadOutcome.retrySoon;
}
