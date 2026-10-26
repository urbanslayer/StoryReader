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
