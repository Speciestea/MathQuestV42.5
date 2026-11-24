import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../models/offline_progress_event.dart';
import 'auth_service.dart';
import 'offline_progress_store.dart';

typedef OfflineStoryAuthorizationCheck = Future<bool> Function(String uid);

class OfflineStoryProgressService {
  OfflineStoryProgressService({
    OfflineProgressStore? store,
    OfflineStoryAuthorizationCheck? isAuthorized,
    DateTime Function()? clock,
    Random? random,
  })  : _store = store ?? OfflineProgressStore(),
        _isAuthorized = isAuthorized ?? _hasCurrentAuthorization,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final OfflineProgressStore _store;
  final OfflineStoryAuthorizationCheck _isAuthorized;
  final DateTime Function() _clock;
  final Random _random;
  Future<void> _writeQueue = Future<void>.value();

  static Future<bool> _hasCurrentAuthorization(String uid) async =>
      AuthService.currentUser?.uid == uid &&
      await AuthService.currentVerifiedStudentOfflineSessionCacheKey() != null;

  String newEventId(String prefix) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,40}$').hasMatch(prefix)) {
      throw ArgumentError.value(prefix, 'prefix');
    }
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final suffix =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '$prefix-$suffix';
  }

  Future<OfflineProgressEvent> record({
    required String uid,
    required String eventId,
    required String eventType,
    required Map<String, Object?> payload,
    String? dependsOnEventId,
  }) async {
    if (!await _isAuthorized(uid)) {
      throw StateError(
        'A matching verified student session is required for offline Story progress.',
      );
    }

    return _serialize(() async {
      final existing = await _store.getEvent(uid, eventId);
      if (existing != null) {
        final existingPayload = Map<String, Object?>.from(existing.payload)
          ..remove('eventSequence');
        final expectedPayload = <String, Object?>{
          ...payload,
          'uid': uid,
          if (dependsOnEventId != null) 'dependsOnEventId': dependsOnEventId,
        };
        final samePayload =
            _canonicalJson(existingPayload) == _canonicalJson(expectedPayload);
        if (existing.eventType == eventType && samePayload) return existing;
        throw const OfflineProgressStoreException(
          'event-id-conflict',
          'A Story event ID cannot be reused with different content.',
        );
      }

      final events = await _store.getEvents(uid);
      final sequence = events.fold<int>(0, (maximum, event) {
            final value = event.payload['eventSequence'];
            return value is int && value > maximum ? value : maximum;
          }) +
          1;
      final eventPayload = <String, Object?>{
        ...payload,
        'uid': uid,
        'eventSequence': sequence,
        if (dependsOnEventId != null) 'dependsOnEventId': dependsOnEventId,
      };
      final event = OfflineProgressEvent(
        eventId: eventId,
        ownerUid: uid,
        eventType: eventType,
        payload: eventPayload,
        createdAt: _clock(),
      );
      await _store.insert(uid, event);
      return event;
    });
  }

  Future<List<OfflineProgressEvent>> getPendingEvents(String uid) async {
    if (!await _isAuthorized(uid)) {
      throw StateError(
        'A matching verified student session is required to read offline Story progress.',
      );
    }
    final events = (await _store.getPendingEvents(uid)).toList();
    events.sort((first, second) {
      final firstSequence = first.payload['eventSequence'];
      final secondSequence = second.payload['eventSequence'];
      if (firstSequence is int && secondSequence is int) {
        final sequenceOrder = firstSequence.compareTo(secondSequence);
        if (sequenceOrder != 0) return sequenceOrder;
      }
      final timestampOrder = first.createdAt.compareTo(second.createdAt);
      return timestampOrder != 0
          ? timestampOrder
          : first.eventId.compareTo(second.eventId);
    });
    return List.unmodifiable(events);
  }

  Future<OfflineProgressEvent?> getEvent(String uid, String eventId) async {
    if (!await _isAuthorized(uid)) {
      throw StateError(
        'A matching verified student session is required to read offline Story progress.',
      );
    }
    return _store.getEvent(uid, eventId);
  }

  Future<List<OfflineProgressEvent>> getEvents(String uid) async {
    if (!await _isAuthorized(uid)) {
      throw StateError(
        'A matching verified student session is required to read offline Story progress.',
      );
    }
    return _store.getEvents(uid);
  }

  Future<void> acknowledgeAfterServerConfirmation(
    String uid,
    String eventId, {
    required String serverConfirmationId,
  }) async {
    if (!await _isAuthorized(uid)) {
      throw StateError(
        'A matching verified student session is required to acknowledge offline Story progress.',
      );
    }
    await _store.acknowledgeAfterServerConfirmation(
      uid,
      eventId,
      serverConfirmationId: serverConfirmationId,
    );
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _writeQueue;
    _writeQueue = () async {
      await previous;
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  static String _canonicalJson(Object? value) {
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}
