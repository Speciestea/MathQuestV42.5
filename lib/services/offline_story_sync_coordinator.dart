import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/offline_progress_event.dart';

class VerifiedOfflineStorySession {
  const VerifiedOfflineStorySession({
    required this.uid,
    required this.sessionKey,
  });

  final String uid;
  final String sessionKey;
}

class OfflineStorySyncConfirmation {
  const OfflineStorySyncConfirmation({
    required this.eventId,
    required this.serverConfirmationId,
    this.confirmedEventIds = const [],
  });

  final String eventId;
  final String serverConfirmationId;
  final List<String> confirmedEventIds;
}

enum OfflineStorySyncStatus {
  alreadyRunning,
  noNetwork,
  unauthorized,
  noPendingEvents,
  trustedValidatorUnavailable,
  dependencyPending,
  invalidEvent,
  conflict,
  rejected,
  serverDidNotConfirm,
  synchronized,
  failed,
}

class OfflineStorySyncResult {
  const OfflineStorySyncResult(
    this.status, {
    this.processedCount = 0,
    this.pendingCount = 0,
  });

  final OfflineStorySyncStatus status;
  final int processedCount;
  final int pendingCount;
}

class OfflineStorySyncConflict implements Exception {
  const OfflineStorySyncConflict(this.message);

  final String message;

  @override
  String toString() => 'OfflineStorySyncConflict: $message';
}

typedef OfflineStorySessionRevalidator = Future<VerifiedOfflineStorySession?>
    Function();
typedef OfflineStorySessionStillCurrent = Future<bool> Function(
    VerifiedOfflineStorySession session);
typedef OfflineStoryPendingEventLoader = Future<List<OfflineProgressEvent>>
    Function(String uid);
typedef OfflineStoryEventLoader = Future<OfflineProgressEvent?> Function(
    String uid, String eventId);
typedef OfflineStoryEventAcknowledger = Future<void> Function(
  String uid,
  String eventId, {
  required String serverConfirmationId,
});
typedef OfflineStoryEventSubmitter = Future<OfflineStorySyncConfirmation?>
    Function(
  VerifiedOfflineStorySession session,
  OfflineProgressEvent event,
);

class OfflineStorySyncCoordinator {
  OfflineStorySyncCoordinator({
    required OfflineStorySessionRevalidator revalidateSession,
    required OfflineStorySessionStillCurrent isSessionStillCurrent,
    required OfflineStoryPendingEventLoader loadPendingEvents,
    required OfflineStoryEventLoader loadEvent,
    required OfflineStoryEventAcknowledger acknowledgeEvent,
    OfflineStoryEventSubmitter? submitEvent,
    Connectivity? connectivity,
    Stream<List<ConnectivityResult>> Function()? connectivityChanges,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
  })  : _revalidateSession = revalidateSession,
        _isSessionStillCurrent = isSessionStillCurrent,
        _loadPendingEvents = loadPendingEvents,
        _loadEvent = loadEvent,
        _acknowledgeEvent = acknowledgeEvent,
        _submitEvent = submitEvent,
        _connectivity = connectivity ?? Connectivity(),
        _connectivityChanges = connectivityChanges,
        _checkConnectivity = checkConnectivity;

  final OfflineStorySessionRevalidator _revalidateSession;
  final OfflineStorySessionStillCurrent _isSessionStillCurrent;
  final OfflineStoryPendingEventLoader _loadPendingEvents;
  final OfflineStoryEventLoader _loadEvent;
  final OfflineStoryEventAcknowledger _acknowledgeEvent;
  final OfflineStoryEventSubmitter? _submitEvent;
  final Connectivity _connectivity;
  final Stream<List<ConnectivityResult>> Function()? _connectivityChanges;
  final Future<List<ConnectivityResult>> Function()? _checkConnectivity;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _isSynchronizing = false;

