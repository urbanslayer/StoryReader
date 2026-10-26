import 'dart:async';
import 'dart:io';

/// TCP-connect probe used to auto-discover the original app's share server on
/// the same phone (it binds `0.0.0.0` on a random port in 10000..10199).
///
/// For every port we open a socket and immediately `destroy()` it **without
/// writing a single byte**: the share handler marks its one-time session as
/// used on the first *HTTP request*, and a bare TCP connect never reaches the
/// handler, so probing is side-effect free.
///
/// Ports are probed in parallel [batchSize] groups; each connect gets its own
/// [timeout]. Returns the open ports in ascending order.
Future<List<int>> findOpenPorts(
  InternetAddress host,
  Iterable<int> ports, {
  Duration timeout = const Duration(milliseconds: 150),
  int batchSize = 20,
}) async {
  final portList = ports.toList()..sort();
  final open = <int>[];
  for (var i = 0; i < portList.length; i += batchSize) {
    final batch = portList.sublist(i, (i + batchSize).clamp(0, portList.length));
    final results = await Future.wait(batch.map((port) async {
      Socket? socket;
      try {
        socket = await Socket.connect(host, port, timeout: timeout);
        return port;
      } catch (_) {
        // Connection refused / timed out / host unreachable: not open.
        return null;
      } finally {
        socket?.destroy();
      }
    }));
    open.addAll(results.whereType<int>());
  }
  return open;
}
