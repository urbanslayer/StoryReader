import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/network_form.dart';
import 'package:story_reader/port_scan.dart';

/// Where the exporting (sharing) app runs and which library format it speaks.
/// The sender validates the `X-Schema` header against its own `schemaVersion`
/// and allows exactly ONE request per sharing session (a rejected one consumes
/// it too). The fork's own format is known, so [LoadSource.forkRemote] just
/// announces it. The original upstream app's version is unknown (published
/// GitHub releases are schema 4 and 2, main-branch builds range up to 10) and
/// a mismatch is only signalled by "406: Schema mismatch", so for the
/// original-app sources the page announces one candidate format from
/// [kOriginalSchemaCandidates] per Load press and cycles to the next
/// candidate after every 406 — the user re-opens the share screen and presses
/// Load again until the format matches. "Advanced: library format" lets
/// users who know their version pin it directly.
enum LoadSource {
  /// Upstream StoryReader on the SAME phone: it binds 0.0.0.0 on a random
  /// port in 10000..10199, so the fork reaches it on 127.0.0.1 and
  /// auto-discovers the port — only the password has to be typed.
  originalSamePhone,

  /// Upstream StoryReader on another device.
  originalRemote,

  /// StoryReader+, this fork, on another device.
  forkRemote;

  /// Whether this source is the original, upstream app (unknown library
  /// format, needs the X-Schema candidate cycle).
  bool get isOriginal => this != LoadSource.forkRemote;

  bool get isSamePhone => this == LoadSource.originalSamePhone;
}

class LoadNetworkPage extends StatefulWidget {
  const LoadNetworkPage({super.key});

  @override
  State<LoadNetworkPage> createState() => _LoadNetworkPageState();
}

class _LoadNetworkPageState extends State<LoadNetworkPage> {
  static const _loopbackHost = "127.0.0.1";

  /// The original app picks its share port as `10000 + Random.secure().nextInt(200)`.
  static final List<int> _samePhonePorts = List.generate(200, (i) => 10000 + i);

  TextEditingController ipC = TextEditingController();
  TextEditingController portC = TextEditingController();
  TextEditingController pwdC = TextEditingController();

  /// Defaults to the original app on this phone: this page exists mostly to
  /// migrate an existing upstream install into the fork, and during the
  /// migration both apps live on the same device.
  LoadSource source = LoadSource.originalSamePhone;

  /// Same-phone fallback: show a port field when auto-discovery was
  /// ambiguous, or when the user prefers to type the port shown on the share
  /// screen themselves.
  bool showManualPort = false;

  /// `null` = Auto (cycle through [kOriginalSchemaCandidates] on 406);
  /// otherwise the format pinned under "Advanced: library format".
  int? explicitSchema;

  /// Index into [kOriginalSchemaCandidates] of the next format to announce.
  /// Persisted under [kSchemaCyclePrefKey] so the cycle survives leaving the
  /// page; reset on a successful import.
  int cycleIndex = 0;

