import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/models/offline_progress_event.dart';
import 'package:flutter_mathquest/services/offline_progress_store.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

OfflineProgressEvent _event({
  String eventId = 'event-1',
  String ownerUid = 'student-a',
  String answer = '42',
  DateTime? createdAt,
}) =>
    OfflineProgressEvent(
      eventId: eventId,
      ownerUid: ownerUid,
      eventType: 'quiz.answer',
      payload: {'answer': answer, 'correct': true},
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
    );

OfflineProgressStore _createStore(String databasePath) => OfflineProgressStore(
      databaseName: 'test-events',
      openDatabase: (_) => databaseFactoryIo.openDatabase(databasePath),
      clock: () => DateTime.utc(2026, 1, 2),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late String databasePath;
  late OfflineProgressStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mathquest-outbox-');
    databasePath = '${directory.path}${Platform.pathSeparator}events.db';
    store = _createStore(databasePath);
  });

  tearDown(() async {
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('OfflineProgressEvent', () {
    test('rejects invalid IDs, UIDs, schema versions, and payloads', () {
      expect(
        () => _event(eventId: '../unsafe'),
        throwsArgumentError,
      );
      expect(
        () => _event(ownerUid: ' '),
        throwsArgumentError,
      );
      expect(
        () => OfflineProgressEvent(
          eventId: 'event-1',
          ownerUid: 'student-a',
          eventType: 'quiz.answer',
          payload: const {},
          createdAt: DateTime.utc(2026),
          schemaVersion: 99,
        ),
        throwsArgumentError,
      );
      expect(
        () => OfflineProgressEvent(
          eventId: 'event-1',
          ownerUid: 'student-a',
          eventType: 'quiz.answer',
          payload: const {
            'nested': {'refresh_token': 'not-allowed'}
          },
          createdAt: DateTime.utc(2026),
        ),
        throwsArgumentError,
      );
      expect(
        () => OfflineProgressEvent(
          eventId: 'event-1',
          ownerUid: 'student-a',
          eventType: 'quiz.answer',
          payload: const {'unsupported': Object()},
          createdAt: DateTime.utc(2026),
        ),
        throwsArgumentError,
      );
    });

    test('payload is immutable and only JSON-compatible', () {
      final source = <String, Object?>{'answer': '42'};
      final event = OfflineProgressEvent(
        eventId: 'event-1',
        ownerUid: 'student-a',
        eventType: 'quiz.answer',
        payload: source,
        createdAt: DateTime.utc(2026),
      );
      source['answer'] = 'changed';

      expect(event.payload['answer'], '42');
      expect(
        () => event.payload['answer'] = 'changed',
        throwsUnsupportedError,
      );
    });
  });

  group('OfflineProgressStore', () {
    test('inserts atomically and returns pending events in deterministic order',
        () async {
      await Future.wait([
        store.insert(
          'student-a',
          _event(eventId: 'later', createdAt: DateTime.utc(2026, 1, 2)),
        ),
        store.insert(
          'student-a',
          _event(eventId: 'first', createdAt: DateTime.utc(2026, 1, 1)),
        ),
        store.insert(
          'student-a',
          _event(eventId: 'same-time-b', createdAt: DateTime.utc(2026, 1, 1)),
        ),
      ]);

      expect(
        (await store.getPendingEvents('student-a'))
            .map((event) => event.eventId)
            .toList(),
        ['first', 'same-time-b', 'later'],
      );
      expect(await store.pendingEventCount('student-a'), 3);
    });

    test(
        'identical duplicate IDs are idempotent and changed content is rejected',
        () async {
      final event = _event();
      await Future.wait([
        store.insert('student-a', event),
        store.insert('student-a', event),
      ]);

      expect(await store.pendingEventCount('student-a'), 1);
      await expectLater(
        store.insert('student-a', _event(answer: 'different')),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'event-id-conflict'),
        ),
      );
      expect((await store.getEvent('student-a', 'event-1'))!.payload['answer'],
          '42');
    });

    test('does not expose events across UIDs', () async {
      await store.insert('student-a', _event(ownerUid: 'student-a'));
      await store.insert(
        'student-b',
        _event(eventId: 'event-2', ownerUid: 'student-b'),
      );

      expect(await store.pendingEventCount('student-a'), 1);
      expect(await store.pendingEventCount('student-b'), 1);
      expect(
          await store.getPendingEvents('student-b'),
          everyElement(isA<OfflineProgressEvent>().having(
            (event) => event.ownerUid,
            'ownerUid',
            'student-b',
          )));
      expect(await store.getEvent('student-b', 'event-1'), isNull);
      await expectLater(
        store.insert('student-b', _event(ownerUid: 'student-a')),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'uid-mismatch'),
        ),
      );
    });

    test('retrieval is retry-safe until explicit server confirmation',
        () async {
      await store.insert('student-a', _event());
      expect((await store.getPendingEvents('student-a')).length, 1);
      expect((await store.getPendingEvents('student-a')).length, 1);

      await expectLater(
        store.acknowledgeAfterServerConfirmation(
          'student-a',
          'event-1',
          serverConfirmationId: ' ',
        ),
        throwsArgumentError,
      );
      expect(await store.pendingEventCount('student-a'), 1);

      await store.acknowledgeAfterServerConfirmation(
        'student-a',
        'event-1',
        serverConfirmationId: 'server-event-1',
      );
      await store.acknowledgeAfterServerConfirmation(
        'student-a',
        'event-1',
        serverConfirmationId: 'server-event-1',
      );
      expect(await store.pendingEventCount('student-a'), 0);
      expect(
        (await store.getEvent('student-a', 'event-1'))!.syncStatus,
        OfflineProgressSyncStatus.acknowledged,
      );
      await expectLater(
        store.acknowledgeAfterServerConfirmation(
          'student-b',
          'event-1',
          serverConfirmationId: 'server-event-1',
        ),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'uid-mismatch'),
        ),
      );
    });

    test('pending events survive closing and reopening the database', () async {
      await store.insert('student-a', _event());
      await store.close();
      store = _createStore(databasePath);

      expect(
        (await store.getPendingEvents('student-a')).single.eventId,
        'event-1',
      );
    });

    test('corrupted records are reported and not silently discarded', () async {
      final database = await databaseFactoryIo.openDatabase(databasePath);
      await StoreRef<String, Object?>.main().record('corrupt-event').put(
        database,
        {
          'eventId': 'different-id',
          'ownerUid': 'student-a',
          'syncStatus': 'pending',
        },
      );
      await database.close();

      await expectLater(
        store.getPendingEvents('student-a'),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'corrupted-record'),
        ),
      );
    });

    test('unsupported database schemas are reported', () async {
      final database = await databaseFactoryIo.openDatabase(databasePath);
      await StoreRef<String, Object?>.main()
          .record('_offline_progress_schema')
          .put(database, {'schemaVersion': 99});
      await database.close();

      await expectLater(
        store.getPendingEvents('student-a'),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'unsupported-schema'),
        ),
      );
    });

    test('unavailable storage is reported without an in-memory fallback',
        () async {
      final unavailableStore = OfflineProgressStore(
        databaseName: 'unavailable',
        openDatabase: (_) => throw StateError('disk unavailable'),
      );
      addTearDown(unavailableStore.close);

      await expectLater(
        unavailableStore.insert('student-a', _event()),
        throwsA(
          isA<OfflineProgressStoreException>()
              .having((error) => error.code, 'code', 'storage-unavailable'),
        ),
      );
      await expectLater(
        unavailableStore.getPendingEvents('student-a'),
        throwsA(isA<OfflineProgressStoreException>()),
      );
    });
  });
}