  void start() {
    if (_subscription != null) return;
    final changes =
        _connectivityChanges?.call() ?? _connectivity.onConnectivityChanged;
    _subscription = changes.listen(
      (results) {
        if (_hasNetwork(results)) unawaited(_synchronizeFromConnectivity());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Offline Story connectivity monitoring failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
  }

  Future<OfflineStorySyncResult> onAppResumed() async {
    try {
      final results = await (_checkConnectivity?.call() ??
          _connectivity.checkConnectivity());
      if (!_hasNetwork(results)) {
        return const OfflineStorySyncResult(OfflineStorySyncStatus.noNetwork);
      }
      return synchronizePendingEvents();
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to check connectivity for offline Story sync: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const OfflineStorySyncResult(OfflineStorySyncStatus.failed);
    }
  }

  Future<OfflineStorySyncResult> _synchronizeFromConnectivity() async {
    return synchronizePendingEvents();
  }

  Future<OfflineStorySyncResult> synchronizePendingEvents() async {
    final result = await _synchronizePendingEvents();
    if (result.status == OfflineStorySyncStatus.trustedValidatorUnavailable) {
      debugPrint(
        'Offline Story events remain provisional: '
        'no trusted server validator is configured.',
      );
    }
    return result;
  }

  Future<OfflineStorySyncResult> _synchronizePendingEvents() async {
    if (_isSynchronizing) {
      return const OfflineStorySyncResult(
        OfflineStorySyncStatus.alreadyRunning,
      );
    }
    _isSynchronizing = true;
    try {
      final session = await _revalidateSession();
      if (session == null || !await _isSessionStillCurrent(session)) {
        return const OfflineStorySyncResult(
            OfflineStorySyncStatus.unauthorized);
      }

      final events = await _loadPendingEvents(session.uid);
      if (events.isEmpty) {
        return const OfflineStorySyncResult(
          OfflineStorySyncStatus.noPendingEvents,
        );
      }
      final submitEvent = _submitEvent;
      if (submitEvent == null) {
        return OfflineStorySyncResult(
          OfflineStorySyncStatus.trustedValidatorUnavailable,
          pendingCount: events.length,
        );
      }

      final confirmedThisRun = <String>{};
      var previousSequence = 0;
      for (final event in events) {
        final sequence = event.payload['eventSequence'];
        if (event.ownerUid != session.uid ||
            event.payload['uid'] != session.uid ||
            sequence is! int ||
            sequence <= previousSequence) {
          return OfflineStorySyncResult(
            OfflineStorySyncStatus.invalidEvent,
            processedCount: confirmedThisRun.length,
            pendingCount: events.length,
          );
        }
        previousSequence = sequence;

        final dependencyId = event.payload['dependsOnEventId'];
        if (dependencyId is String && dependencyId.isNotEmpty) {
          if (!confirmedThisRun.contains(dependencyId)) {
            final dependency = await _loadEvent(session.uid, dependencyId);
            final isCompletionBundleDependency =
                event.eventType == 'story.game-mode.completed' &&
                    dependency != null &&
                    dependency.ownerUid == session.uid &&
                    dependency.payload['uid'] == session.uid &&
                    dependency.eventType == 'story.npc.completed' &&
                    dependency.payload['level'] == event.payload['level'] &&
                    dependency.payload['questionNumber'] == 6;
            if (dependency?.syncStatus !=
                    OfflineProgressSyncStatus.acknowledged &&
                !isCompletionBundleDependency) {
              return OfflineStorySyncResult(
                OfflineStorySyncStatus.dependencyPending,
                processedCount: confirmedThisRun.length,
                pendingCount: events.length,
              );
            }
          }
        }

        if (!await _isSessionStillCurrent(session)) {
          return OfflineStorySyncResult(
            OfflineStorySyncStatus.unauthorized,
            processedCount: confirmedThisRun.length,
            pendingCount: events.length,
          );
        }
        final confirmation = await submitEvent(session, event);
        if (confirmation == null ||
            confirmation.eventId != event.eventId ||
            confirmation.serverConfirmationId.trim().isEmpty) {
          return OfflineStorySyncResult(
            OfflineStorySyncStatus.serverDidNotConfirm,
            processedCount: confirmedThisRun.length,
            pendingCount: events.length,
          );
        }
        final eventIdsToAcknowledge = {
          ...confirmation.confirmedEventIds,
          event.eventId,
        };
        final bundledEvents = <String, OfflineProgressEvent>{
          for (final pendingEvent in events) pendingEvent.eventId: pendingEvent,
        };
        for (final bundledEventId in confirmation.confirmedEventIds) {
          final bundledEvent = await _loadEvent(session.uid, bundledEventId);
          if (bundledEvent != null) {
            bundledEvents[bundledEventId] = bundledEvent;
          }
        }
        if (confirmation.confirmedEventIds.isNotEmpty &&
            !_hasValidNpcCompletionBundle(
              event,
              confirmation,
              bundledEvents.values.toList(growable: false),
            )) {
          return OfflineStorySyncResult(
            OfflineStorySyncStatus.invalidEvent,
            processedCount: confirmedThisRun.length,
            pendingCount: events.length,
          );
        }
        if (!await _isSessionStillCurrent(session)) {
          return OfflineStorySyncResult(
            OfflineStorySyncStatus.unauthorized,
            processedCount: confirmedThisRun.length,
            pendingCount: events.length,
          );
        }
        for (final eventId in eventIdsToAcknowledge) {
          if (eventId != event.eventId) {
            final bundledEvent = bundledEvents[eventId];
            if (bundledEvent == null ||
                bundledEvent.ownerUid != session.uid ||
                bundledEvent.payload['uid'] != session.uid ||
                bundledEvent.eventType != 'story.npc.completed') {
              return OfflineStorySyncResult(
                OfflineStorySyncStatus.invalidEvent,
                processedCount: confirmedThisRun.length,
                pendingCount: events.length,
              );
            }
          }
          if (!await _isSessionStillCurrent(session)) {
            return OfflineStorySyncResult(
              OfflineStorySyncStatus.unauthorized,
              processedCount: confirmedThisRun.length,
              pendingCount: events.length,
            );
          }
          await _acknowledgeEvent(
            session.uid,
            eventId,
            serverConfirmationId: confirmation.serverConfirmationId,
          );
        }
        confirmedThisRun.add(event.eventId);
      }

      return OfflineStorySyncResult(
        OfflineStorySyncStatus.synchronized,
        processedCount: confirmedThisRun.length,
      );
    } on OfflineStorySyncConflict catch (error, stackTrace) {
      debugPrint('Offline Story synchronization conflict: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const OfflineStorySyncResult(OfflineStorySyncStatus.conflict);
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Offline Story synchronization was rejected by Firestore: '
        'code=${error.code}, message=${error.message}.',
      );
      debugPrintStack(stackTrace: stackTrace);
      return OfflineStorySyncResult(
        error.code == 'permission-denied'
            ? OfflineStorySyncStatus.rejected
            : OfflineStorySyncStatus.failed,
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Offline Story synchronization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const OfflineStorySyncResult(OfflineStorySyncStatus.failed);
    } finally {
      _isSynchronizing = false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  static bool _hasValidNpcCompletionBundle(
    OfflineProgressEvent completion,
    OfflineStorySyncConfirmation confirmation,
    List<OfflineProgressEvent> pendingEvents,
  ) {
    if (completion.eventType != 'story.game-mode.completed' ||
        confirmation.confirmedEventIds.length != 6 ||
        confirmation.confirmedEventIds.toSet().length != 6) {
      return false;
    }

    final eventsById = {
      for (final event in pendingEvents) event.eventId: event,
    };
    final npcEvents = <int, OfflineProgressEvent>{};
    for (final eventId in confirmation.confirmedEventIds) {
      final npcEvent = eventsById[eventId];
      final questionNumber = npcEvent?.payload['questionNumber'];
      if (npcEvent == null ||
          npcEvent.ownerUid != completion.ownerUid ||
          npcEvent.eventType != 'story.npc.completed' ||
          npcEvent.payload['uid'] != completion.ownerUid ||
          npcEvent.payload['level'] != completion.payload['level'] ||
          npcEvent.payload['moduleId'] != completion.payload['moduleId'] ||
          questionNumber is! int ||
          questionNumber < 1 ||
          questionNumber > 6 ||
          npcEvents.containsKey(questionNumber)) {
        return false;
      }
      npcEvents[questionNumber] = npcEvent;
    }

    var previousSequence = 0;
    final completionSequence = completion.payload['eventSequence'];
    if (completionSequence is! int) return false;
    for (var questionNumber = 1; questionNumber <= 6; questionNumber++) {
      final npcEvent = npcEvents[questionNumber];
      if (npcEvent == null) return false;
      final sequence = npcEvent.payload['eventSequence'];
      if (sequence is! int ||
          sequence <= previousSequence ||
          sequence >= completionSequence) {
        return false;
      }
      previousSequence = sequence;
      final dependencyId = npcEvent.payload['dependsOnEventId'];
      if (questionNumber == 1) {
        if (dependencyId is String && dependencyId.isNotEmpty) return false;
      } else if (dependencyId != npcEvents[questionNumber - 1]?.eventId) {
        return false;
      }
    }

    return completion.payload['dependsOnEventId'] == npcEvents[6]?.eventId;
  }
}
