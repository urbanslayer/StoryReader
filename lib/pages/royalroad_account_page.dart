// RoyalRoad account screen: optional sign-in (WebView-hosted — the app never
// sees the password) and "Import my Follows" into the library.
//
// Reached from Settings → "RoyalRoad account" (route `/rrAccount`).
//
// Sign-in status is read by loading https://www.royalroad.com/account
// through the shared headless WebView (`BrowserFetcher`) and parsing the
// document ([parseRoyalRoadAccount]): a logout link ⇒ signed in (with the
// display name), a login form ⇒ signed out, anything else (a challenge page
// the user cancelled, an unknown shape) ⇒ unknown. Cloudflare checks that
// appear during these fetches reuse the existing verification screen.
//
// "Log in" opens a **visible** WebView on RoyalRoad's own login page (the
// Cloudflare interstitial may show there first — the user just completes it
// in the same view). Success is detected passively: the view navigated away
// from `/account/login` *and* the shared cookie jar now carries an ASP.NET
// identity session cookie (names only, values never read or logged). No JS
// is injected into the form and no field is ever read.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/rr_auth.dart';
import 'package:story_reader/rr_follows.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/sh_toc.dart';

enum _LoginStatus { checking, signedOut, signedIn, unknown, unsupported }

class RoyalRoadAccountPage extends StatefulWidget {
  const RoyalRoadAccountPage({super.key});

  @override
  State<RoyalRoadAccountPage> createState() => _RoyalRoadAccountPageState();
}

class _RoyalRoadAccountPageState extends State<RoyalRoadAccountPage> {
  _LoginStatus _status = _LoginStatus.checking;
  String _username = "";
  Uri? _logoutUrl;
  String? _statusDetail;

  /// True while the visible login WebView is on screen.
  bool _loginOpen = false;
  InAppWebViewController? _loginController;
  bool _loginSettled = false;

