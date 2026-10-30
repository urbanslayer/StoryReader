// Hermetic tests for the RoyalRoad sign-in plumbing: the pure account-page
// parser (logged in / logged out / wall), the login-page marker, the logout
// link extraction, and the cookie-name predicates the login/logout flows
// use. Fixtures are hand-written with placeholder text; no network, no real
// WebView (the cookie *predicates* are pure name matching; the CookieManager
// plumbing itself is exercised on device / by `flutter build apk --debug`).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/rr_parse.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  final loggedIn = fixture('rr_account_logged_in.html');
  final loggedOut = fixture('rr_account_logged_out.html');
  final anubis = fixture('rr_anubis_challenge.html');
  final cloudflare = fixture('sh_cloudflare_interstitial.html');

  group('parseRoyalRoadAccount', () {
    test('logged-in page: logout link proves the session, name from the '
        'profile form', () {
      final state = parseRoyalRoadAccount(loggedIn);
      expect(state, isNotNull);
      expect(state!.loggedIn, isTrue);
      expect(state.username, 'Placeholder Reader');
    });

    test('logged-out page (login form) is an explicit signed-out state', () {
      final state = parseRoyalRoadAccount(loggedOut);
      expect(state, isNotNull);
      expect(state!.loggedIn, isFalse);
      expect(state.username, isEmpty);
    });

    test('anti-bot challenge pages parse to null — never a fake sign-in '
        'state', () {
      expect(parseRoyalRoadAccount(anubis), isNull);
      expect(parseRoyalRoadAccount(cloudflare), isNull);
    });

    test('unparseable garbage yields null, never a crash', () {
      expect(parseRoyalRoadAccount('not html at all <<<'), isNull);
      expect(parseRoyalRoadAccount(''), isNull);
    });
  });

  group('isRoyalRoadLoginPage', () {
    test('only the login page matches', () {
      expect(isRoyalRoadLoginPage(loggedOut), isTrue);
      expect(isRoyalRoadLoginPage(loginLoggedInVariant()), isFalse);
      expect(isRoyalRoadLoginPage(anubis), isFalse);
      expect(isRoyalRoadLoginPage(cloudflare), isFalse);
    });
  });

  group('isRoyalRoadAccountReady', () {
    test('accepts both account-page shapes and rejects the walls', () {
      expect(isRoyalRoadAccountReady(loggedIn), isTrue);
      expect(isRoyalRoadAccountReady(loggedOut), isTrue);
      expect(isRoyalRoadAccountReady(anubis), isFalse);
      expect(isRoyalRoadAccountReady(cloudflare), isFalse);
    });
  });

  group('royalRoadLogoutUrl', () {
    test('resolves the Sign-Out link against the site base', () {
      expect(royalRoadLogoutUrl(loggedIn).toString(),
          'https://www.royalroad.com/Account/Logout');
    });
    test('login page / garbage carry no logout link', () {
      expect(royalRoadLogoutUrl(loggedOut), isNull);
      expect(royalRoadLogoutUrl('garbage <<<'), isNull);
    });
  });

  group('cookie-name predicates (values are never inspected)', () {
    test('the ASP.NET Core identity session cookie proves sign-in', () {
      expect(
          hasRoyalRoadAuthCookie(
              ['cf_clearance', '.AspNetCore.Identity.Application']),
          isTrue);
      expect(isRoyalRoadAuthCookieName('.aspnetcore.identity.application'),
          isTrue,
          reason: 'matching is case-insensitive (cookie names vary)');
    });

    test('Cloudflare cookies alone do NOT prove sign-in', () {
      expect(hasRoyalRoadAuthCookie(['cf_clearance', '__cf_bm']), isFalse);
    });

    test('Cloudflare cookies are the ones logout must keep', () {
      expect(isRoyalRoadCloudflareCookieName('cf_clearance'), isTrue);
      expect(isRoyalRoadCloudflareCookieName('_cf_bm'), isTrue);
      expect(isRoyalRoadCloudflareCookieName('CF_CHL_PROOF'), isTrue);
      expect(
          isRoyalRoadCloudflareCookieName('.AspNetCore.Identity.Application'),
          isFalse);
      expect(isRoyalRoadCloudflareCookieName('PHPSESSID'), isFalse);
    });
  });
}

/// Logged-in page variant that also mentions a password change (the account
/// page legitimately carries a "new password" input — it must not be
/// mistaken for the login page while a logout link is present).
String loginLoggedInVariant() =>
    fixture('rr_account_logged_in.html').replaceAll(
        '<button type="submit">Save</button>',
        '<input type="password" name="NewPassword" />'
        '<button type="submit">Save</button>');
