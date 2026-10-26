// Hermetic tests for the download-manager decision table (no network, no DB).
//
// Regression: the download isolate used to dequeue a chapter on *any* failure
// — RetryInterceptor hands back the last response with a null body after 3
// tries, so 429/5xx emptied the queue, and RoyalRoad's Anubis challenge
// (HTTP 200, unparseable) crashed the parser into an Error, which also
// dequeued. The classifier must keep the queue on everything transient and
// drop chapters only when they are genuinely gone or unparseable-for-good.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/download_outcome.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  final anubis = fixture('rr_anubis_challenge.html');
  final cloudflare = fixture('sh_cloudflare_interstitial.html');
  final realChapterish = fixture('sh_series_page_live.html');

  group('classifyChapterFetch — bot challenges first (keep queue, slow backoff)', () {
    test('Anubis page with HTTP 200 -> retrySlow, never dequeue', () {
      expect(classifyChapterFetch(200, anubis, false), DownloadOutcome.retrySlow);
    });

    test('Cloudflare 403 interstitial -> retrySlow', () {
      expect(classifyChapterFetch(403, cloudflare, false), DownloadOutcome.retrySlow);
      expect(classifyChapterFetch(403, '', false), DownloadOutcome.retrySlow);
    });

    test('challenge wins over a 404 status (blocked, not gone)', () {
      expect(classifyChapterFetch(404, anubis, false), DownloadOutcome.retrySlow);
    });
  });

  group('classifyChapterFetch — only 404/410 dequeue a failed fetch', () {
    test('404 / 410 with empty body -> dequeue', () {
      expect(classifyChapterFetch(404, null, false), DownloadOutcome.dequeue);
      expect(classifyChapterFetch(404, '', false), DownloadOutcome.dequeue);
      expect(classifyChapterFetch(410, null, false), DownloadOutcome.dequeue);
    });
  });

  group('classifyChapterFetch — transient failures keep the queue', () {
    test('429 rate limit (null body after RetryInterceptor gives up) -> retrySlow', () {
      expect(classifyChapterFetch(429, null, false), DownloadOutcome.retrySlow);
      expect(classifyChapterFetch(429, '', false), DownloadOutcome.retrySlow);
    });

    test('5xx and other non-success -> retrySoon', () {
      expect(classifyChapterFetch(500, 'server exploded', false), DownloadOutcome.retrySoon);
      expect(classifyChapterFetch(503, null, false), DownloadOutcome.retrySoon);
      expect(classifyChapterFetch(418, 'teapot', false), DownloadOutcome.retrySoon);
    });

    test('no response at all (timeout/connection error) -> retrySoon', () {
      expect(classifyChapterFetch(null, null, false), DownloadOutcome.retrySoon);
      expect(classifyChapterFetch(null, '', false), DownloadOutcome.retrySoon);
    });
  });

  group('classifyChapterFetch — parse results', () {
    test('parsed content -> save', () {
      expect(classifyChapterFetch(200, realChapterish, true), DownloadOutcome.save);
    });

    test('200 page that failed to parse (not a challenge) -> dequeue this chapter', () {
      expect(classifyChapterFetch(200, '<html><body>moved house</body></html>', false),
          DownloadOutcome.dequeue);
      expect(classifyChapterFetch(200, '', false), DownloadOutcome.dequeue);
    });

    test('success status with null body -> dequeue (unparseable 2xx)', () {
      expect(classifyChapterFetch(200, null, false), DownloadOutcome.dequeue);
    });
  });
}
