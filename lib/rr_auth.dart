// RoyalRoad sign-in state on the shared platform cookie jar, plus logout.
//
// The plugin drives the per-app `android.webkit.CookieManager` singleton
// (see `lib/browser_fetch.dart`), so these helpers see exactly the cookies
// the headless fetch WebView and any visible WebView send to royalroad.com —
// including the session cookie the login page sets behind the user's back.
// The app only ever inspects cookie *names*; values are never logged and the
// password never leaves the login page's own form.

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/rr_parse.dart';

/// Whether the shared cookie jar holds a RoyalRoad session cookie (name
/// matching only — see [hasRoyalRoadAuthCookie]).
Future<bool> royalRoadHasAuthCookie() async {
  final cookies = await CookieManager.instance()
      .getCookies(url: WebUri(royalRoadCookieUrl));
  return hasRoyalRoadAuthCookie(cookies.map((c) => c.name));
}

/// How [royalRoadLogout] managed to sign the user out (wording for the UI).
enum RoyalRoadLogoutMethod {
  /// RoyalRoad's own logout link was followed (then the session cookies were
  /// swept as a belt-and-braces measure).
  siteLogout,

  /// No logout link was available/usable; only the cookie jar was cleared.
  cookiesOnly,
}

/// Outcome of [royalRoadLogout]: what was done and whether the Cloudflare
/// clearance survived (kept when possible so the user is not re-challenged).
final class RoyalRoadLogoutResult {
  final RoyalRoadLogoutMethod method;
  final bool keptCloudflareCookies;

  const RoyalRoadLogoutResult(
      {required this.method, required this.keptCloudflareCookies});
}

/// Signs the user out of RoyalRoad:
///
///  1. When the account page carried a logout link ([logoutUrl]), it is
///     loaded once through the headless WebView (RoyalRoad's Sign-Out is a
///     plain GET link) so the site ends the session server-side.
///  2. Every royalroad.com cookie whose *name* is not a Cloudflare cookie
///     (`cf_clearance`, `_cf_bm`, …) is then deleted individually — the
///     Cloudflare ones are deliberately kept so the next fetch is not
///     re-challenged. If a per-cookie delete fails, the whole jar for the
///     site is dropped instead and [RoyalRoadLogoutResult] reports the
///     Cloudflare cookies were lost.
///
/// Cookie values are only handed back to the CookieManager; nothing is
/// logged.
Future<RoyalRoadLogoutResult> royalRoadLogout({Uri? logoutUrl}) async {
  var method = RoyalRoadLogoutMethod.cookiesOnly;
  if (logoutUrl != null) {
    try {
      await BrowserFetcher.instance
          .fetchHtml(logoutUrl, isReady: (_) => true);
      method = RoyalRoadLogoutMethod.siteLogout;
    } catch (_) {
      // Site logout unavailable (blocked/timeout): fall back to cookies.
    }
  }

  final cm = CookieManager.instance();
  final url = WebUri(royalRoadCookieUrl);
  var keptCf = false;
  try {
    final cookies = await cm.getCookies(url: url);
    var deletedAny = false;
    var failed = false;
    for (final c in cookies) {
      if (isRoyalRoadCloudflareCookieName(c.name)) {
        keptCf = true;
        continue;
      }
      try {
        final ok = await cm.deleteCookie(
            url: url,
            name: c.name,
            path: c.path ?? "/",
            domain: c.domain ?? ".royalroad.com");
        deletedAny |= ok;
      } catch (_) {
        failed = true;
      }
    }
    if (failed || !deletedAny) {
      // Per-cookie delete unsupported/partial: wipe the site jar wholesale
      // (this also drops cf_clearance — the user may face one fresh check).
      await cm.deleteCookies(url: url);
      keptCf = false;
    }
  } catch (_) {
    // getCookies itself failed: still try the blunt instrument.
    try {
      await cm.deleteCookies(url: url);
    } catch (_) {}
    keptCf = false;
  }
  return RoyalRoadLogoutResult(method: method, keptCloudflareCookies: keptCf);
}
