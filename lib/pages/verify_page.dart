import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/sh_toc.dart';

/// Full-screen human-verification screen for an anti-bot challenge
/// (ScribbleHub / Cloudflare).
///
/// Pushed by the root widget whenever [BrowserFetcher.verificationNeeded]
/// fires: shows a **visible** WebView on the challenged URL (it shares the
/// platform cookie jar with the headless fetch WebView, so solving the check
/// here unblocks the download automatically). When the loaded page stops
/// looking like a challenge the pending verification is completed and this
/// route pops; Cancel fails the current fetch with `SiteBlocked` and the
/// chapter stays queued.
class VerifyPage extends StatefulWidget {
  const VerifyPage({super.key, required this.url});

  final Uri url;

  @override
  State<VerifyPage> createState() => _VerifyPageState();
}

class _VerifyPageState extends State<VerifyPage> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _settled = false;

  @override
  void dispose() {
    _poll?.cancel();
    // If the screen goes away without a decision (system back, route popped),
    // treat it as a cancel so the fetcher never waits forever.
    _cancel();
    super.dispose();
  }

  void _settle({required bool solved}) {
    if (_settled) return;
    _settled = true;
    _poll?.cancel();
    if (solved) {
      BrowserFetcher.instance.completeVerification();
    } else {
      BrowserFetcher.instance.cancelVerification();
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _cancel() => _settle(solved: false);

  /// True when the visible page is no longer an anti-bot interstitial.
  Future<bool> _pageCleared() async {
    final controller = _controller;
    if (controller == null) return false;
    final value = await controller.evaluateJavascript(
        source:
            "document.documentElement ? document.documentElement.outerHTML : null");
    if (value is! String || value.isEmpty) return false;
    if (isBotChallenge(null, value)) return false;
    // The challenge page also auto-navigates to the real chapter once
    // solved; any non-challenge document counts for the fetcher, which
    // re-verifies readiness on its own headless reload.
    return true;
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      if (_settled || !mounted) return;
      try {
        if (await _pageCleared()) _settle(solved: true);
      } catch (_) {
        // evaluateJavascript mid-navigation: next tick retries.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Verification needed"),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(onPressed: _cancel, child: const Text("Cancel")),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              "ScribbleHub wants to confirm you're human — complete the "
              "check, the download continues automatically.",
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
              // Default User-Agent (the same WebView family the headless
              // fetcher uses) and the shared platform cookie jar: solving the
              // check here is what lets the headless reload pass.
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStop: (_, __) => _startPolling(),
            ),
          ),
        ],
      ),
    );
  }
}
