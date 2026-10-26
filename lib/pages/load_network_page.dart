import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:story_reader/db.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/network_form.dart';
import 'package:story_reader/port_scan.dart';

/// Where the exporting (sharing) app runs and which schema it speaks. The
/// sender validates the `X-Schema` header against its own `schemaVersion`, so
/// the receiver must announce the sender's version — not its own — when
/// importing from the original upstream app (schema v10). The sender allows
/// exactly ONE request per sharing session (a rejected one consumes it too),
/// so there is no automatic retry: the version is chosen up front.
enum LoadSource {
  /// Upstream StoryReader on the SAME phone: it binds 0.0.0.0 on a random
  /// port in 10000..10199, so the fork reaches it on 127.0.0.1 and
  /// auto-discovers the port — only the password has to be typed.
  originalSamePhone,

  /// Upstream StoryReader (F-Droid) on another device, DB schema v10.
  originalRemote,

  /// StoryReader+, this fork, on another device.
  forkRemote;

  int get schemaVersion => switch (this) {
        LoadSource.originalSamePhone || LoadSource.originalRemote => 10,
        LoadSource.forkRemote => appDB.schemaVersion,
      };

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

  Future? loading;
  String? error;

  @override
  void dispose() {
    super.dispose();
    ipC.dispose();
    portC.dispose();
    pwdC.dispose();
  }

  Future<void> _load() async {
    String? failure;
    bool forceManualPort = false;
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
              "X-Schema": source.schemaVersion.toString(),
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
            await appDB.importLegacyV10Library(data as Map<String, dynamic>);
          }
        } else {
          var body = resp.body.trim();
          failure = "Server answered ${resp.statusCode}"
              "${body.isEmpty ? "" : ": $body"}.\n"
              "The Share session on the source app answers only ONE request, even "
              "a rejected one — start sharing again there before retrying.";
        }
      }
    } catch (e) {
      failure = "$e";
    }
    if (!mounted) {
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
