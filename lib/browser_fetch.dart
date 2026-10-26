// WebView-backed HTML fetcher for pages that no non-browser client can load
// (ScribbleHub chapter pages sit behind a Cloudflare managed challenge that
// 403s every dart:io/curl request, 2026-10). One reused [HeadlessInAppWebView]
// loads the page with the default WebView User-Agent (deliberately *not*
// overridden), waits for the JS challenge to clear itself, and returns the
// rendered DOM. If the challenge demands a human, a verification request is
// published on [verificationNeeded]; `lib/pages/verify_page.dart` shows the
// page to the user and completes the request via [completeVerification] /
// [cancelVerification].
//
// Cookie continuity (why this works against Cloudflare): on Android the
// plugin drives the platform `android.webkit.CookieManager`, which is a
// per-app singleton — every WebView in the process (headless and visible)
// shares one jar, and the WebView data directory persists across app
// restarts, so a solved `cf_clearance` survives. The same holds on iOS/macOS
// (shared default WKWebsiteDataStore) and Windows (shared WebView2 user data
// folder). The visible verification WebView and the headless fetch WebView
// therefore feed each other automatically. (To be re-confirmed on a real
// device; it is the plugin's documented platform behaviour.)

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:story_reader/browser_download_loop.dart';
import 'package:story_reader/sh_toc.dart';

/// Singleton [HtmlFetcher] backed by one reused [HeadlessInAppWebView].
///
/// Fetches are serialised (WebView + Cloudflare cookies are shared state) and
/// politely paced ([pacing] between consecutive page loads).
final class BrowserFetcher implements HtmlFetcher {
  BrowserFetcher._();

  /// Process-wide singleton; WebViews are heavy and must not proliferate.
  static final BrowserFetcher instance = BrowserFetcher._();

  /// WebViews exist on Android/iOS/macOS/Windows (via the plugin's platform
  /// implementations). On Linux (dev desktop) there is no implementation —
  /// callers keep the plain HTTP path there.
  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;

  /// Budget for one page load + self-clearing JS challenge grace, per round.
  /// User verification time is *excluded* (each verification starts a fresh
  /// round).
  static const Duration pageTimeout = Duration(seconds: 45);

  /// How long to wait for a non-interactive Cloudflare challenge to solve
  /// itself inside the WebView before raising a verification request. Covered
  /// by [pageTimeout]'s poll loop.
  static const Duration challengeGrace = Duration(seconds: 20);

  /// Minimum gap between consecutive page fetches (site politeness).
  static const Duration pacing = Duration(milliseconds: 1500);

  /// Cap on human-verification rounds per [fetchHtml] call; after that the
  /// chapter stays queued with [SiteBlocked].
  static const int maxVerificationRounds = 3;

  /// Upper bound on one user-verification wait (user-paced, but a forgotten
  /// verification screen must not wedge the queue forever).
  static const Duration verificationWindow = Duration(minutes: 10);

  /// Poll interval while waiting for the page to become ready.
  static const Duration pollInterval = Duration(seconds: 1);

  /// Set to the challenged URL while a human verification is pending, null
  /// otherwise. The root widget listens for this and shows the verification
  /// screen; only one verification is ever in flight (fetches are serialised).
  final ValueNotifier<Uri?> verificationNeeded = ValueNotifier<Uri?>(null);

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;

  /// Completed by the WebView's load-stop / load-error callbacks.
  Completer<void>? _loadStop;

  /// Serialisation chain: one fetch (and at most one verification) at a time.
  Future<void> _tail = Future.value();

  DateTime _lastFetchEnd = DateTime.fromMillisecondsSinceEpoch(0);

