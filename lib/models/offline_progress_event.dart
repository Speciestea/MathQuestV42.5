import 'dart:convert';

enum OfflineProgressSyncStatus { pending, acknowledged }

class OfflineProgressEvent {
  factory OfflineProgressEvent({
    required String eventId,
    required String ownerUid,
    required String eventType,
    required Map<String, Object?> payload,
    required DateTime createdAt,
    int schemaVersion = currentSchemaVersion,
  }) {
    _validateSchemaVersion(schemaVersion);
    _validateEventId(eventId);
    _validateOwnerUid(ownerUid);
    _validateEventType(eventType);
    final safePayload = _freezeMap(payload);

    return OfflineProgressEvent._(
      schemaVersion: schemaVersion,
      eventId: eventId,
      ownerUid: ownerUid,
      eventType: eventType,
      payload: safePayload,
      createdAt: createdAt.toUtc(),
      syncStatus: OfflineProgressSyncStatus.pending,
    );
  }

  const OfflineProgressEvent._({
    required this.schemaVersion,
    required this.eventId,
    required this.ownerUid,
    required this.eventType,
    required this.payload,
    required this.createdAt,
    required this.syncStatus,
    this.acknowledgedAt,
    this.serverConfirmationId,
  });

  static const int currentSchemaVersion = 1;
  static const Set<String> _requiredFields = {
    'schemaVersion',
    'eventId',
    'ownerUid',
    'eventType',
    'payload',
    'createdAt',
    'syncStatus',
  };
  static const Set<String> _acknowledgementFields = {
    'acknowledgedAt',
    'serverConfirmationId',
  };

  final int schemaVersion;
  final String eventId;
  final String ownerUid;
  final String eventType;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final OfflineProgressSyncStatus syncStatus;
  final DateTime? acknowledgedAt;
  final String? serverConfirmationId;

  bool hasSameImmutableContent(OfflineProgressEvent other) =>
      schemaVersion == other.schemaVersion &&
      eventId == other.eventId &&
      ownerUid == other.ownerUid &&
      eventType == other.eventType &&
      createdAt == other.createdAt &&
      _canonicalJson(payload) == _canonicalJson(other.payload);

  Map<String, Object?> toRecord() => {
        'schemaVersion': schemaVersion,
        'eventId': eventId,
        'ownerUid': ownerUid,
        'eventType': eventType,
        'payload': _mutableJsonValue(payload) as Map<String, Object?>,
        'createdAt': createdAt.toIso8601String(),
        'syncStatus': syncStatus.name,
        if (acknowledgedAt != null)
          'acknowledgedAt': acknowledgedAt!.toIso8601String(),
        if (serverConfirmationId != null)
          'serverConfirmationId': serverConfirmationId,
      };