  Future? loading;
  String? error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) {
        return;
      }
      var stored = prefs.getInt(kSchemaCyclePrefKey);
      if (stored != null) {
        setState(() =>
            cycleIndex = stored.clamp(0, kOriginalSchemaCandidates.length - 1));
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
    ipC.dispose();
    portC.dispose();
    pwdC.dispose();
  }

  /// The `X-Schema` value announced to the original app on the next attempt.
  int get effectiveSchema =>
      explicitSchema ?? kOriginalSchemaCandidates[cycleIndex];

  Future<void> _saveCycle(int index) async {
    cycleIndex = index.clamp(0, kOriginalSchemaCandidates.length - 1);
    var prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kSchemaCyclePrefKey, cycleIndex);
  }

  Future<void> _resetCycle() async {
    var prefs = await SharedPreferences.getInstance();
    await prefs.remove(kSchemaCyclePrefKey);
    cycleIndex = 0;
  }

  Future<void> _load() async {
    String? failure;
    bool forceManualPort = false;
    // The format announced this round: the fork knows its own, the original
    // app gets the current candidate / pinned format.
    final schema = source.isOriginal ? effectiveSchema : appDB.schemaVersion;
    // Validate everything BEFORE touching the network: the share server
    // burns its one-time session even on a rejected request, and a parse
    // crash (int.parse on an empty field) must never reach the wire.
    final invalid = validateLoadForm(
        samePhone: source.isSamePhone,
        manualPort: showManualPort,
        ip: ipC.text,
        port: portC.text,
        password: pwdC.text);
    if (invalid != null) {
      setState(() {
        error = invalid;
        loading = null;
      });
      return;
    }
    var mismatch406 = false;
    try {
      // Assigned unless `failure` was set; the HTTP call below is skipped then.
      late final String host;
      late final int port;
      if (source.isSamePhone) {
        host = _loopbackHost;
        final manual = int.tryParse(portC.text.trim());
        if (showManualPort && manual != null) {
          port = manual;
        } else {
          // Bare TCP connects never reach the share handler, so the scan
          // does not consume the one-time share session.
          final open = await findOpenPorts(
              InternetAddress(_loopbackHost), _samePhonePorts);
          if (open.isEmpty) {
            failure =
                "Couldn't find the original app's share screen — is it open?";
            forceManualPort = true;
          } else if (open.length > 1) {
            failure =
                "Found several open ports (${open.join(", ")}) — trying none "
                "of them, since every request consumes the one-time share "
                "session. Enter the port shown on the share screen manually:";
            forceManualPort = true;
          } else {
            port = open.single;
          }
        }
      } else {
        host = ipC.text.trim();
        final remotePort = int.tryParse(portC.text.trim());
        if (remotePort == null) {
          // Unreachable: validateLoadForm already accepted this input.
          failure = "Port must be a number (e.g. 10042).";
        } else {
          port = remotePort;
        }
      }
      if (failure == null) {
        var resp = await http.get(
            Uri(scheme: "http", host: host, port: port),
            headers: {
              "X-Schema": schema.toString(),
              "X-Password": pwdC.text,
            });
        if (resp.statusCode == 200) {
          var data = json.decode(resp.body);
          if (source == LoadSource.forkRemote) {
            // Same schema: straight replace with current-schema rows.
            await appDB.replaceDB(
                (data["series"] as List<dynamic>)
                    .map((s) => Series.fromJson(s as Map<String, dynamic>))
                    .toList(),
                (data["chapters"] as List<dynamic>)
                    .map((c) => Chapter.fromJson(c as Map<String, dynamic>))
                    .toList(),
                (data["chapterImages"] as List<dynamic>)
                    .map((i) => ChapterImage.fromJson(i as Map<String, dynamic>))
                    .toList());
          } else {
            // Replay the announced upstream schema against the real
            // migration chain, then replace the live library with the result.
            await appDB.importLegacyLibrary(data as Map<String, dynamic>,
                sourceSchema: schema);
            await _resetCycle();
          }
        } else {
          var body = resp.body.trim();
          if (source.isOriginal && resp.statusCode == 406) {
            mismatch406 = true;
          } else {
            failure = "Server answered ${resp.statusCode}"
                "${body.isEmpty ? "" : ": $body"}.\n"
                "The Share session on the source app answers only ONE request, even "
                "a rejected one — start sharing again there before retrying.";
          }
        }
      }
    } catch (e) {
      failure = "$e";
    }
    if (!mounted) {
      return;
    }
    if (mismatch406) {
      // The rejected request consumed the share session; remember the next
      // candidate format (persisted, survives leaving the page) and tell the
      // user exactly what to do.
      if (explicitSchema != null) {
        // A pinned format stays pinned — the user picks the next one.
        setState(() {
          error = schemaMismatchManualMessage(explicitSchema!);
          loading = null;
        });
        return;
      }
      var nextIndex = (cycleIndex + 1) % kOriginalSchemaCandidates.length;
      await _saveCycle(nextIndex);
      if (!mounted) {
        return;
      }
      setState(() {
        error = schemaMismatchCycleMessage(
            nextSchema: kOriginalSchemaCandidates[nextIndex],
            nextAttempt: nextIndex + 1,
            totalAttempts: kOriginalSchemaCandidates.length);
        loading = null;
      });
      return;
    }
    if (failure != null) {
      // Stay on the page so the error and the source-app picker are visible.
      setState(() {
        error = failure;
        loading = null;
        if (forceManualPort) {
          showManualPort = true;
        }
      });
    } else {
      router.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Text("Source app:"),
                    SizedBox(width: 12),
                    DropdownButton<LoadSource>(
                      value: source,
                      onChanged: loading == null
                          ? (v) => setState(
                              () => source = v ?? LoadSource.originalSamePhone)
                          : null,
                      items: [
                        DropdownMenuItem(
                            value: LoadSource.originalSamePhone,
                            child:
                                Text("Original StoryReader on this phone")),
                        DropdownMenuItem(
                            value: LoadSource.originalRemote,
                            child:
                                Text("Original StoryReader on another device")),
                        DropdownMenuItem(
                            value: LoadSource.forkRemote,
                            child: Text("StoryReader+ on another device")),
                      ],
                    ),
                  ],
                ),
              ),
              if (source.isOriginal) ...[
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Text("Advanced: library format:"),
                      SizedBox(width: 12),
                      DropdownButton<int?>(
                        value: explicitSchema,
                        onChanged: loading == null
                            ? (v) => setState(() => explicitSchema = v)
                            : null,
                        items: [
                          DropdownMenuItem(
                              value: null,
                              child: Text(
                                  "Auto (cycle ${kOriginalSchemaCandidates.join(", ")})")),
                          for (var s = 2; s <= 10; s++)
                            DropdownMenuItem(value: s, child: Text("$s")),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                      explicitSchema != null
                          ? "Announcing library format $explicitSchema."
                          : "Announcing library format ${kOriginalSchemaCandidates[cycleIndex]} "
                              "(attempt ${cycleIndex + 1} of ${kOriginalSchemaCandidates.length}).",
                      softWrap: true),
                ),
              ],
              if (source.isSamePhone) ...[
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                      "Open the original StoryReader \u2192 share library, note "
                      "the password, come back here and enter it. Keep the "
                      "share screen open (split-screen works best).",
                      softWrap: true),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: loading == null
                          ? () => setState(
                              () => showManualPort = !showManualPort)
                          : null,
                      child: Text(showManualPort
                          ? "Hide port field"
                          : "Enter port manually"),
                    ),
                  ),
                ),
                if (showManualPort)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TextField(
                      controller: portC,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(label: Text("Port")),
                    ),
                  ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: ipC,
                    decoration: InputDecoration(label: Text("IP")),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: portC,
                    decoration: InputDecoration(label: Text("Port")),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: TextField(
                  controller: pwdC,
                  obscureText: true,
                  decoration: InputDecoration(label: Text("Password")),
                ),
              ),
              if (loading == null)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ElevatedButton(
                      onPressed: () {
                        if (loading == null) {
                          setState(() {
                            error = null;
                            loading = _load();
                          });
                        }
                      },
                      child: Text("Load")),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(error!, softWrap: true),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
