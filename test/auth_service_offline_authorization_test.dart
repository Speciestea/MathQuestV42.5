import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/services/auth_service.dart';

void main() {
  const uid = 'student-a';
  const deviceId = 'device-1234567890123456';
  const sessionId = 'session-a';
  const verifiedKey = '$uid:$deviceId:$sessionId';

  tearDown(() async {
    await AuthService.resetVerifiedSessionForTesting();
  });

  group('student offline authorization', () {
    test('only approved students receive student-only offline access', () {
      expect(
        AuthService.canEstablishStudentOfflineAuthorization(
          role: 'student',
          status: 'approved',
        ),
        isTrue,
      );
      for (final status in ['pending', 'rejected', 'disabled']) {
        expect(
          AuthService.canEstablishStudentOfflineAuthorization(
            role: 'student',
            status: status,
          ),
          isFalse,
          reason: '$status accounts must not receive offline authorization',
        );
      }
    });

    test('teacher and admin retain general cache but not student access', () {
      for (final role in ['teacher', 'admin']) {
        AuthService.rememberVerifiedSessionForTesting(
          uid: uid,
          role: role,
          status: 'approved',
          deviceId: deviceId,
          sessionId: sessionId,
        );

        expect(AuthService.verifiedSessionCacheKeyForTesting, verifiedKey);
        expect(
          AuthService.verifiedStudentOfflineSessionCacheKeyForTesting,
          isNull,
        );
        AuthService.invalidateCurrentVerifiedSession();
      }
    });

    test('binds authorization to UID, device, and session', () {
      expect(
        AuthService.verifiedSessionCacheKeyFor(
          uid: uid,
          deviceId: deviceId,
          sessionId: sessionId,
          verifiedCacheKey: verifiedKey,
        ),
        verifiedKey,
      );
      for (final mismatch in [
        (uid: 'student-b', deviceId: deviceId, sessionId: sessionId),
        (uid: uid, deviceId: 'device-abcdefghijklmnop', sessionId: sessionId),
        (uid: uid, deviceId: deviceId, sessionId: 'session-b'),
        (uid: uid, deviceId: 'short', sessionId: sessionId),
        (uid: uid, deviceId: deviceId, sessionId: ''),
      ]) {
        expect(
          AuthService.verifiedSessionCacheKeyFor(
            uid: mismatch.uid,
            deviceId: mismatch.deviceId,
            sessionId: mismatch.sessionId,
            verifiedCacheKey: verifiedKey,
          ),
          isNull,
        );
      }
    });

    test('temporary network failures preserve the verified grant', () {
      AuthService.rememberVerifiedSessionForTesting(
        uid: uid,
        role: 'student',
        status: 'approved',
        deviceId: deviceId,
        sessionId: sessionId,
      );

      for (final code in [
        'deadline-exceeded',
        'network-request-failed',
        'unavailable',
      ]) {
        expect(
          AuthService.preservesVerifiedSessionForFailureCode(code),
          isTrue,
        );
        expect(AuthService.verifiedSessionCacheKeyForTesting, verifiedKey);
      }
      expect(
        AuthService.preservesVerifiedSessionForFailureCode('permission-denied'),
        isFalse,
      );
    });
  });

  group('auth-state listener lifecycle', () {
    test('same-UID events and initial null before a grant preserve it',
        () async {
      final changes = StreamController<String?>.broadcast(sync: true);
      AuthService.listenForAuthStateChangesForTesting(changes.stream);
      changes.add(null);
      AuthService.rememberVerifiedSessionForTesting(
        uid: uid,
        role: 'student',
        status: 'approved',
        deviceId: deviceId,
        sessionId: sessionId,
      );

      changes.add(uid);
      expect(AuthService.verifiedSessionCacheKeyForTesting, verifiedKey);
      expect(
        AuthService.verifiedStudentOfflineSessionCacheKeyForTesting,
        verifiedKey,
      );
      await changes.close();
    });

    test('UID changes and null-UID events immediately invalidate the grant',
        () async {
      for (final changedUid in ['student-b', null]) {
        final changes = StreamController<String?>.broadcast(sync: true);
        AuthService.listenForAuthStateChangesForTesting(changes.stream);
        AuthService.rememberVerifiedSessionForTesting(
          uid: uid,
          role: 'student',
          status: 'approved',
          deviceId: deviceId,
          sessionId: sessionId,
        );

        changes.add(changedUid);
        expect(AuthService.verifiedSessionCacheKeyForTesting, isNull);
        expect(
          AuthService.verifiedStudentOfflineSessionCacheKeyForTesting,
          isNull,
        );
        await AuthService.resetVerifiedSessionForTesting();
        await changes.close();
      }
    });

    test('repeated setup creates only one stream subscription', () async {
      var listenCount = 0;
      final changes = StreamController<String?>.broadcast(
        sync: true,
        onListen: () => listenCount++,
      );
      AuthService.listenForAuthStateChangesForTesting(changes.stream);
      AuthService.listenForAuthStateChangesForTesting(changes.stream);

      expect(listenCount, 1);
      await AuthService.resetVerifiedSessionForTesting();
      await changes.close();
    });

    test('explicit invalidation clears both grants immediately', () {
      AuthService.rememberVerifiedSessionForTesting(
        uid: uid,
        role: 'student',
        status: 'approved',
        deviceId: deviceId,
        sessionId: sessionId,
      );

      AuthService.invalidateCurrentVerifiedSession();

      expect(AuthService.verifiedSessionCacheKeyForTesting, isNull);
      expect(
        AuthService.verifiedStudentOfflineSessionCacheKeyForTesting,
        isNull,
      );
    });
  });
}
