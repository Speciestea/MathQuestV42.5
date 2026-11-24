import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/services/offline_progress_store.dart';
import 'package:flutter_mathquest/services/offline_story_progress_service.dart';
import 'package:flutter_mathquest/services/user_progress_service.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late String databasePath;
  late OfflineProgressStore store;
  late OfflineStoryProgressService service;
  var now = DateTime.utc(2026, 11, 4);

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('mathquest-story-outbox-');
    databasePath = '${directory.path}${Platform.pathSeparator}events.db';
    store = OfflineProgressStore(
      databaseName: 'story-events',
      openDatabase: (_) => databaseFactoryIo.openDatabase(databasePath),
      clock: () => now,
    );
    service = OfflineStoryProgressService(
      store: store,
      isAuthorized: (uid) async => uid == 'student-a',
      clock: () => now,
    );
  });

  tearDown(() async {
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('offline recording requires the matching student authorization', () {
    expect(
      service.record(
        uid: 'student-b',
        eventId: 'answer-1',
        eventType: 'story.answer',
        payload: const {'level': 1},
      ),
      throwsStateError,
    );
  });

  test('offline progress overlay preserves Super Account Game Mode access',
      () async {
    UserProgressService.offlineStoryProgressServiceForTesting = service;
    final officialProgress = UserProgress(
      completedLevels: const [],
      completedNpcQuestions: const [],
      unlockedLevels: 3,
      questAttempts: 0,
      isSuperAccount: true,
      maxUnlockedSubLevel: const {1: 20, 2: 20, 3: 20},
    );

    final visibleProgress =
        await UserProgressService.applyPendingOfflineStoryProgress(
      officialProgress,
      uid: 'student-a',
    );

    expect(visibleProgress.isSuperAccount, isTrue);
    for (var level = 1; level <= 60; level++) {
      expect(
        visibleProgress.isGameModeLevelAvailable(
          level,
          includeProvisional: true,
        ),
        isTrue,
        reason: 'Game Mode level $level should remain accessible',
      );
    }
    expect(
      visibleProgress.nextRequiredGameModeLevelForTopic(60),
      isNull,
    );
  });

  test('records durable sequenced events and preserves dependency ordering',
      () async {
    await service.record(
      uid: 'student-a',
      eventId: 'answer-1',
      eventType: 'story.answer',
      payload: const {'level': 1, 'selectedAnswer': 8},
    );
    now = now.add(const Duration(seconds: 1));
    await service.record(
      uid: 'student-a',
      eventId: 'completion-1',
      eventType: 'story.completion',
      payload: const {'level': 1, 'provisionalPoints': 10},
      dependsOnEventId: 'answer-1',
    );

    await store.close();
    store = OfflineProgressStore(
      databaseName: 'story-events',
      openDatabase: (_) => databaseFactoryIo.openDatabase(databasePath),
      clock: () => now,
    );
    service = OfflineStoryProgressService(
      store: store,
      isAuthorized: (uid) async => uid == 'student-a',
      clock: () => now,
    );

    final pending = await service.getPendingEvents('student-a');
    expect(pending.map((event) => event.eventId), ['answer-1', 'completion-1']);
    expect(pending.map((event) => event.payload['eventSequence']), [1, 2]);
    expect(pending.last.payload['dependsOnEventId'], 'answer-1');
    expect(pending.last.payload['uid'], 'student-a');
  });

  test('same event retry is idempotent and changed content is rejected',
      () async {
    await service.record(
      uid: 'student-a',
      eventId: 'answer-1',
      eventType: 'story.answer',
      payload: const {'level': 1, 'selectedAnswer': 8},
    );
    now = now.add(const Duration(seconds: 3));

    final repeated = await service.record(
      uid: 'student-a',
      eventId: 'answer-1',
      eventType: 'story.answer',
      payload: const {'level': 1, 'selectedAnswer': 8},
    );
    expect(repeated.payload['eventSequence'], 1);
    expect(await store.pendingEventCount('student-a'), 1);

    await expectLater(
      service.record(
        uid: 'student-a',
        eventId: 'answer-1',
        eventType: 'story.answer',
        payload: const {'level': 1, 'selectedAnswer': 9},
      ),
      throwsA(isA<OfflineProgressStoreException>()),
    );
  });

  test('event sequence remains monotonic after an acknowledged event',
      () async {
    final first = await service.record(
      uid: 'student-a',
      eventId: 'event-1',
      eventType: 'story.answer',
      payload: const {'level': 1},
    );
    await service.acknowledgeAfterServerConfirmation(
      'student-a',
      first.eventId,
      serverConfirmationId: 'confirmed-event-1',
    );

    final next = await service.record(
      uid: 'student-a',
      eventId: 'event-2',
      eventType: 'story.answer',
      payload: const {'level': 2},
    );

    expect(next.payload['eventSequence'], 2);
  });

  test('retrieves only pending events for the requested authorized UID',
      () async {
    await service.record(
      uid: 'student-a',
      eventId: 'answer-a',
      eventType: 'story.answer',
      payload: const {'level': 1},
    );
    await expectLater(
      service.getPendingEvents('student-b'),
      throwsStateError,
    );
    expect(
      (await store.getPendingEvents('student-a'))
          .map((event) => event.ownerUid),
      everyElement('student-a'),
    );
  });

  test('Story completion stays provisional and unlocks only local progression',
      () async {
    UserProgressService.offlineStoryProgressServiceForTesting = service;
    for (var questionNumber = 1; questionNumber <= 6; questionNumber++) {
      await service.record(
        uid: 'student-a',
        eventId: 'npc-$questionNumber',
        eventType: 'story.npc.completed',
        payload: {
          'moduleId': 'fraction-add-subtract',
          'level': 1,
          'questionNumber': questionNumber,
        },
        dependsOnEventId:
            questionNumber == 1 ? null : 'npc-${questionNumber - 1}',
      );
    }
    await service.record(
      uid: 'student-a',
      eventId: 'game-mode-completed-1',
      eventType: 'story.game-mode.completed',
      payload: const {
        'moduleId': 'fraction-add-subtract',
        'level': 1,
        'score': 60,
        'provisionalPoints': 60,
      },
      dependsOnEventId: 'npc-6',
    );

    final officialProgress = UserProgress(
      completedLevels: const [],
      completedNpcQuestions: const [],
      unlockedLevels: 1,
      questAttempts: 0,
      maxUnlockedSubLevel: const {1: 1, 2: 1, 3: 1},
    );
    final visibleProgress =
        await UserProgressService.applyPendingOfflineStoryProgress(
      officialProgress,
      uid: 'student-a',
    );

    expect(visibleProgress.completedLevels, isEmpty);
    expect(visibleProgress.gameModeFinalScores, isEmpty);
    expect(visibleProgress.provisionalCompletedLevels, [1]);
    expect(visibleProgress.provisionalGameModeFinalScores[1], 60);
    expect(visibleProgress.isStoryLevelUnlocked(2), isFalse);
    expect(
      visibleProgress.isStoryLevelUnlocked(2, includeProvisional: true),
      isTrue,
    );
    expect(visibleProgress.unlockedLevels, 1);
    expect(visibleProgress.provisionalUnlockedLevels, 1);
    expect(
      visibleProgress.isGameModeLevelAvailable(1, includeProvisional: true),
      isTrue,
    );
    expect(
      visibleProgress.isGameModeLevelAvailable(2, includeProvisional: true),
      isTrue,
    );
    expect(
      visibleProgress.isGameModeLevelAvailable(3, includeProvisional: true),
      isFalse,
    );
  });
}
