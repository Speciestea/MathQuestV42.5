import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/services/user_progress_service.dart';

UserProgress _progress(
  Set<int> completedLevels, {
  bool isSuperAccount = false,
}) =>
    UserProgress(
      completedLevels: completedLevels.toList(),
      completedNpcQuestions: const [],
      unlockedLevels: 1,
      questAttempts: 0,
      isSuperAccount: isSuperAccount,
      maxUnlockedSubLevel: const {},
    );

void main() {
  const sessionKey = 'student-a:device-1234567890123456:session-a';

  test('offline access requires the matching approved-student session', () {
    final access = UserProgressService.offlineWorksheetModuleAccess(
      sessionKey: sessionKey,
      studentOfflineSessionKey: null,
      cachedAccess: null,
    );

    expect(access.sessionVerified, isFalse);
    expect(access.canOpenModule(1), isFalse);
  });

  test('matching student session preserves cached unlocks only', () {
    final cached = WorksheetModuleAccess(
      sessionVerified: true,
      progress: _progress({8}),
      usingCachedProgress: true,
    );
    final access = UserProgressService.offlineWorksheetModuleAccess(
      sessionKey: sessionKey,
      studentOfflineSessionKey: sessionKey,
      cachedAccess: cached,
    );

    expect(access, same(cached));
    expect(access.canOpenModule(1), isTrue);
    expect(access.canOpenModule(2), isTrue);
    expect(access.canOpenModule(3), isFalse);
  });

  test('Super Account can access every worksheet module only on its profile',
      () {
    final superAccess = WorksheetModuleAccess(
      sessionVerified: true,
      progress: _progress({}, isSuperAccount: true),
      usingCachedProgress: false,
    );
    final regularAccess = WorksheetModuleAccess(
      sessionVerified: true,
      progress: _progress({}),
      usingCachedProgress: false,
    );

    for (var module = 1; module <= 8; module++) {
      expect(superAccess.canOpenModule(module), isTrue);
      expect(superAccess.progress!.isWorksheetModuleUnlocked(module), isTrue);
    }
    expect(regularAccess.canOpenModule(1), isTrue);
    for (var module = 2; module <= 8; module++) {
      expect(regularAccess.canOpenModule(module), isFalse);
    }
  });

  test(
      'matching student session permits only the always-unlocked first module '
      'when progress has not been cached', () {
    final access = UserProgressService.offlineWorksheetModuleAccess(
      sessionKey: sessionKey,
      studentOfflineSessionKey: sessionKey,
      cachedAccess: null,
    );

    expect(access.sessionVerified, isTrue);
    expect(access.canOpenModule(1), isTrue);
    expect(access.canOpenModule(2), isFalse);
  });

  test('a cache from another verified session is not reused offline', () {
    final cached = WorksheetModuleAccess(
      sessionVerified: true,
      progress: _progress({8, 15, 20, 25, 30, 35, 41, 42}),
      usingCachedProgress: true,
    );
    final access = UserProgressService.offlineWorksheetModuleAccess(
      sessionKey: sessionKey,
      studentOfflineSessionKey: 'student-b:other-device:other-session',
      cachedAccess: cached,
    );

    expect(access.sessionVerified, isFalse);
    for (var module = 1; module <= 8; module++) {
      expect(access.canOpenModule(module), isFalse);
    }
  });
}
