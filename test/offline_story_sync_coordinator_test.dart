import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/models/offline_progress_event.dart';
import 'package:flutter_mathquest/services/offline_story_sync_coordinator.dart';

OfflineProgressEvent _event(
  String id,
  int sequence, {
  String? dependency,
  String ownerUid = 'student-a',
}) =>
    OfflineProgressEvent(
      eventId: id,
      ownerUid: ownerUid,
      eventType: 'story.answer',
      payload: {
        'uid': ownerUid,
        'eventSequence': sequence,
        if (dependency != null) 'dependsOnEventId': dependency,
      },
      createdAt: DateTime.utc(2026, 11, 4).add(Duration(seconds: sequence)),
    );

OfflineProgressEvent _npcCompletionEvent(int questionNumber) =>
    OfflineProgressEvent(
      eventId: 'npc-$questionNumber',
      ownerUid: 'student-a',
      eventType: 'story.npc.completed',
      payload: {
        'uid': 'student-a',
        'moduleId': 'fraction-add-subtract',
        'level': 1,
        'questionNumber': questionNumber,
        'eventSequence': questionNumber,
        if (questionNumber > 1) 'dependsOnEventId': 'npc-${questionNumber - 1}',
      },
      createdAt: DateTime.utc(2026, 11, 4, 0, 0, questionNumber),
    );

