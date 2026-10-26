
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP client used for every site request (the ScribbleHub/RoyalRoad chopper
/// clients and the image-fetching isolate).
///
/// UA policy — measured live (2026-10) against ScribbleHub and RoyalRoad, both
/// behind Cloudflare: requests that claim a browser User-Agent while carrying
/// the `dart:io` TLS fingerprint (e.g. the Firefox UA this file used to set,
/// and which curl gets away with thanks to its different fingerprint) are
/// answered with a 403 "Just a moment…" interstitial on *both* sites, while
/// the honest `dart:io` default User-Agent returns 200. The clients therefore
/// deliberately do not spoof a browser; they keep the default UA. ScribbleHub
/// additionally requires the series page as `Referer` on `?toc=N` TOC requests
/// (see `SHAPI._seriesToc`).
http.Client httpClient() {
  return IOClient(HttpClient());
}