  factory OfflineProgressEvent.fromRecord(Map<String, Object?> record) {
    try {
      final keys = record.keys.toSet();
      if (!keys.containsAll(_requiredFields) ||
          keys
              .difference(_requiredFields)
              .difference(_acknowledgementFields)
              .isNotEmpty) {
        throw const FormatException('Unexpected offline event fields.');
      }

      final schemaVersion = record['schemaVersion'];
      final eventId = record['eventId'];
      final ownerUid = record['ownerUid'];
      final eventType = record['eventType'];
      final payload = record['payload'];
      final createdAtValue = record['createdAt'];
      final syncStatusValue = record['syncStatus'];

      if (schemaVersion is! int ||
          eventId is! String ||
          ownerUid is! String ||
          eventType is! String ||
          payload is! Map ||
          createdAtValue is! String ||
          syncStatusValue is! String) {
        throw const FormatException('Invalid offline event field types.');
      }
      _validateSchemaVersion(schemaVersion);
      _validateEventId(eventId);
      _validateOwnerUid(ownerUid);
      _validateEventType(eventType);
      final parsedCreatedAt = DateTime.tryParse(createdAtValue);
      if (parsedCreatedAt == null) {
        throw const FormatException('Invalid offline event creation time.');
      }
      final status = OfflineProgressSyncStatus.values
          .where((value) => value.name == syncStatusValue)
          .firstOrNull;
      if (status == null) {
        throw const FormatException('Invalid offline event sync status.');
      }

      final acknowledgementKeys = keys.intersection(_acknowledgementFields);
      final acknowledgedAtValue = record['acknowledgedAt'];
      final confirmationId = record['serverConfirmationId'];
      if (status == OfflineProgressSyncStatus.pending) {
        if (acknowledgementKeys.isNotEmpty) {
          throw const FormatException(
            'Pending events cannot contain acknowledgement metadata.',
          );
        }
      } else {
        if (!acknowledgementKeys.containsAll(_acknowledgementFields) ||
            acknowledgedAtValue is! String ||
            confirmationId is! String ||
            confirmationId.trim().isEmpty ||
            DateTime.tryParse(acknowledgedAtValue) == null) {
          throw const FormatException(
            'Acknowledged events require valid confirmation metadata.',
          );
        }
      }

      return OfflineProgressEvent._(
        schemaVersion: schemaVersion,
        eventId: eventId,
        ownerUid: ownerUid,
        eventType: eventType,
        payload: _freezeMap(Map<String, Object?>.from(payload)),
        createdAt: parsedCreatedAt.toUtc(),
        syncStatus: status,
        acknowledgedAt: acknowledgedAtValue is String
            ? DateTime.parse(acknowledgedAtValue).toUtc()
            : null,
        serverConfirmationId: confirmationId is String ? confirmationId : null,
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Malformed offline event record: $error');
    }
  }

  OfflineProgressEvent acknowledged({
    required DateTime acknowledgedAt,
    required String serverConfirmationId,
  }) {
    final confirmationId = serverConfirmationId.trim();
    if (confirmationId.isEmpty || confirmationId.length > 256) {
      throw ArgumentError.value(
        serverConfirmationId,
        'serverConfirmationId',
      );
    }
    return OfflineProgressEvent._(
      schemaVersion: schemaVersion,
      eventId: eventId,
      ownerUid: ownerUid,
      eventType: eventType,
      payload: payload,
      createdAt: createdAt,
      syncStatus: OfflineProgressSyncStatus.acknowledged,
      acknowledgedAt: acknowledgedAt.toUtc(),
      serverConfirmationId: confirmationId,
    );
  }

  static void _validateSchemaVersion(int schemaVersion) {
    if (schemaVersion != currentSchemaVersion) {
      throw ArgumentError.value(schemaVersion, 'schemaVersion');
    }
  }

  static void _validateEventId(String eventId) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(eventId)) {
      throw ArgumentError.value(eventId, 'eventId');
    }
  }

  static void _validateOwnerUid(String ownerUid) {
    if (ownerUid.trim() != ownerUid ||
        ownerUid.isEmpty ||
        ownerUid.length > 128 ||
        ownerUid.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(ownerUid, 'ownerUid');
    }
  }

  static void _validateEventType(String eventType) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(eventType)) {
      throw ArgumentError.value(eventType, 'eventType');
    }
  }

  static Map<String, Object?> _freezeMap(Map<String, Object?> value) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (_isSensitiveField(entry.key)) {
        throw ArgumentError.value(entry.key, 'payload',
            'Sensitive credential and token fields are not allowed.');
      }
      result[entry.key] = _freezeJsonValue(entry.value);
    }
    return Map.unmodifiable(result);
  }

  static Object? _freezeJsonValue(Object? value) {
    if (value == null || value is String || value is bool || value is int) {
      return value;
    }
    if (value is double) {
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'payload', 'Numbers must be finite.');
      }
      return value;
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_freezeJsonValue));
    }
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw ArgumentError.value(value, 'payload', 'Keys must be strings.');
        }
        final key = entry.key as String;
        if (_isSensitiveField(key)) {
          throw ArgumentError.value(key, 'payload',
              'Sensitive credential and token fields are not allowed.');
        }
        result[key] = _freezeJsonValue(entry.value);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    throw ArgumentError.value(
      value,
      'payload',
      'Payload values must be JSON-compatible.',
    );
  }

  static bool _isSensitiveField(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('token') ||
        normalized.contains('credential') ||
        normalized.contains('secret') ||
        normalized.contains('authorization') ||
        normalized.contains('privatekey') ||
        normalized.contains('apikey');
  }

  static Object? _mutableJsonValue(Object? value) {
    if (value is Map<String, Object?>) {
      return {
        for (final entry in value.entries)
          entry.key: _mutableJsonValue(entry.value),
      };
    }
    if (value is List) {
      return value.map(_mutableJsonValue).toList(growable: false);
    }
    return value;
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