void main() {
  test('does not upload or acknowledge without a trusted validator', () async {
    final pending = [_event('event-1', 1)];
    var acknowledgeCount = 0;
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async => const VerifiedOfflineStorySession(
        uid: 'student-a',
        sessionKey: 'student-a:device:session',
      ),
      isSessionStillCurrent: (_) async => true,
      loadPendingEvents: (_) async => pending,
      loadEvent: (_, __) async => null,
      acknowledgeEvent: (_, __, {required serverConfirmationId}) async {
        acknowledgeCount++;
      },
    );

    final result = await coordinator.synchronizePendingEvents();

    expect(result.status, OfflineStorySyncStatus.trustedValidatorUnavailable);
    expect(result.pendingCount, 1);
    expect(acknowledgeCount, 0);
    await coordinator.dispose();
  });

  test('submits events in sequence and acknowledges exact server confirmations',
      () async {
    final events = [
      _event('event-1', 1),
      _event('event-2', 2, dependency: 'event-1'),
    ];
    final savedEvents = {for (final event in events) event.eventId: event};
    final submitted = <String>[];
    final acknowledged = <String>[];
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async => const VerifiedOfflineStorySession(
        uid: 'student-a',
        sessionKey: 'student-a:device:session',
      ),
      isSessionStillCurrent: (_) async => true,
      loadPendingEvents: (_) async => events,
      loadEvent: (_, eventId) async => savedEvents[eventId],
      acknowledgeEvent: (_, eventId, {required serverConfirmationId}) async {
        acknowledged.add('$eventId:$serverConfirmationId');
        final event = savedEvents[eventId]!;
        savedEvents[eventId] = event.acknowledged(
          acknowledgedAt: DateTime.utc(2026, 11, 4),
          serverConfirmationId: serverConfirmationId,
        );
      },
      submitEvent: (_, event) async {
        submitted.add(event.eventId);
        return OfflineStorySyncConfirmation(
          eventId: event.eventId,
          serverConfirmationId: 'server-${event.eventId}',
        );
      },
    );

    final result = await coordinator.synchronizePendingEvents();

    expect(result.status, OfflineStorySyncStatus.synchronized);
    expect(result.processedCount, 2);
    expect(submitted, ['event-1', 'event-2']);
    expect(
      acknowledged,
      ['event-1:server-event-1', 'event-2:server-event-2'],
    );
    await coordinator.dispose();
  });

  test('refuses mismatched confirmation without acknowledging the event',
      () async {
    final event = _event('event-1', 1);
    var acknowledgeCount = 0;
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async => const VerifiedOfflineStorySession(
        uid: 'student-a',
        sessionKey: 'student-a:device:session',
      ),
      isSessionStillCurrent: (_) async => true,
      loadPendingEvents: (_) async => [event],
      loadEvent: (_, __) async => null,
      acknowledgeEvent: (_, __, {required serverConfirmationId}) async {
        acknowledgeCount++;
      },
      submitEvent: (_, __) async => const OfflineStorySyncConfirmation(
        eventId: 'different-event',
        serverConfirmationId: 'server-confirmation',
      ),
    );

    final result = await coordinator.synchronizePendingEvents();

    expect(result.status, OfflineStorySyncStatus.serverDidNotConfirm);
    expect(acknowledgeCount, 0);
    await coordinator.dispose();
  });

  test('acknowledges a completion and its six confirmed NPC dependencies',
      () async {
    final npcEvents =
        List.generate(6, (index) => _npcCompletionEvent(index + 1));
    final completion = OfflineProgressEvent(
      eventId: 'completion-1',
      ownerUid: 'student-a',
      eventType: 'story.game-mode.completed',
      payload: {
        'uid': 'student-a',
        'moduleId': 'fraction-add-subtract',
        'level': 1,
        'score': 65,
        'eventSequence': 7,
        'dependsOnEventId': 'npc-6',
      },
      createdAt: DateTime.utc(2026, 11, 4, 0, 0, 7),
    );
    final savedEvents = {
      for (final event in [...npcEvents, completion]) event.eventId: event,
    };
    final acknowledged = <String>[];
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async => const VerifiedOfflineStorySession(
        uid: 'student-a',
        sessionKey: 'student-a:device:session',
      ),
      isSessionStillCurrent: (_) async => true,
      loadPendingEvents: (_) async => [completion],
      loadEvent: (_, eventId) async => savedEvents[eventId],
      acknowledgeEvent: (_, eventId, {required serverConfirmationId}) async {
        acknowledged.add(eventId);
      },
      submitEvent: (_, event) async => OfflineStorySyncConfirmation(
        eventId: event.eventId,
        serverConfirmationId: 'server-confirmation',
        confirmedEventIds:
            npcEvents.map((npcEvent) => npcEvent.eventId).toList(),
      ),
    );

    final result = await coordinator.synchronizePendingEvents();

    expect(result.status, OfflineStorySyncStatus.synchronized);
    expect(result.processedCount, 1);
    expect(acknowledged.toSet(), {
      'completion-1',
      for (final event in npcEvents) event.eventId,
    });
    await coordinator.dispose();
  });

  test('does not acknowledge after the verified session changes', () async {
    var sessionChecks = 0;
    var acknowledgeCount = 0;
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async => const VerifiedOfflineStorySession(
        uid: 'student-a',
        sessionKey: 'student-a:device:session',
      ),
      isSessionStillCurrent: (_) async => ++sessionChecks < 3,
      loadPendingEvents: (_) async => [_event('event-1', 1)],
      loadEvent: (_, __) async => null,
      acknowledgeEvent: (_, __, {required serverConfirmationId}) async {
        acknowledgeCount++;
      },
      submitEvent: (_, event) async => OfflineStorySyncConfirmation(
        eventId: event.eventId,
        serverConfirmationId: 'server-confirmation',
      ),
    );

    final result = await coordinator.synchronizePendingEvents();

    expect(result.status, OfflineStorySyncStatus.unauthorized);
    expect(acknowledgeCount, 0);
    await coordinator.dispose();
  });

  test('reconnection event starts one safe sync attempt without polling',
      () async {
    final connectivityChanges =
        StreamController<List<ConnectivityResult>>.broadcast(sync: true);
    var verificationCount = 0;
    final coordinator = OfflineStorySyncCoordinator(
      revalidateSession: () async {
        verificationCount++;
        return const VerifiedOfflineStorySession(
          uid: 'student-a',
          sessionKey: 'student-a:device:session',
        );
      },
      isSessionStillCurrent: (_) async => true,
      loadPendingEvents: (_) async => const [],
      loadEvent: (_, __) async => null,
      acknowledgeEvent: (_, __, {required serverConfirmationId}) async {},
      connectivityChanges: () => connectivityChanges.stream,
      checkConnectivity: () async => [ConnectivityResult.none],
    );
    coordinator.start();
    connectivityChanges.add([ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    expect(verificationCount, 0);

    connectivityChanges.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);

    expect(verificationCount, 1);
    await coordinator.dispose();
    await connectivityChanges.close();
  });
}
