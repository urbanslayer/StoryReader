import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:story_reader/db.dart';
import 'package:story_reader/main.dart';

/// Which app the exporting (sharing) device runs. The sender validates the
/// `X-Schema` header against its own `schemaVersion`, so the receiver must
/// announce the sender's version — not its own — when importing from the
/// original upstream app (schema v10). The sender allows exactly ONE request
/// per sharing session (a rejected one consumes it too), so there is no
/// automatic retry: the version is chosen up front.
enum SourceApp {
  /// Upstream StoryReader (F-Droid), DB schema v10.
  original,

  /// StoryReader+, this fork.
  fork;

  int get schemaVersion => switch (this) {
        SourceApp.original => 10,
        SourceApp.fork => appDB.schemaVersion,
      };
}

class LoadNetworkPage extends StatefulWidget {
  const LoadNetworkPage({super.key});

  @override
  State<LoadNetworkPage> createState() => _LoadNetworkPageState();
}

class _LoadNetworkPageState extends State<LoadNetworkPage> {
  TextEditingController ipC = TextEditingController();
  TextEditingController portC = TextEditingController();
  TextEditingController pwdC = TextEditingController();

  /// Defaults to the original app: this page exists mostly to migrate an
  /// existing upstream install into the fork.
  SourceApp source = SourceApp.original;

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
    try {
      var resp = await http
          .get(Uri(scheme: "http", host: ipC.text, port: int.parse(portC.text)), headers: {
        "X-Schema": source.schemaVersion.toString(),
        "X-Password": pwdC.text,
      });
      if (resp.statusCode == 200) {
        var data = json.decode(resp.body);
        if (source == SourceApp.fork) {
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
                    DropdownButton<SourceApp>(
                      value: source,
                      onChanged: loading == null
                          ? (v) => setState(() => source = v ?? SourceApp.original)
                          : null,
                      items: [
                        DropdownMenuItem(
                            value: SourceApp.original, child: Text("Original StoryReader")),
                        DropdownMenuItem(
                            value: SourceApp.fork, child: Text("StoryReader+ (this fork)")),
                      ],
                    ),
                  ],
                ),
              ),
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