  Completer<bool>? _verification;

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) {
    final gated = _tail.then(
        (_) => _fetchGated(url, isReady),
        onError: (Object _) => _fetchGated(url, isReady));
    // Keep the chain alive regardless of this fetch's outcome.
    _tail = gated.then((_) {}, onError: (_) {});
    return gated;
  }

  Future<String> _fetchGated(Uri url, bool Function(String html) isReady) async {
    final sinceLast = DateTime.now().difference(_lastFetchEnd);
    if (sinceLast < pacing) {
      await Future.delayed(pacing - sinceLast);
    }
    try {
      return await _fetch(url, isReady);
    } finally {
      _lastFetchEnd = DateTime.now();
    }
  }

  Future<String> _fetch(Uri url, bool Function(String html) isReady) async {
    final controller = await _ensureController();
    for (var round = 0;; round++) {
      final budget = Stopwatch()..start();
      Duration left() {
        final r = pageTimeout - budget.elapsed;
        return r.isNegative ? Duration.zero : r;
      }

      await _navigate(controller, url, left());
      var html = await _readHtml(controller);
      // Wait out the self-clearing JS challenge / late rendering inside the
      // page budget (challengeGrace <= pageTimeout).
      while (!isReady(html) && left() > Duration.zero) {
        await Future.delayed(pollInterval);
        html = await _readHtml(controller);
      }
      if (isReady(html)) return html;

      if (html.isEmpty) {
        // No readable document at all (navigation/WebView trouble): treat as
        // transient so the queue survives and retries.
        throw TimeoutException(
            "WebView returned no document for $url", pageTimeout);
      }
      if (!isBotChallenge(null, html)) {
        // A real page that never grew the expected content — the caller's
        // parser decides; a page that cannot parse is dequeued there
        // (retrying the same HTML would never help).
        return html;
      }
      if (round >= maxVerificationRounds) {
        throw _blocked(url, html);
      }
      final solved = await _requestVerification(url);
      if (!solved) throw _blocked(url, html); // user cancelled / timed out
      // Fresh round: the visible verification WebView solved the challenge
      // into the shared cookie jar; reload the headless one with it.
    }
  }

  SiteBlocked _blocked(Uri url, String html) => SiteBlocked(
        url.toString(),
        kind: botChallengeKind(null, html) ?? BotChallengeKind.cloudflare,
        siteName: "ScribbleHub",
      );

  // ---- verification hand-off -------------------------------------------

  Future<bool> _requestVerification(Uri url) async {
    assert(_verification == null, "fetches are serialised: one at a time");
    final c = Completer<bool>();
    _verification = c;
    verificationNeeded.value = url;
    bool solved;
    try {
      solved = await c.future.timeout(verificationWindow,
          onTimeout: () => false);
    } finally {
      _verification = null;
      verificationNeeded.value = null;
    }
    return solved;
  }

  /// Called by the verification screen when the page stopped being a
  /// challenge: the fetcher re-checks the headless page (fresh cookies).
  void completeVerification() {
    final c = _verification;
    if (c != null && !c.isCompleted) c.complete(true);
  }

  /// Called by the verification screen's Cancel: the fetch fails with
  /// [SiteBlocked] and the chapter stays queued.
  void cancelVerification() {
    final c = _verification;
    if (c != null && !c.isCompleted) c.complete(false);
  }

  bool get verificationPending => _verification != null;

  // ---- WebView plumbing ---------------------------------------------------

  Future<InAppWebViewController> _ensureController() async {
    final existing = _controller;
    if (existing != null) return existing;
    final created = Completer<InAppWebViewController>();
    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri("about:blank")),
      // NOTE: no userAgent override — the default Android System WebView UA
      // is exactly what Cloudflare expects to see.
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        clearCache: false,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
      onWebViewCreated: (controller) {
        if (!created.isCompleted) created.complete(controller);
      },
      onLoadStop: (_, __) => _noteLoadStop(),
      onReceivedError: (_, request, __) {
        // Main-frame failures still end the navigation; let the poll loop
        // inspect whatever document is on screen.
        if (request.isForMainFrame ?? false) _noteLoadStop();
      },
    );
    await _headless!.run();
    final controller = await created.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () =>
            throw TimeoutException("Could not create the WebView"));
    _controller = controller;
    return controller;
  }

  void _noteLoadStop() {
    final c = _loadStop;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _navigate(
      InAppWebViewController controller, Uri url, Duration timeout) async {
    final stop = Completer<void>();
    _loadStop = stop;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
    // Even on timeout we read the document: the challenge page itself is a
    // usable signal, and the poll loop distinguishes challenge from content.
    await stop.future.timeout(timeout, onTimeout: () {});
  }

  Future<String> _readHtml(InAppWebViewController controller) async {
    final value = await controller.evaluateJavascript(
        source:
            "document.documentElement ? document.documentElement.outerHTML : null");
    return value is String ? value : "";
  }

  /// Tears the headless WebView down (e.g. when the download manager stops).
  Future<void> dispose() async {
    final h = _headless;
    _headless = null;
    _controller = null;
    cancelVerification();
    if (h != null) await h.dispose();
  }
}
