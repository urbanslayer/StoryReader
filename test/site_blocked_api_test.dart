// Hermetic tests: when the sites answer with an anti-bot challenge page, the
// API layer must throw a typed SiteBlocked naming the site and the challenge
// kind — not crash on a null-check deep inside parsing (regression: on the
// captured RoyalRoad Anubis page, `querySelector(".fiction-list")!` in
// rr.dart threw "Null check operator used on a null value", and the download
// isolate then dequeued the whole chapter queue).
//
// No network: chopper clients run against `MockClient` replaying fixtures.

import 'dart:convert';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_toc.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

final anubis = fixture('rr_anubis_challenge.html');
final cloudflare = fixture('sh_cloudflare_interstitial.html');

/// Chopper client replaying [body] with [status] for every request, using the
/// production RetryInterceptor (proves the guards sit before any parse crash).
/// Bytes, not the `http.Response` String ctor: that encodes Latin-1 and the
/// fixtures contain non-Latin-1 characters.
ChopperClient _fakeClient(String body, int status) => ChopperClient(
      client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(body), status)),
      interceptors: [RetryInterceptor()],
    );

final fakeSeries = SeriesData(site: Site.royalRoad, id: '12345', name: 'A Story');

void main() {
  group('RRAPI throws SiteBlocked on an Anubis challenge (HTTP 200)', () {
    late RRAPI api;
    setUp(() => api = RRAPI.create(_fakeClient(anubis, 200)));

    test('series', () async {
      await expectLater(
          api.series('12345', 'A Story'),
          throwsA(isA<SiteBlocked>()
              .having((e) => e.kind, 'kind', BotChallengeKind.anubis)
              .having((e) => e.siteName, 'siteName', 'RoyalRoad')
              .having((e) => e.statusCode, 'statusCode', 200)));
    });

    test('simpleSearch', () async {
      await expectLater(api.simpleSearch('story'), throwsA(isA<SiteBlocked>()));
    });

    test('chapterContents', () async {
      await expectLater(
          api.chapterContents(fakeSeries, '678', 'Chapter One'),
          throwsA(isA<SiteBlocked>()
              .having((e) => e.kind, 'kind', BotChallengeKind.anubis)));
    });
  });

  group('SHAPI throws SiteBlocked on a Cloudflare interstitial (HTTP 403)', () {
    late SHAPI api;
    setUp(() => api = SHAPI.create(_fakeClient(cloudflare, 403)));

    test('series', () async {
      await expectLater(
          api.series('623932', 'On Astral Tides'),
          throwsA(isA<SiteBlocked>()
              .having((e) => e.kind, 'kind', BotChallengeKind.cloudflare)
              .having((e) => e.siteName, 'siteName', 'ScribbleHub')));
    });

    test('chapterContents', () async {
      await expectLater(
          api.chapterContents(
              SeriesData(site: Site.scribbleHub, id: '623932', name: 'On Astral Tides'),
              '2640407'),
          throwsA(isA<SiteBlocked>()
              .having((e) => e.userMessage, 'userMessage',
                  'ScribbleHub is asking for a browser check (Cloudflare). Try again later.')));
    });

    test('simpleSearch', () async {
      await expectLater(api.simpleSearch('astral'), throwsA(isA<SiteBlocked>()));
    });
  });

  group('RRAPI throws SiteBlocked on a Cloudflare interstitial (HTTP 403)', () {
    // Measured 2026-10: royalroad.com answers plain HTTP clients with a
    // Cloudflare "Just a moment..." 403 (it served an Anubis PoW 200 page
    // before — both kinds must map to SiteBlocked, with RoyalRoad named).
    late RRAPI api;
    setUp(() => api = RRAPI.create(_fakeClient(cloudflare, 403)));

    test('series', () async {
      await expectLater(
          api.series('111', 'Alpha One'),
          throwsA(isA<SiteBlocked>()
              .having((e) => e.kind, 'kind', BotChallengeKind.cloudflare)
              .having((e) => e.siteName, 'siteName', 'RoyalRoad')
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.userMessage, 'userMessage',
                  'RoyalRoad is asking for a browser check (Cloudflare). Try again later.')));
    });

    test('simpleSearch', () async {
      await expectLater(api.simpleSearch('alpha'), throwsA(isA<SiteBlocked>()));
    });

    test('chapterContents', () async {
      await expectLater(
          api.chapterContents(
              SeriesData(site: Site.royalRoad, id: '111', name: 'Alpha One'),
              '901', 'Chapter One'),
          throwsA(isA<SiteBlocked>()));
    });
  });
}
