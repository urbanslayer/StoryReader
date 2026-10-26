// findOpenPorts against real ServerSockets bound on 127.0.0.1: it must find
// exactly the bound ports out of a mixed list, and the probe must be a pure
// TCP connect — the server side sees connections that send zero bytes before
// the client hangs up (the original app's share handler marks its one-time
// session used on the first HTTP request, so the scan may never write).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/port_scan.dart';

void main() {
  final loopback = InternetAddress('127.0.0.1');

  group('findOpenPorts', () {
    test('finds exactly the open ports out of a mixed list', () async {
      // Bind port 0 to get OS-assigned, definitely-open ephemeral ports.
      final servers = <ServerSocket>[];
      for (var i = 0; i < 3; i++) {
        servers.add(await ServerSocket.bind(loopback, 0));
      }
      addTearDown(() => Future.wait(servers.map((s) => s.close())));

      // Ports confirmed *closed*: ephemeral ports probed before their servers
      // are ever bound (nothing can connect to them in between).
      final closedProbes = <int>[];
      for (var i = 0; i < 4; i++) {
        final throwaway = await ServerSocket.bind(loopback, 0);
        final p = throwaway.port;
        await throwaway.close();
        // Reuse the port number but ensure nothing listens: a connect must fail.
        Object? connectError;
        try {
          final s = await Socket.connect(loopback, p,
              timeout: const Duration(milliseconds: 200));
          s.destroy();
        } catch (e) {
          connectError = e;
        }
        expect(connectError, isA<SocketException>(),
            reason: 'closed probe port $p must refuse');
        closedProbes.add(p);
      }

      final openPorts = servers.map((s) => s.port).toList()..sort();
      final scanList = [...openPorts, ...closedProbes]..sort();

      final found = await findOpenPorts(loopback, scanList);
      expect(found, openPorts);
    });

    test('probe sends zero bytes: servers see connects, no payload, then close',
        () async {
      final servers = <ServerSocket>[];
      final connects = <int, int>{}; // port -> accepted connections
      final byteLogs = <int, List<int>>{}; // port -> every byte ever received
      final doneCompleters = <int, Completer<void>>{};

      for (var i = 0; i < 2; i++) {
        final s = await ServerSocket.bind(loopback, 0);
        servers.add(s);
        connects[s.port] = 0;
        byteLogs[s.port] = [];
        s.listen((socket) {
          connects[s.port] = connects[s.port]! + 1;
          final done = Completer<void>();
          doneCompleters[s.port] = done;
          socket.listen(
            (bytes) => byteLogs[s.port]!.addAll(bytes),
            onDone: () => done.complete(),
            onError: (_) {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
        });
      }
      addTearDown(() => Future.wait(servers.map((s) => s.close())));

      final openPorts = servers.map((s) => s.port).toList()..sort();
      // One definitely-closed port alongside them.
      final throwaway = await ServerSocket.bind(loopback, 0);
      final closedPort = throwaway.port;
      await throwaway.close();

      final found =
          await findOpenPorts(loopback, [...openPorts, closedPort]);
      expect(found, openPorts);

      // Each open port got exactly one connection, which ended (client
      // destroyed the socket) without ever delivering a byte.
      for (final port in openPorts) {
        expect(connects[port], 1, reason: 'one probe connect on $port');
        await doneCompleters[port]!.future
            .timeout(const Duration(seconds: 2));
        expect(byteLogs[port], isEmpty,
            reason: 'probe must not write any bytes to $port');
      }
    });

    test('empty port list finds nothing and returns quickly', () async {
      expect(await findOpenPorts(loopback, const <int>[]), isEmpty);
    });

    test('closed ports are reported as not open', () async {
      final throwaway = await ServerSocket.bind(loopback, 0);
      final closed = throwaway.port;
      await throwaway.close();
      expect(await findOpenPorts(loopback, [closed]), isEmpty);
    });
  });
}
