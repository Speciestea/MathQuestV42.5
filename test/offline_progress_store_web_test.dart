@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/models/offline_progress_event.dart';
import 'package:flutter_mathquest/services/offline_progress_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('IndexedDB records survive reopening the web store', () async {
    final databaseName =
        'mathquest_offline_progress_test_${DateTime.now().microsecondsSinceEpoch}';
    var store = OfflineProgressStore(databaseName: databaseName);
    final event = OfflineProgressEvent(
      eventId: 'web-restart-event',
      ownerUid: 'web-student',
      eventType: 'quiz.answer',
      payload: const {'selectedAnswer': '42', 'correct': true},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    try {
      await store.insert('web-student', event);
      await store.close();
      store = OfflineProgressStore(databaseName: databaseName);

      final restored = await store.getPendingEvents('web-student');
      expect(restored, hasLength(1));
      expect(restored.single.eventId, event.eventId);
      expect(restored.single.payload, event.payload);
    } finally {
      await store.close();
    }
  });
}
