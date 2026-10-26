// validateLoadForm must reject every malformed input BEFORE any network call
// (the share server burns its one-time session even on rejected requests)
// and must accept everything the page can legitimately submit.

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/network_form.dart';

void main() {
  group('remote modes', () {
    test('accepts a well-formed form', () {
      expect(
          validateLoadForm(
              samePhone: false,
              manualPort: false,
              ip: '192.168.1.20',
              port: '10042',
              password: 'ab12cd'),
          isNull);
      // Surrounding whitespace is tolerated.
      expect(
          validateLoadForm(
              samePhone: false,
              manualPort: false,
              ip: ' 10.0.0.5 ',
              port: ' 80 ',
              password: ' x '),
          isNull);
    });

    test('empty IP is an inline error, not a crash', () {
      final err = validateLoadForm(
          samePhone: false,
          manualPort: false,
          ip: '',
          port: '10042',
          password: 'abc');
      expect(err, isNotNull);
      expect(err!.toLowerCase(), contains('ip'));
    });

    test('empty port is the real-app crash regression: friendly error', () {
      final err = validateLoadForm(
          samePhone: false,
          manualPort: false,
          ip: '192.168.1.20',
          port: '',
          password: 'abc');
      expect(err, isNotNull);
      expect(err!.toLowerCase(), contains('port'));
    });

    test('non-numeric port', () {
      for (final bad in ['abc', '10o00', '10 000', '10.5', '-1x']) {
        final err = validateLoadForm(
            samePhone: false,
            manualPort: false,
            ip: '1.2.3.4',
            port: bad,
            password: 'abc');
        expect(err, isNotNull, reason: '"$bad" must be rejected');
        expect(err!.toLowerCase(), contains('number'));
      }
    });

    test('port range 1..65535 inclusive', () {
      for (final good in ['1', '65535']) {
        expect(
            validateLoadForm(
                samePhone: false,
                manualPort: false,
                ip: '1.2.3.4',
                port: good,
                password: 'abc'),
            isNull,
            reason: '"$good" must be accepted');
      }
      for (final bad in ['0', '65536', '99999']) {
        final err = validateLoadForm(
            samePhone: false,
            manualPort: false,
            ip: '1.2.3.4',
            port: bad,
            password: 'abc');
        expect(err, isNotNull, reason: '"$bad" must be rejected');
        expect(err!.contains('65535'), isTrue);
      }
    });
  });

  group('same-phone mode', () {
    test('only the password is required while auto-discovering', () {
      // Port/IP fields are hidden in this mode: they must not block loading.
      expect(
          validateLoadForm(
              samePhone: true,
              manualPort: false,
              ip: '',
              port: '',
              password: 'secret'),
          isNull);
    });

    test('empty password is always an inline error', () {
      for (final form in [
        // (samePhone, manualPort)
        (true, false),
        (true, true),
        (false, false),
      ]) {
        final err = validateLoadForm(
            samePhone: form.$1,
            manualPort: form.$2,
            ip: '1.2.3.4',
            port: '10000',
            password: '   ');
        expect(err, isNotNull, reason: 'empty password $form');
        expect(err!.toLowerCase(), contains('password'));
      }
    });

    test('manual port field is validated when visible', () {
      final empty = validateLoadForm(
          samePhone: true,
          manualPort: true,
          ip: '',
          port: '',
          password: 'abc');
      expect(empty, isNotNull);
      expect(empty!.toLowerCase(), contains('port'));

      final nan = validateLoadForm(
          samePhone: true,
          manualPort: true,
          ip: '',
          port: 'ten',
          password: 'abc');
      expect(nan, isNotNull);

      final oor = validateLoadForm(
          samePhone: true,
          manualPort: true,
          ip: '',
          port: '70000',
          password: 'abc');
      expect(oor, isNotNull);
      expect(oor!.contains('65535'), isTrue);

      expect(
          validateLoadForm(
              samePhone: true,
              manualPort: true,
              ip: '',
              port: '10042',
              password: 'abc'),
          isNull);
    });
  });
}
