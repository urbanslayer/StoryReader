// Pure input validation for the network load page, kept out of the widget
// so it is trivially testable and runs BEFORE any network call: the share
// server consumes its one-time session even on a rejected request, so a
// malformed request (or a parse crash after one was sent) is a real user
// cost. Never use `int.parse` on user input; only `int.tryParse` here.

/// Validates the load-page inputs for the given mode.
///
/// * [samePhone]: the "Original StoryReader on this phone" mode.
/// * [manualPort]: same-phone mode with the manual port field visible
///   (otherwise the port is auto-discovered and not user input).
///
/// Returns user-facing error text, or `null` when the inputs are usable.
String? validateLoadForm({
  required bool samePhone,
  required bool manualPort,
  required String ip,
  required String port,
  required String password,
}) {
  if (password.trim().isEmpty) {
    return "Enter the one-time password shown on the share screen.";
  }
  if (samePhone && !manualPort) {
    // Port is auto-discovered on 127.0.0.1; nothing else to validate.
    return null;
  }
  if (!samePhone && ip.trim().isEmpty) {
    return "Enter the IP address of the device sharing its library.";
  }
  final text = port.trim();
  if (text.isEmpty) {
    return samePhone
        ? "Enter the port shown on the share screen, or hide this field to "
            "find it automatically."
        : "Enter the port shown on the share screen (e.g. 10042).";
  }
  final parsed = int.tryParse(text);
  if (parsed == null) {
    return "Port must be a number (e.g. 10042).";
  }
  if (parsed < 1 || parsed > 65535) {
    return "Port must be between 1 and 65535.";
  }
  return null;
}

// ---- library-format (X-Schema) cycle --------------------------------------
//
// The original app's share server only answers when the announced `X-Schema`
// equals its own `schemaVersion`, tells nothing beyond "406: Schema
// mismatch", and burns its one-shot share session on the rejected request.
// So for the original-app sources the fork announces one candidate format
// per sharing session and remembers, across page visits, which candidate to
// try next after every 406.

/// Candidate `X-Schema` values to announce to the original app, ordered by
/// likelihood: the only published releases are 0.9.1 (schema 4) and 0.9.0
/// (schema 2); F-Droid/main-branch builds range up to schema 10.
const List<int> kOriginalSchemaCandidates = [4, 2, 10, 9, 8, 7, 6, 5, 3];

/// Preferences key holding the index into [kOriginalSchemaCandidates] of the
/// next format to try (persisted so the cycle survives leaving the page; a
/// successful import resets it).
const String kSchemaCyclePrefKey = "load.originalSchemaCycleIndex";

/// User-facing guidance shown after a 406 in Auto mode: the old share
/// session is spent, and [nextSchema] (the [nextAttempt]-th of
/// [totalAttempts] attempts) is announced on the next Load press.
String schemaMismatchCycleMessage(
        {required int nextSchema, required int nextAttempt, required int totalAttempts}) =>
    "The original app uses a different library format. Open Share library "
    "again in the original app (the old session is used up), then press "
    "Load — trying format $nextSchema next "
    "(attempt $nextAttempt of $totalAttempts).";

/// Guidance shown after a 406 when the user pinned a format manually.
String schemaMismatchManualMessage(int rejectedSchema) =>
    "Format $rejectedSchema was rejected (406: Schema mismatch). Open Share "
    "library again in the original app (the old session is used up), then "
    "pick another format under \"Advanced: library format\" — or Auto to "
    "cycle through all formats.";
