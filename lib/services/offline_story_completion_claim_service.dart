import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/offline_progress_event.dart';
import 'firestore_transaction.dart';
import 'leaderboard_service.dart';
import 'offline_story_progress_service.dart';
import 'offline_story_sync_coordinator.dart';
import '../worksheet_lesson_data.dart';

class OfflineStoryCompletionClaimService {
  OfflineStoryCompletionClaimService({
    OfflineStoryProgressService? progressService,
    FirebaseFirestore? firestore,
  })  : _progressService = progressService ?? OfflineStoryProgressService(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  static const int _claimSchemaVersion = 1;
  final OfflineStoryProgressService _progressService;
  final FirebaseFirestore _firestore;

  Future<OfflineStorySyncConfirmation?> submit(
    VerifiedOfflineStorySession session,
    OfflineProgressEvent event,
  ) async {
    final claim = _validateCompletionEvent(session, event);
    final npcEvents = await _loadNpcCompletionBundle(
      session.uid,
      event,
      claim.level,
      claim.moduleId,
    );
    final userRef = _firestore.collection('users').doc(session.uid);
    final awardRef = userRef.collection('scoreAwards').doc(
          'game-mode-${claim.level}',
        );
    final leaderboardRef = _firestore
        .collection(LeaderboardService.collectionName)
        .doc(session.uid);

    late final String confirmationId;
    try {
      confirmationId = await runFirestoreTransactionWithRetry<String>(
        _firestore,
        (transaction) async {
          final userSnapshot = await transaction.get(userRef);
          final leaderboardSnapshot = await transaction.get(leaderboardRef);
          final awardSnapshot = await transaction.get(awardRef);
          if (!userSnapshot.exists) {
            throw const OfflineStorySyncConflict(
              'The official student profile no longer exists.',
            );
          }

          final userData = userSnapshot.data()!;
          if (userData['role'] != 'student' ||
              userData['status'] != 'approved') {
            throw const OfflineStorySyncConflict(
              'The student account is no longer approved.',
            );
          }
          final progressValue = userData['progress'];
          if (progressValue is! Map<String, dynamic>) {
            throw const OfflineStorySyncConflict(
              'The official Story progress is invalid.',
            );
          }
          final oldProgress = progressValue;
          final rawScores = oldProgress['gameModeFinalScores'];
          final oldScores = rawScores is Map<String, dynamic>
              ? rawScores
              : <String, dynamic>{};
          final existingScore = oldScores['${claim.level}'];

          if (existingScore != null) {
            if (existingScore == claim.points &&
                awardSnapshot.data()?['points'] == claim.points) {
              final savedEventId = awardSnapshot.data()?['eventId'];
              return savedEventId is String && savedEventId.isNotEmpty
                  ? 'offline-game-mode-award:${session.uid}:${claim.level}:$savedEventId'
                  : 'official-game-mode-award:${session.uid}:${claim.level}:${claim.points}';
            }
            throw const OfflineStorySyncConflict(
              'Official progress already contains a different completion result.',
            );
          }
          if (awardSnapshot.exists) {
            throw const OfflineStorySyncConflict(
              'A Game Mode reward exists without matching official completion.',
            );
          }
          if (!_isLevelUnlocked(oldProgress, claim.level)) {
            throw const OfflineStorySyncConflict(
              'The claimed level is not unlocked in current official progress.',
            );
          }

          final oldNpcValue = oldProgress['completedNpcQuestionsByLevel'];
          final oldNpcByLevel = oldNpcValue is Map<String, dynamic>
              ? Map<String, dynamic>.from(oldNpcValue)
              : <String, dynamic>{};
          final oldNpcQuestions =
              (oldNpcByLevel['${claim.level}'] as List<dynamic>? ?? [])
                  .map((value) => value is int ? value : -1)
                  .toList(growable: false);
          if (oldNpcQuestions.any((question) => question < 1 || question > 6) ||
              oldNpcQuestions.toSet().length != oldNpcQuestions.length) {
            throw const OfflineStorySyncConflict(
              'Official NPC progression is invalid.',
            );
          }

          final savedCompletedLevels = oldProgress['completedLevels'];
          if (savedCompletedLevels is! List ||
              savedCompletedLevels.any((value) => value is! int)) {
            throw const OfflineStorySyncConflict(
              'Official completed-level data cannot be safely reconciled.',
            );
          }
          final completedLevels = savedCompletedLevels.cast<int>().toSet()
            ..add(claim.level);
          final sortedCompletedLevels = completedLevels.toList()..sort();
          final mainLevel = ((claim.level - 1) ~/ 20) + 1;
          final subLevel = ((claim.level - 1) % 20) + 1;
          final sublevelsValue = oldProgress['maxUnlockedSubLevel'];
          final sublevels = <String, int>{
            '1': _asInt(
              sublevelsValue is Map ? sublevelsValue['1'] : null,
              defaultValue: 1,
            ),
            '2': _asInt(
              sublevelsValue is Map ? sublevelsValue['2'] : null,
              defaultValue: 1,
            ),
            '3': _asInt(
              sublevelsValue is Map ? sublevelsValue['3'] : null,
              defaultValue: 1,
            ),
          };
          if (subLevel < 20) {
            sublevels['$mainLevel'] =
                (sublevels['$mainLevel'] ?? 1).clamp(1, 20) > subLevel + 1
                    ? sublevels['$mainLevel']!
                    : subLevel + 1;
          }
          final oldUnlockedLevels =
              _asInt(oldProgress['unlockedLevels'], defaultValue: 1);
          final unlockedLevels = subLevel == 20 && mainLevel < 3
              ? (oldUnlockedLevels > mainLevel + 1
                  ? oldUnlockedLevels
                  : mainLevel + 1)
              : oldUnlockedLevels;

          final leaderboardData =
              leaderboardSnapshot.data() ?? <String, dynamic>{};
          final baseline = userData['scoreBaseline'] ?? 0;
          final earned = userData['scoreEarned'] ?? 0;
          final savedScore = userData['gameScore'];
          if (baseline is! int ||
              earned is! int ||
              (savedScore != null && savedScore is! int) ||
              (savedScore is int && savedScore != baseline + earned)) {
            throw const OfflineStorySyncConflict(
              'The official cumulative score data is inconsistent.',
            );
          }
          final currentUserTotals =
              LeaderboardService.scoreAfterAward(userData, claim.points);
          final currentLeaderboardScore = _leaderboardScore(leaderboardData);
          if (currentLeaderboardScore > currentUserTotals.previousScore) {
            throw const OfflineStorySyncConflict(
              'The official leaderboard is ahead of the student score data.',
            );
          }
          final scoreTotals = LeaderboardService.scoreAfterAward(
            userData,
            claim.points,
            minimumExistingScore: currentLeaderboardScore,
          );
          final currentNpcQuestions =
              oldNpcByLevel['${claim.level}'] as List<dynamic>? ?? [];
          final updatedNpcQuestions = <int>{
            ...currentNpcQuestions.whereType<int>(),
            ...claim.completedNpcQuestionNumbers,
          }.toList()
            ..sort();

          transaction.update(userRef, {
            'progress.completedLevels': sortedCompletedLevels,
            'progress.unlockedLevels': unlockedLevels,
            'progress.maxUnlockedSubLevel': sublevels,
            'progress.completedNpcQuestionsByLevel.${claim.level}':
                updatedNpcQuestions,
            if (claim.level == 1)
              'progress.completedNpcQuestions': updatedNpcQuestions,
            'progress.latestCompletedNpcQuestionLevel': '${claim.level}',
            'progress.gameModeFinalScores.${claim.level}': claim.points,
            'progress.latestCompletedGameModeLevel': '${claim.level}',
            'scoreEarned': scoreTotals.scoreEarned,
            'gameScore': scoreTotals.gameScore,
            'lastScoreAwardId': 'game-mode-${claim.level}',
            'lastScoreAwardPoints': claim.points,
          });
          transaction.set(awardRef, {
            'schemaVersion': _claimSchemaVersion,
            'eventId': event.eventId,
            'uid': session.uid,
            'eventType': event.eventType,
            'moduleId': claim.moduleId,
            'level': claim.level,
            'points': claim.points,
            'completedNpcQuestionNumbers': claim.completedNpcQuestionNumbers,
            'dependsOnEventId': claim.dependsOnEventId,
            'eventSequence': claim.eventSequence,
            'createdAt': FieldValue.serverTimestamp(),
          });

          final displayName = (userData['name'] ?? 'Player').toString();
          final createdAt =
              userData['createdAt'] ?? FieldValue.serverTimestamp();
          final leaderboardUpdate = <String, dynamic>{
            'uid': session.uid,
            'displayName': displayName,
            'totalScore': scoreTotals.gameScore,
            'lastScoreAwardId': 'game-mode-${claim.level}',
            'lastScoreAwardPoints': claim.points,
            'createdAt': createdAt,
            'updatedAt': FieldValue.serverTimestamp(),
          };
          if (leaderboardSnapshot.exists) {
            for (final legacyKey in ['displayname', 'name', 'totalscore']) {
              if (leaderboardData.containsKey(legacyKey)) {
                leaderboardUpdate[legacyKey] = FieldValue.delete();
              }
            }
            transaction.update(leaderboardRef, leaderboardUpdate);
          } else {
            transaction.set(leaderboardRef, leaderboardUpdate);
          }
          return 'offline-game-mode-award:${session.uid}:${claim.level}:${event.eventId}';
        },
      );
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      final userSnapshot = await userRef.get();
      final awardSnapshot = await awardRef.get();
      final savedProgress = userSnapshot.data()?['progress'];
      final savedScores = savedProgress is Map<String, dynamic>
          ? savedProgress['gameModeFinalScores']
          : null;
      final savedScore = savedScores is Map<String, dynamic>
          ? savedScores['${claim.level}']
          : null;
      final awardData = awardSnapshot.data();
      if (!userSnapshot.exists ||
          userSnapshot.data()?['role'] != 'student' ||
          userSnapshot.data()?['status'] != 'approved' ||
          savedScore != claim.points ||
          awardData?['points'] != claim.points) {
        rethrow;
      }
      final savedEventId = awardData?['eventId'];
      confirmationId = savedEventId is String && savedEventId.isNotEmpty
          ? 'offline-game-mode-award:${session.uid}:${claim.level}:$savedEventId'
          : 'official-game-mode-award:${session.uid}:${claim.level}:${claim.points}';
    }

    return OfflineStorySyncConfirmation(
      eventId: event.eventId,
      serverConfirmationId: confirmationId,
      confirmedEventIds: npcEvents.map((npcEvent) => npcEvent.eventId).toList(),
    );
  }

  Future<List<OfflineProgressEvent>> _loadNpcCompletionBundle(
    String uid,
    OfflineProgressEvent completion,
    int level,
    String moduleId,
  ) async {
    final allEvents = await _progressService.getEvents(uid);
    final npcEvents = <int, OfflineProgressEvent>{};
    for (final event in allEvents) {
      if (event.ownerUid != uid ||
          event.payload['uid'] != uid ||
          event.eventType != 'story.npc.completed' ||
          event.payload['level'] != level ||
          event.payload['moduleId'] != moduleId) {
        continue;
      }
      final questionNumber = event.payload['questionNumber'];
      if (questionNumber is! int ||
          questionNumber < 1 ||
          questionNumber > 6 ||
          npcEvents.containsKey(questionNumber)) {
        continue;
      }
      npcEvents[questionNumber] = event;
    }

    final orderedEvents = <OfflineProgressEvent>[];
    var previousSequence = 0;
    for (var questionNumber = 1; questionNumber <= 6; questionNumber++) {
      final npcEvent = npcEvents[questionNumber];
      if (npcEvent == null) {
        throw const OfflineStorySyncConflict(
          'The local completion is missing its NPC progression events.',
        );
      }
      final sequence = npcEvent.payload['eventSequence'];
      final dependencyId = npcEvent.payload['dependsOnEventId'];
      if (sequence is! int ||
          sequence <= previousSequence ||
          sequence >= (completion.payload['eventSequence'] as int) ||
          (questionNumber == 1
              ? dependencyId != null
              : dependencyId != npcEvents[questionNumber - 1]?.eventId)) {
        throw const OfflineStorySyncConflict(
          'The local NPC events are out of order or have invalid dependencies.',
        );
      }
      previousSequence = sequence;
      orderedEvents.add(npcEvent);
    }

    if (completion.payload['dependsOnEventId'] != orderedEvents.last.eventId) {
      throw const OfflineStorySyncConflict(
        'The completion event does not depend on the final NPC event.',
      );
    }
    return List.unmodifiable(orderedEvents);
  }

  _ValidatedCompletion _validateCompletionEvent(
    VerifiedOfflineStorySession session,
    OfflineProgressEvent event,
  ) {
    final payload = event.payload;
    final level = payload['level'];
    final moduleId = payload['moduleId'];
    final points = payload['score'];
    final eventSequence = payload['eventSequence'];
    final dependsOnEventId = payload['dependsOnEventId'];
    if (event.schemaVersion != OfflineProgressEvent.currentSchemaVersion ||
        event.ownerUid != session.uid ||
        payload['uid'] != session.uid ||
        event.eventType != 'story.game-mode.completed' ||
        level is! int ||
        level < 1 ||
        level > 60 ||
        moduleId is! String ||
        moduleId != _moduleForLevel(level) ||
        points is! int ||
        points < 60 ||
        points > 70 ||
        payload['provisionalPoints'] != points ||
        eventSequence is! int ||
        eventSequence < 1 ||
        dependsOnEventId is! String ||
        dependsOnEventId.isEmpty) {
      throw const OfflineStorySyncConflict(
        'The local Game Mode completion claim has an invalid schema or value.',
      );
    }
    return _ValidatedCompletion(
      moduleId: moduleId,
      level: level,
      points: points,
      eventSequence: eventSequence,
      dependsOnEventId: dependsOnEventId,
      completedNpcQuestionNumbers: const [1, 2, 3, 4, 5, 6],
    );
  }

  bool _isLevelUnlocked(Map<String, dynamic> progress, int level) {
    final mainLevel = ((level - 1) ~/ 20) + 1;
    final subLevel = ((level - 1) % 20) + 1;
    final unlockedLevels = _asInt(progress['unlockedLevels'], defaultValue: 1);
    final rawSublevels = progress['maxUnlockedSubLevel'];
    final unlockedSublevel = rawSublevels is Map
        ? _asInt(rawSublevels['$mainLevel'], defaultValue: 1)
        : 1;
    return mainLevel <= unlockedLevels && subLevel <= unlockedSublevel;
  }

  String _moduleForLevel(int level) {
    final range = gameModeTopicRanges.firstWhere(
      (topicRange) =>
          level >= topicRange.firstLevel && level <= topicRange.lastLevel,
    );
    return range.moduleId;
  }

  static int _leaderboardScore(Map<String, dynamic> data) {
    final value = data['totalScore'] ?? data['totalscore'] ?? 0;
    final score = value is int ? value : int.tryParse(value.toString());
    if (score == null || score < 0) {
      throw const OfflineStorySyncConflict(
        'The official leaderboard score is invalid.',
      );
    }
    return score;
  }

  static int _asInt(Object? value, {required int defaultValue}) =>
      value is int && value >= 0 ? value : defaultValue;
}

class _ValidatedCompletion {
  const _ValidatedCompletion({
    required this.moduleId,
    required this.level,
    required this.points,
    required this.eventSequence,
    required this.dependsOnEventId,
    required this.completedNpcQuestionNumbers,
  });

  final String moduleId;
  final int level;
  final int points;
  final int eventSequence;
  final String dependsOnEventId;
  final List<int> completedNpcQuestionNumbers;
}