  /// Progress text while an import runs (null = idle); drives the progress
  /// dialog through a ValueNotifier so dialog rebuilds stay cheap.
  final ValueNotifier<String?> _importProgress = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    if (!BrowserFetcher.isSupported) {
      _status = _LoginStatus.unsupported;
    } else {
      _checkStatus();
    }
  }

  @override
  void dispose() {
    _importProgress.dispose();
    super.dispose();
  }

  bool get _busy => _importProgress.value != null;

  // ---- status ---------------------------------------------------------------

  Future<void> _checkStatus() async {
    if (!BrowserFetcher.isSupported) {
      setState(() => _status = _LoginStatus.unsupported);
      return;
    }
    setState(() => _status = _LoginStatus.checking);
    try {
      final html = await BrowserFetcher.instance
          .fetchHtml(royalRoadAccountUrl(), isReady: isRoyalRoadAccountReady);
      final state = parseRoyalRoadAccount(html);
      if (!mounted) return;
      if (state == null) {
        setState(() {
          _status = _LoginStatus.unknown;
          _statusDetail =
              "The RoyalRoad account page did not load in a recognisable "
                  "shape. Try again.";
        });
        return;
      }
      setState(() {
        _username = state.username;
        _status =
            state.loggedIn ? _LoginStatus.signedIn : _LoginStatus.signedOut;
        _logoutUrl = state.loggedIn ? royalRoadLogoutUrl(html) : null;
      });
    } on SiteBlocked catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _LoginStatus.unknown;
        _statusDetail =
            "RoyalRoad blocked the check (${e.kind?.name ?? "bot"} wall). "
                "Press Retry and complete the browser check.";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _LoginStatus.unknown;
        _statusDetail = "Could not check the sign-in status ($e). Try again.";
      });
    }
  }

  // ---- login ----------------------------------------------------------------

  void _openLogin() {
    setState(() {
      _loginOpen = true;
      _loginSettled = false;
      _loginController = null;
    });
  }

  void _closeLogin({bool signedIn = false}) {
    if (!mounted) return;
    setState(() => _loginOpen = false);
    if (signedIn) _checkStatus();
  }

  /// Passive login-success detection: the view left the login page *and* a
  /// session cookie (by name) is in the shared jar. Values are never read.
  Future<void> _checkLoginNavigation() async {
    if (_loginSettled) return;
    final controller = _loginController;
    if (controller == null) return;
    try {
      final url = await controller.getUrl();
      final path = url?.toString().toLowerCase() ?? "";
      if (path.isEmpty || path.contains("/account/login")) return;
      if (await royalRoadHasAuthCookie()) {
        _loginSettled = true;
        _closeLogin(signedIn: true);
      }
    } catch (_) {
      // Mid-navigation: the next load/history event re-checks.
    }
  }

  // ---- logout ---------------------------------------------------------------

  Future<void> _logout() async {
    setState(() => _importProgress.value = "Signing out…");
    final result = await royalRoadLogout(logoutUrl: _logoutUrl);
    if (!mounted) return;
    _importProgress.value = null;
    final viaSite = result.method == RoyalRoadLogoutMethod.siteLogout;
    final cfNote = result.keptCloudflareCookies
        ? "The Cloudflare check was kept, so no new browser check should "
            "appear."
        : "All RoyalRoad cookies were cleared (a fresh browser check may "
            "appear).";
    _showSnack(viaSite
        ? "Signed out via RoyalRoad's own sign-out link. $cfNote"
        : "Signed out by clearing the RoyalRoad session cookies. $cfNote");
    await _checkStatus();
  }

  // ---- follows import ---------------------------------------------------------

  Future<void> _importFollows() async {
    if (_busy) return;
    _importProgress.value = "Importing your Follows…";
    FollowsImportReport? report;
    Object? error;
    try {
      report = await importRoyalRoadFollows(
        db: appDB,
        fetcher: BrowserFetcher.instance,
        fetchThumbnail:
            Preferences.useImages.value ? fetchRoyalRoadThumbnailBytes : null,
        onProgress: (pages, seen) {
          _importProgress.value =
              "Importing your Follows… page $pages, $seen series seen";
        },
      );
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    _importProgress.value = null;
    await showDialog(
      context: context,
      builder: (c) => _ImportSummaryDialog(report: report, error: error),
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("RoyalRoad account"),
        actions: _loginOpen
            ? [TextButton(onPressed: () => _closeLogin(), child: const Text("Close"))]
            : null,
      ),
      body: Stack(
        children: [
          Positioned.fill(
              child: _loginOpen ? _buildLoginWebView() : _buildAccountView()),
          ValueListenableBuilder<String?>(
            valueListenable: _importProgress,
            builder: (context, progress, _) => progress == null
                ? const SizedBox.shrink()
                : _ProgressOverlay(text: progress),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountView() {
    final signedIn = _status == _LoginStatus.signedIn;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusLine(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                ElevatedButton(
                  onPressed: _status == _LoginStatus.unsupported ||
                          _status == _LoginStatus.checking ||
                          signedIn ||
                          _busy
                      ? null
                      : _openLogin,
                  child: const Text("Log in"),
                ),
                ElevatedButton(
                  onPressed: signedIn && !_busy ? _logout : null,
                  child: const Text("Log out"),
                ),
                ElevatedButton(
                  onPressed: _status == _LoginStatus.checking || _busy
                      ? null
                      : _checkStatus,
                  child: const Text("Retry"),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: signedIn && !_busy ? _importFollows : null,
              child: const Text("Import my Follows"),
            ),
            const SizedBox(height: 8),
            Text(
              signedIn
                  ? "Adds each followed series to your library. Chapters are "
                      "not downloaded automatically — open a series and use "
                      "Download all / Export EPUB to fetch chapters."
                  : "Log in to import your Follows.",
              softWrap: true,
            ),
            const SizedBox(height: 24),
            const Text(
              "Your password is typed into RoyalRoad's own page inside the "
                  "built-in browser. StoryReader never sees, stores or logs "
                  "it — it only notices that the sign-in succeeded.",
              softWrap: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine() {
    final (text, icon) = switch (_status) {
      _LoginStatus.checking => ("Checking sign-in status…", Icons.hourglass_top),
      _LoginStatus.signedIn => (
          _username.isEmpty
              ? "Logged in"
              : "Logged in as $_username",
          Icons.check_circle
        ),
      _LoginStatus.signedOut => ("Not logged in", Icons.account_circle_outlined),
      _LoginStatus.unknown => (
          _statusDetail ?? "Sign-in status unknown.",
          Icons.help_outline
        ),
      _LoginStatus.unsupported => (
          "Sign-in needs a platform with WebViews (Android, iOS, macOS or "
              "Windows).",
          Icons.info_outline
        ),
    };
    return Row(
      children: [
        Icon(icon, size: 28),
        const SizedBox(width: 8),
        Flexible(child: Text(text, softWrap: true)),
      ],
    );
  }

  Widget _buildLoginWebView() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            "Sign in on RoyalRoad's page below (a Cloudflare check may come "
            "first — just complete it). The screen closes by itself once "
            "you're signed in.",
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest:
                URLRequest(url: WebUri(royalRoadLoginPageUrl().toString())),
            // Default UA + shared platform cookie jar (the same WebView
            // family the fetcher uses), no JS injection into the form.
            onWebViewCreated: (controller) => _loginController = controller,
            onLoadStop: (_, __) => _checkLoginNavigation(),
            onUpdateVisitedHistory: (_, __, ___) => _checkLoginNavigation(),
          ),
        ),
      ],
    );
  }
}

class _ProgressOverlay extends StatelessWidget {
  const _ProgressOverlay({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(text, softWrap: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ImportSummaryDialog extends StatelessWidget {
  const _ImportSummaryDialog({this.report, this.error});

  final FollowsImportReport? report;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final String body;
    if (error != null) {
      body = switch (error) {
        RoyalRoadNotLoggedIn() =>
          "RoyalRoad sent you back to the login page — sign in again and "
              "retry the import.",
        SiteBlocked() =>
          "RoyalRoad blocked the import with a browser check. Press Retry, "
              "complete the check, and run the import again.",
        _ => "The import failed: $error",
      };
    } else {
      body = "${report!.summary}\n\n"
          "Open a series and use Download all / Export EPUB to fetch "
          "chapters.";
    }
    return AlertDialog(
      title: Text(error == null ? "Follows import" : "Follows import failed"),
      content: Text(body, softWrap: true),
      actions: [
        ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Close")),
      ],
    );
  }
}
