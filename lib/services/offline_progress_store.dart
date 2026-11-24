import 'package:sembast/sembast.dart';

import '../models/offline_progress_event.dart';
import 'offline_progress_database_stub.dart'
    if (dart.library.js_interop) 'offline_progress_database_web.dart'
    if (dart.library.io) 'offline_progress_database_io.dart' as platform;

typedef OfflineProgressDatabaseOpener = Future<Database> Function(
  String databaseName,
);

class OfflineProgressStoreException implements Exception {
  const OfflineProgressStoreException(
    this.code,
    this.message, {
    this.cause,
  });

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'OfflineProgressStoreException($code): $message'
      '${cause == null ? '' : ' Cause: $cause'}';
}

class OfflineProgressStore {
  OfflineProgressStore({
    String databaseName = 'mathquest_offline_progress_v1',
    OfflineProgressDatabaseOpener? openDatabase,
    DateTime Function()? clock,
  })  : _databaseName = databaseName,
        _openDatabase = openDatabase ?? platform.openOfflineProgressDatabase,
        _clock = clock ?? DateTime.now {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(databaseName)) {
      throw ArgumentError.value(databaseName, 'databaseName');
    }
  }

  static const String _schemaRecordId = '_offline_progress_schema';
  static const int _databaseSchemaVersion = 1;
  static final StoreRef<String, Object?> _records = StoreRef.main();

  final String _databaseName;
  final OfflineProgressDatabaseOpener _openDatabase;
  final DateTime Function() _clock;
  Future<Database>? _databaseFuture;

  Future<void> insert(
    String uid,
    OfflineProgressEvent event,
  ) async {
    _validateUid(uid);
    if (event.ownerUid != uid) {
      throw const OfflineProgressStoreException(
        'uid-mismatch',
        'The event owner does not match the requested account.',
      );
    }
    if (event.syncStatus != OfflineProgressSyncStatus.pending) {
      throw const OfflineProgressStoreException(
        'invalid-event-state',
        'Only pending events can be inserted.',
      );
    }

    final database = await _database();
    try {
      await database.transaction((transaction) async {
        final record = _records.record(event.eventId);
        final savedValue = await record.get(transaction);
        if (savedValue != null) {
          final saved = _decodeRecord(event.eventId, savedValue);
          if (saved.hasSameImmutableContent(event)) return;
          throw const OfflineProgressStoreException(
            'event-id-conflict',
            'An event ID cannot be reused with different content.',
          );
        }
        await record.put(transaction, event.toRecord());
      });
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-write-failed',
        'The offline event could not be stored.',
        cause: error,
      );
    }
  }

  Future<List<OfflineProgressEvent>> getPendingEvents(String uid) async {
    _validateUid(uid);
    final database = await _database();
    try {
      final snapshots = await _records.find(
        database,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('ownerUid', uid),
            Filter.equals('syncStatus', OfflineProgressSyncStatus.pending.name),
          ]),
        ),
      );
      final events = snapshots
          .map((snapshot) => _decodeRecord(snapshot.key, snapshot.value))
          .toList()
        ..sort(_compareEvents);
      return List.unmodifiable(events);
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-read-failed',
        'Pending offline events could not be read.',
        cause: error,
      );
    }
  }

  Future<List<OfflineProgressEvent>> getEvents(String uid) async {
    _validateUid(uid);
    final database = await _database();
    try {
      final snapshots = await _records.find(
        database,
        finder: Finder(filter: Filter.equals('ownerUid', uid)),
      );
      final events = snapshots
          .map((snapshot) => _decodeRecord(snapshot.key, snapshot.value))
          .toList()
        ..sort(_compareEvents);
      return List.unmodifiable(events);
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-read-failed',
        'Offline events could not be read.',
        cause: error,
      );
    }
  }

  Future<int> pendingEventCount(String uid) async =>
      (await getPendingEvents(uid)).length;

  Future<OfflineProgressEvent?> getEvent(String uid, String eventId) async {
    _validateUid(uid);
    _validateEventId(eventId);
    final database = await _database();
    try {
      final value = await _records.record(eventId).get(database);
      if (value == null) return null;
      final event = _decodeRecord(eventId, value);
      return event.ownerUid == uid ? event : null;
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-read-failed',
        'The offline event could not be read.',
        cause: error,
      );
    }
  }

  Future<void> acknowledgeAfterServerConfirmation(
    String uid,
    String eventId, {
    required String serverConfirmationId,
  }) async {
    _validateUid(uid);
    _validateEventId(eventId);
    if (serverConfirmationId.trim().isEmpty ||
        serverConfirmationId.length > 256) {
      throw ArgumentError.value(
        serverConfirmationId,
        'serverConfirmationId',
      );
    }
    final database = await _database();
    try {
      await database.transaction((transaction) async {
        final record = _records.record(eventId);
        final value = await record.get(transaction);
        if (value == null) {
          throw const OfflineProgressStoreException(
            'event-not-found',
            'The offline event does not exist.',
          );
        }
        final event = _decodeRecord(eventId, value);
        if (event.ownerUid != uid) {
          throw const OfflineProgressStoreException(
            'uid-mismatch',
            'The event belongs to a different account.',
          );
        }
        if (event.syncStatus == OfflineProgressSyncStatus.acknowledged) {
          if (event.serverConfirmationId == serverConfirmationId.trim()) return;
          throw const OfflineProgressStoreException(
            'acknowledgement-conflict',
            'The event was acknowledged with a different confirmation.',
          );
        }
        await record.put(
          transaction,
          event
              .acknowledged(
                acknowledgedAt: _clock(),
                serverConfirmationId: serverConfirmationId,
              )
              .toRecord(),
        );
      });
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-write-failed',
        'The confirmed offline event could not be acknowledged.',
        cause: error,
      );
    }
  }

  Future<void> close() async {
    final future = _databaseFuture;
    _databaseFuture = null;
    if (future == null) return;
    try {
      final database = await future;
      await database.close();
    } on OfflineProgressStoreException {
      rethrow;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-close-failed',
        'The offline event store could not be closed.',
        cause: error,
      );
    }
  }

  Future<Database> _database() async {
    final existing = _databaseFuture;
    if (existing != null) return existing;

    final opening = _initializeDatabase();
    _databaseFuture = opening;
    try {
      return await opening;
    } on Object {
      if (identical(_databaseFuture, opening)) _databaseFuture = null;
      rethrow;
    }
  }

  Future<Database> _initializeDatabase() async {
    late final Database database;
    try {
      database = await _openDatabase(_databaseName);
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'storage-unavailable',
        'Durable offline storage could not be opened.',
        cause: error,
      );
    }

    try {
      await database.transaction((transaction) async {
        final schema = await _records.record(_schemaRecordId).get(transaction);
        if (schema == null) {
          await _records.record(_schemaRecordId).put(transaction, {
            'schemaVersion': _databaseSchemaVersion,
          });
          return;
        }
        if (schema is! Map || schema['schemaVersion'] is! int) {
          throw const OfflineProgressStoreException(
            'corrupted-schema',
            'The offline event store schema record is malformed.',
          );
        }
        if (schema['schemaVersion'] != _databaseSchemaVersion) {
          throw OfflineProgressStoreException(
            'unsupported-schema',
            'Offline event store schema '
                '${schema['schemaVersion']} is not supported.',
          );
        }
      });
      return database;
    } on OfflineProgressStoreException {
      await database.close();
      rethrow;
    } on Object catch (error) {
      await database.close();
      throw OfflineProgressStoreException(
        'storage-initialization-failed',
        'The offline event store could not be initialized.',
        cause: error,
      );
    }
  }

  OfflineProgressEvent _decodeRecord(String recordId, Object? value) {
    if (value is! Map) {
      throw OfflineProgressStoreException(
        'corrupted-record',
        'Offline event "$recordId" is not a map.',
      );
    }
    try {
      final record = Map<String, Object?>.from(value);
      final event = OfflineProgressEvent.fromRecord(record);
      if (event.eventId != recordId) {
        throw const FormatException('Record ID does not match event ID.');
      }
      return event;
    } on Object catch (error) {
      throw OfflineProgressStoreException(
        'corrupted-record',
        'Offline event "$recordId" is malformed.',
        cause: error,
      );
    }
  }

  static int _compareEvents(
    OfflineProgressEvent first,
    OfflineProgressEvent second,
  ) {
    final createdAtOrder = first.createdAt.compareTo(second.createdAt);
    return createdAtOrder != 0
        ? createdAtOrder
        : first.eventId.compareTo(second.eventId);
  }

  static void _validateUid(String uid) {
    if (uid.trim() != uid ||
        uid.isEmpty ||
        uid.length > 128 ||
        uid.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(uid, 'uid');
    }
  }

  static void _validateEventId(String eventId) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(eventId)) {
      throw ArgumentError.value(eventId, 'eventId');
    }
  }
}
