import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import {
  doc,
  getDoc,
  runTransaction,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  deleteField,
  arrayUnion,
  getDocs,
  orderBy,
  query,
} from 'firebase/firestore';

const projectId = 'demo-mathquest-rules';
const studentId = 'game-mode-student';
const secondStudentId = 'existing-entry-student';
const attackerId = 'unrelated-student';
const legacyProgressId = 'legacy-progress-student';
const teacherId = 'approved-teacher';
const pendingStudentId = 'pending-student';
const existingProgressStudentId = 'existing-progress-student';
const maxProgressStudentId = 'max-progress-student';
const legacyLeaderboardStudentId = 'legacy-leaderboard-student';
const missingScoreFieldsStudentId = 'missing-score-fields-student';
const stringLevelProgressStudentId = 'string-level-progress-student';
const levelQuestionAwardStudentId = 'level-question-award-student';
const problemAnswerStudentId = 'problem-answer-student';
const noLrnProblemAnswerStudentId = 'no-lrn-problem-answer-student';
const npcProgressStudentId = 'npc-progress-student';
const noLrnNpcProgressStudentId = 'no-lrn-npc-progress-student';
const noLrnClassroomAttemptStudentId = 'no-lrn-classroom-attempt-student';
const noSessionStudentId = 'no-active-session-student';
const offlineClaimStudentId = 'offline-claim-student';
const offlineClaimPendingStudentId = 'offline-claim-pending-student';
const offlineClaimNoSessionStudentId = 'offline-claim-no-session-student';
const offlineClaimConflictStudentId = 'offline-claim-conflict-student';
const sequentialNpcStudentId = 'sequential-npc-student';
const legacyStringScoreStudentId = 'legacy-string-score-student';
const newClassroomCompletionStudentId = 'new-classroom-completion-student';
const rejectedClassroomCompletionStudentId =
  'rejected-classroom-completion-student';
const profileEditStudentId = 'profile-edit-student';
const occupiedLrnStudentId = 'occupied-lrn-student';
const pendingProfileStudentId = 'pending-profile-student';
const rejectedProfileStudentId = 'rejected-profile-student';
const adminRosterId = 'approval-workflow-admin';
const accountDeletionStudentId = 'account-deletion-target';
const approvalWorkflowStudentId = 'approval-workflow-pending';
const rejectionWorkflowStudentId = 'rejection-workflow-pending';
const legacyRosterStudentId = 'legacy-roster-student';
const originalProfileLrn = '123456789012';
const updatedProfileLrn = '234567890123';
const occupiedProfileLrn = '345678901234';
const occupiedOldLrn = '456789012345';
const questions = [1, 2, 3, 4, 5, 6];
const timestamp = Timestamp.fromDate(new Date('2026-01-01T00:00:00Z'));
const rules = await readFile(
  fileURLToPath(new URL('../firestore.rules', import.meta.url)),
  'utf8',
);
const testEnv = await initializeTestEnvironment({
  projectId,
  firestore: { rules },
});

function student(uid) {
  return {
    uid,
    email: `${uid}@example.test`,
    name: uid,
    role: 'student',
    status: 'approved',
    character: 'character3',
    lrn: '123456789012',
    studentNo: 'MQ-000001',
    createdAt: timestamp,
    scoreBaseline: 0,
    scoreEarned: 0,
    gameScore: 0,
    progress: {
      completedLevels: [],
      completedNpcQuestions: questions,
      completedNpcQuestionsByLevel: { '1': questions },
      unlockedLevels: 1,
      maxUnlockedSubLevel: { '1': 1, '2': 1, '3': 1 },
      gameModeFinalScores: {},
    },
  };
}

async function createStudentRegistrationProfile({
  uid,
  email = `${uid}@example.test`,
  character = 'character3',
  userId = uid,
  overrides = {},
}) {
  const db = testEnv.authenticatedContext(uid, { email }).firestore();
  const userRef = doc(db, 'users', userId);
  await setDoc(userRef, {
    uid: userId,
    email,
    role: 'student',
    status: 'pending',
    name: uid,
    address: 'School address',
    studentNo: '1',
    character,
    profilePhotoUrl: '',
    tutorialEligible: true,
    tutorialCompleted: false,
    createdAt: serverTimestamp(),
    ...overrides,
  });
}

async function seedStudent(uid, leaderboardScore) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', uid), student(uid));
    await setDoc(doc(db, 'activeSessions', uid), { sessionId: 'active' });
    if (leaderboardScore != null) {
      await setDoc(doc(db, 'leaderboard', uid), {
        uid,
        displayName: uid,
        totalScore: leaderboardScore,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }
  });
}

async function seedStudentWithoutLrn(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const profile = student(uid);
    delete profile.lrn;
    await setDoc(doc(db, 'users', uid), profile);
    await setDoc(doc(db, 'activeSessions', uid), { sessionId: 'active' });
  });
}

async function seedStudentWithoutSession(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users', uid), student(uid));
  });
}

async function seedTeacher(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', uid), {
      uid,
      name: uid,
      email: `${uid}@example.test`,
      role: 'teacher',
      status: 'approved',
    });
    await setDoc(doc(db, 'activeSessions', uid), { sessionId: 'active' });
  });
}

async function seedAdmin(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', uid), {
      uid,
      name: uid,
      role: 'admin',
      status: 'approved',
    });
    await setDoc(doc(db, 'activeSessions', uid), { sessionId: 'active' });
  });
}

async function ensureStudentLeaderboardEntry(uid) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const leaderboardRef = doc(db, 'leaderboard', uid);
  const leaderboardSnapshot = await getDoc(leaderboardRef);
  if (leaderboardSnapshot.exists()) return;

  const userSnapshot = await getDoc(doc(db, 'users', uid));
  assert.ok(userSnapshot.exists());
  const userData = userSnapshot.data();
  const baseline = userData.scoreBaseline ?? 0;
  const earned = userData.scoreEarned ?? 0;
  const totalScore = Math.max(
    baseline + earned,
    userData.gameScore ?? 0,
  );
  await assertSucceeds(setDoc(leaderboardRef, {
    uid,
    displayName: userData.name,
    totalScore,
    profilePhotoUrl: 'assets/images/player/T-rex.png',
    createdAt: userData.createdAt ?? timestamp,
    updatedAt: serverTimestamp(),
  }));
}

async function completeGameMode(uid, score, level = 1) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);
  const leaderboardRef = doc(db, 'leaderboard', uid);
  const awardRef = doc(userRef, 'scoreAwards', `game-mode-${level}`);

  await runTransaction(db, async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const leaderboardSnapshot = await transaction.get(leaderboardRef);
    const awardSnapshot = await transaction.get(awardRef);
    const userData = userSnapshot.data();
    const oldScore = userData.progress.gameModeFinalScores[String(level)];
    if (oldScore != null) {
      assert.equal(oldScore, score);
      return;
    }
    assert.equal(awardSnapshot.exists(), false);

    const oldEarned = userData.scoreEarned ?? 0;
    const baseline = userData.scoreBaseline ?? 0;
    const userTotal = Math.max(
      baseline + oldEarned,
      userData.gameScore ?? 0,
    );
    const oldProgress = userData.progress;
    const leaderboardRecord = leaderboardSnapshot.data() ?? {};
    const rawPreviousLeaderboardScore =
      leaderboardRecord.totalScore ?? leaderboardRecord.totalscore ?? 0;
    const previousLeaderboardScore =
      typeof rawPreviousLeaderboardScore === 'number'
        ? rawPreviousLeaderboardScore
        : Number.parseInt(rawPreviousLeaderboardScore, 10);
    assert.ok(
      Number.isSafeInteger(previousLeaderboardScore)
        && previousLeaderboardScore >= 0,
    );
    const previousScore = Math.max(userTotal, previousLeaderboardScore);
    const awardId = `game-mode-${level}`;
    const completedLevels = arrayUnion(level);
    const mainLevel = Math.floor((level - 1) / 20) + 1;
    const displayNumber = level % 20 === 0 ? 20 : level % 20;
    const nextSubLevel = displayNumber + 1;
    const sublevels = {
      ...(oldProgress.maxUnlockedSubLevel ?? { '1': 1, '2': 1, '3': 1 }),
    };
    if (nextSubLevel <= 20 && nextSubLevel > (sublevels[mainLevel] ?? 1)) {
      sublevels[mainLevel] = nextSubLevel;
    }
    transaction.update(userRef, {
      'progress.completedLevels': completedLevels,
      'progress.unlockedLevels': oldProgress.unlockedLevels ?? 1,
      'progress.maxUnlockedSubLevel': {
        '1': sublevels['1'] ?? 1,
        '2': sublevels['2'] ?? 1,
        '3': sublevels['3'] ?? 1,
      },
      [`progress.gameModeFinalScores.${level}`]: score,
      'progress.latestCompletedGameModeLevel': String(level),
      scoreEarned: previousScore - baseline + score,
      gameScore: previousScore + score,
      lastScoreAwardId: awardId,
      lastScoreAwardPoints: score,
    });
    transaction.set(awardRef, {
      points: score,
      createdAt: serverTimestamp(),
    });
    const leaderboardData = {
      uid,
      displayName: uid,
      totalScore: previousScore + score,
      lastScoreAwardId: awardId,
      lastScoreAwardPoints: score,
      createdAt: timestamp,
      updatedAt: serverTimestamp(),
    };
    if (leaderboardSnapshot.exists()) {
      const existingLeaderboard = leaderboardSnapshot.data();
      if (Object.hasOwn(existingLeaderboard, 'displayname')) {
        leaderboardData.displayname = deleteField();
      }
      if (Object.hasOwn(existingLeaderboard, 'name')) {
        leaderboardData.name = deleteField();
      }
      if (Object.hasOwn(existingLeaderboard, 'totalscore')) {
        leaderboardData.totalscore = deleteField();
      }
      transaction.update(leaderboardRef, leaderboardData);
    } else {
      transaction.set(leaderboardRef, leaderboardData);
    }
  });
}

async function completeOfflineGameModeClaim(
  uid,
  {
    authUid = uid,
    userId = uid,
    claimId = `offline-game-mode-${uid}-1`,
    level = 1,
    score = 60,
    points = score,
    claimedScoreEarned,
    claimedGameScore,
    moduleId = 'fraction-add-subtract',
    eventType = 'story.game-mode.completed',
    schemaVersion = 1,
    completedNpcQuestionNumbers = questions,
  } = {},
) {
  const db = testEnv.authenticatedContext(authUid).firestore();
  const userRef = doc(db, 'users', userId);
  const leaderboardRef = doc(db, 'leaderboard', userId);
  const awardRef = doc(userRef, 'scoreAwards', `game-mode-${level}`);

  await runTransaction(db, async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const leaderboardSnapshot = await transaction.get(leaderboardRef);
    const awardSnapshot = await transaction.get(awardRef);
    assert.ok(userSnapshot.exists());

    const userData = userSnapshot.data();
    const oldProgress = userData.progress ?? {};
    const oldCompletedLevels = oldProgress.completedLevels ?? [];
    if (
      oldProgress.gameModeFinalScores?.[String(level)] === score &&
      awardSnapshot.data()?.points === score
    ) {
      return;
    }

    const mainLevel = Math.floor((level - 1) / 20) + 1;
    const subLevel = ((level - 1) % 20) + 1;
    const sublevels = {
      ...(oldProgress.maxUnlockedSubLevel ?? {
        '1': 1,
        '2': 1,
        '3': 1,
      }),
    };
    const oldUnlockedLevels = oldProgress.unlockedLevels ?? 1;
    const unlockedLevels =
      subLevel === 20 && mainLevel < 3
        ? Math.max(oldUnlockedLevels, mainLevel + 1)
        : oldUnlockedLevels;
    if (subLevel < 20) {
      sublevels[String(mainLevel)] = Math.max(
        sublevels[String(mainLevel)] ?? 1,
        subLevel + 1,
      );
    }
    const leaderboardData = leaderboardSnapshot.data() ?? {};
    const previousLeaderboardScore =
      leaderboardData.totalScore ?? leaderboardData.totalscore ?? 0;
    const previousScore = Math.max(
      (userData.scoreBaseline ?? 0) + (userData.scoreEarned ?? 0),
      userData.gameScore ?? 0,
      previousLeaderboardScore,
    );
    const baseline = userData.scoreBaseline ?? 0;
    const completedLevels = [...new Set([...oldCompletedLevels, level])]
      .sort((first, second) => first - second);
    const userProgressUpdate = {
      'progress.completedLevels': completedLevels,
      'progress.unlockedLevels': unlockedLevels,
      'progress.maxUnlockedSubLevel': sublevels,
      [`progress.completedNpcQuestionsByLevel.${level}`]: questions,
      ...(level === 1
        ? { 'progress.completedNpcQuestions': questions }
        : {}),
      'progress.latestCompletedNpcQuestionLevel': String(level),
      [`progress.gameModeFinalScores.${level}`]: score,
      'progress.latestCompletedGameModeLevel': String(level),
      scoreEarned: claimedScoreEarned ?? previousScore - baseline + score,
      gameScore: claimedGameScore ?? previousScore + score,
      lastScoreAwardId: `game-mode-${level}`,
      lastScoreAwardPoints: score,
    };
    const claimData = {
      schemaVersion,
      eventId: claimId,
      uid: userId,
      eventType,
      moduleId,
      level,
      points,
      completedNpcQuestionNumbers,
      dependsOnEventId: `npc-${uid}-${level}-6`,
      eventSequence: 7,
      createdAt: serverTimestamp(),
    };
    transaction.update(userRef, userProgressUpdate);
    transaction.set(awardRef, {
      ...claimData,
    });
    const leaderboardUpdate = {
      uid: userId,
      displayName: userData.name,
      totalScore: previousScore + score,
      lastScoreAwardId: `game-mode-${level}`,
      lastScoreAwardPoints: score,
      createdAt: userData.createdAt ?? serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
    for (const legacyKey of ['displayname', 'name', 'totalscore']) {
      if (Object.hasOwn(leaderboardData, legacyKey)) {
        leaderboardUpdate[legacyKey] = deleteField();
      }
    }
    if (leaderboardSnapshot.exists()) {
      transaction.update(leaderboardRef, leaderboardUpdate);
    } else {
      transaction.set(leaderboardRef, leaderboardUpdate);
    }
  });
}

async function awardLevelQuestionPoints(uid, level) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);
  const leaderboardRef = doc(db, 'leaderboard', uid);
  const awardRef = doc(userRef, 'scoreAwards', String(level));
  await ensureStudentLeaderboardEntry(uid);

  try {
    await runTransaction(db, async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const leaderboardSnapshot = await transaction.get(leaderboardRef);
      const awardSnapshot = await transaction.get(awardRef);
      if (awardSnapshot.exists()) {
        assert.equal(awardSnapshot.data().points, 10);
        return;
      }

      const userData = userSnapshot.data();
      const progress = userData.progress;
      assert.ok(progress.levelQuestionAnswers[String(level)]);
      const existing = leaderboardSnapshot.data();
      assert.ok(existing);
      const awardId = String(level);
      const baseline = userData.scoreBaseline ?? 0;
      const userTotal = Math.max(
        baseline + (userData.scoreEarned ?? 0),
        userData.gameScore ?? 0,
        existing.totalScore ?? existing.totalscore ?? 0,
      );
      const scoreAfter = userTotal + 10;
      transaction.update(userRef, {
        scoreEarned: userTotal - baseline + 10,
        gameScore: scoreAfter,
        lastScoreAwardId: awardId,
        lastScoreAwardPoints: 10,
      });
      transaction.set(awardRef, {
        points: 10,
        createdAt: serverTimestamp(),
      });
      transaction.update(leaderboardRef, {
        totalScore: scoreAfter,
        lastScoreAwardId: awardId,
        lastScoreAwardPoints: 10,
        updatedAt: serverTimestamp(),
      });
    });
  } catch (error) {
    await verifyCommittedScoreAward(db, awardRef, 10, error);
  }
}

async function awardMissionPoints(uid, points, awardId) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);
  const leaderboardRef = doc(db, 'leaderboard', uid);
  const awardRef = doc(userRef, 'scoreAwards', `mission-${awardId}`);
  await ensureStudentLeaderboardEntry(uid);

  try {
    await runTransaction(db, async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const leaderboardSnapshot = await transaction.get(leaderboardRef);
      const awardSnapshot = await transaction.get(awardRef);
      if (awardSnapshot.exists()) {
        assert.equal(awardSnapshot.data().points, points);
        return;
      }

      assert.ok(userSnapshot.exists());
      const existing = leaderboardSnapshot.data();
      assert.ok(existing);
      const scoreAwardId = `mission-${awardId}`;
      const userData = userSnapshot.data();
      const baseline = userData.scoreBaseline ?? 0;
      const userTotal = Math.max(
        baseline + (userData.scoreEarned ?? 0),
        userData.gameScore ?? 0,
        existing.totalScore ?? existing.totalscore ?? 0,
      );
      const scoreAfter = userTotal + points;
      transaction.update(userRef, {
        scoreEarned: userTotal - baseline + points,
        gameScore: scoreAfter,
        lastScoreAwardId: scoreAwardId,
        lastScoreAwardPoints: points,
      });
      transaction.set(awardRef, {
        points,
        createdAt: serverTimestamp(),
      });
      transaction.update(leaderboardRef, {
        totalScore: scoreAfter,
        lastScoreAwardId: scoreAwardId,
        lastScoreAwardPoints: points,
        updatedAt: serverTimestamp(),
      });
    });
  } catch (error) {
    await verifyCommittedScoreAward(db, awardRef, points, error);
  }
}

async function verifyCommittedScoreAward(db, awardRef, points, error) {
  if (error?.code !== 'permission-denied') throw error;
  const awardSnapshot = await getDoc(awardRef);
  if (!awardSnapshot.exists()) throw error;
  assert.equal(awardSnapshot.data().points, points);
}

async function completeNpcQuestion(uid, questionNumber, level = 1) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);

  await runTransaction(db, async (transaction) => {
    const snapshot = await transaction.get(userRef);
    const progress = snapshot.data().progress;
    const byLevel = progress.completedNpcQuestionsByLevel ?? {};
    const completed = byLevel[String(level)] ?? [];
    if (completed.includes(questionNumber)) return;
    assert.equal(completed.length + 1, questionNumber);

    const updatedQuestions = [...completed, questionNumber];
    transaction.set(
      userRef,
      {
        progress: {
          completedNpcQuestions: level === 1
            ? updatedQuestions
            : progress.completedNpcQuestions,
          completedNpcQuestionsByLevel: {
            ...byLevel,
            [String(level)]: updatedQuestions,
          },
          latestCompletedNpcQuestionLevel: String(level),
        },
      },
      { merge: true },
    );
  });
}

async function saveGameModeAnswers(uid) {
  const db = testEnv.authenticatedContext(uid).firestore();
  for (let questionNumber = 1; questionNumber <= 6; questionNumber++) {
    await setDoc(
      doc(db, 'users', uid, 'gameModeAttempts', `level-1-${questionNumber}`),
      {
        uid,
        level: 1,
        questionNumber,
        question: `Question ${questionNumber}`,
        selectedAnswer: '2',
        correctAnswer: '2',
        isCorrect: true,
        scoreEarned: 10,
        scoreAfter: questionNumber * 10,
        attemptedAt: serverTimestamp(),
      },
    );
  }
}

async function recordProblemLevelAttempt(
  uid,
  attemptId,
  selectedAnswer,
  correctAnswer,
  { userId = uid, question = '17 + 23 = ?' } = {},
) {
  const db = testEnv.authenticatedContext(uid).firestore();
  await setDoc(
    doc(db, 'users', userId, 'problemLevelAttempts', attemptId),
    {
      uid: userId,
      level: 1,
      question,
      selectedAnswer,
      correctAnswer,
      isCorrect: selectedAnswer === correctAnswer,
      attemptedAt: serverTimestamp(),
    },
  );
}

async function recordClassroomAttempt(uid, attemptId, questionNumber = 1) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);
  const attemptRef = doc(userRef, 'classroomQuestAttempts', attemptId);
  await runTransaction(db, async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const attemptSnapshot = await transaction.get(attemptRef);
    if (attemptSnapshot.exists()) return;
    const userData = userSnapshot.data();
    const oldCount = userData.progress.questAttempts ?? 0;
    transaction.set(attemptRef, {
      uid,
      questId: 'classroom_quest',
      type: 'answer',
      questionNumber,
      answer: '3/4',
      isCorrect: true,
      score: 10,
      attemptNumber: oldCount + 1,
      timeSpentSeconds: 12,
      timedOut: false,
      status: 'correct',
      attemptedAt: serverTimestamp(),
    });
    transaction.update(userRef, {
      'progress.questAttempts': oldCount + 1,
      'progress.latestClassroomQuestAttemptId': attemptId,
    });
  });
}

async function completeClassroomQuest(
  uid,
  completionTimeSeconds,
  {
    correctAnswers = 3,
    totalQuestions = 3,
    recordAttempts = true,
  } = {},
) {
  const db = testEnv.authenticatedContext(uid).firestore();
  const userRef = doc(db, 'users', uid);
  const leaderboardRef = doc(db, 'leaderboard', uid);
  const dayKey = classroomQuestDayKey();
  const dailyRef = doc(userRef, 'classroomQuestDailyCompletions', dayKey);
  const scoreAwardId = `classroom-quest-${dayKey}`;
  const awardRef = doc(userRef, 'scoreAwards', scoreAwardId);
  const completionId = `classroom-completion-${uid}`;
  const correctAttemptIds = [1, 2, 3].map(
    (questionNumber) => `${completionId}-answer-${questionNumber}`,
  );
  const questionIds = ['worksheet-1', 'worksheet-2', 'worksheet-3'];
  if (recordAttempts) {
    for (let questionNumber = 1; questionNumber <= 3; questionNumber++) {
      await recordClassroomAttempt(
        uid,
        correctAttemptIds[questionNumber - 1],
        questionNumber,
      );
    }
  }
  await ensureStudentLeaderboardEntry(uid);
  await runTransaction(db, async (transaction) => {
    const snapshot = await transaction.get(userRef);
    const dailySnapshot = await transaction.get(dailyRef);
    const leaderboardSnapshot = await transaction.get(leaderboardRef);
    const awardSnapshot = await transaction.get(awardRef);
    if (dailySnapshot.exists()) return;
    assert.equal(awardSnapshot.exists(), false);
    assert.ok(leaderboardSnapshot.exists());
    const userData = snapshot.data();
    const progress = userData.progress ?? {};
    const results = { ...(progress.classroomQuestResults ?? {}) };
    const history = { ...(progress.classroomQuestHistory ?? {}) };
    const completionTimes = {
      ...(progress.classroomQuestCompletionTimes ?? {}),
      classroom_quest: completionTimeSeconds,
    };
    const completedAt = serverTimestamp();
    history[completionId] = {
      type: 'completion',
      completionTimeSeconds,
      score: correctAnswers * 10,
      correctAnswers,
      totalQuestions,
      dayKey,
      completedAt,
    };
    results.classroom_quest = {
      status: 'completed',
      completionTimeSeconds,
      score: correctAnswers * 10,
      correctAnswers,
      totalQuestions,
      dayKey,
      completedAt,
    };
    const leaderboardData = leaderboardSnapshot.data();
    const baseline = userData.scoreBaseline ?? 0;
    const userTotal = Math.max(
      baseline + (userData.scoreEarned ?? 0),
      userData.gameScore ?? 0,
      leaderboardData.totalScore ?? leaderboardData.totalscore ?? 0,
    );
    const score = correctAnswers * 10;
    const scoreAfter = userTotal + score;
    transaction.update(userRef, {
      'progress.classroomQuestCompletionTimes': completionTimes,
      'progress.classroomQuestResults': results,
      'progress.classroomQuestHistory': history,
      'progress.latestClassroomQuestHistoryId': completionId,
      scoreEarned: userTotal - baseline + score,
      gameScore: scoreAfter,
      lastScoreAwardId: scoreAwardId,
      lastScoreAwardPoints: score,
    });
    transaction.set(awardRef, {
      points: score,
      createdAt: serverTimestamp(),
    });
    transaction.update(leaderboardRef, {
      uid,
      displayName: uid,
      totalScore: scoreAfter,
      lastScoreAwardId: scoreAwardId,
      lastScoreAwardPoints: score,
      createdAt: leaderboardData.createdAt ?? timestamp,
      updatedAt: serverTimestamp(),
    });
    transaction.set(dailyRef, {
      uid,
      questId: 'classroom_quest',
      dayKey,
      completionId,
      questionIds,
      correctAttemptIds,
      completionTimeSeconds,
      correctAnswers,
      totalQuestions,
      score: correctAnswers * 10,
      completedAt,
    });
  });
}

function classroomQuestDayKey(date = new Date()) {
  const manilaDate = new Date(date.getTime() + 8 * 60 * 60 * 1000);
  return `${manilaDate.getUTCFullYear()}-${String(
    manilaDate.getUTCMonth() + 1,
  ).padStart(2, '0')}-${String(manilaDate.getUTCDate()).padStart(2, '0')}`;
}

try {
  for (const [uid, character] of [
    ['new-registration-boy', 'boy'],
    ['new-registration-girl', 'girl'],
    ['new-registration-character3', 'character3'],
    ['new-registration-character4', 'character4'],
    ['new-registration-character5', 'character5'],
  ]) {
    await assertFails(
      createStudentRegistrationProfile({ uid, character }),
    );
  }
  await assertFails(
    createStudentRegistrationProfile({
      uid: 'registration-role-escalation',
      overrides: { role: 'admin' },
    }),
  );
  await assertFails(
    createStudentRegistrationProfile({
      uid: 'registration-wrong-document-id',
      userId: 'another-users-id',
    }),
  );
  await assertFails(
    createStudentRegistrationProfile({
      uid: 'registration-forged-student-number',
      overrides: { studentNo: '1' },
    }),
  );
  await assertFails(
    createStudentRegistrationProfile({
      uid: 'registration-invalid-character',
      character: 'admin',
    }),
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const uid of [approvalWorkflowStudentId, rejectionWorkflowStudentId]) {
      await setDoc(doc(db, 'users', uid), {
        ...student(uid),
        status: 'pending',
      });
    }
    const legacyRosterStudent = student(legacyRosterStudentId);
    delete legacyRosterStudent.studentNo;
    await setDoc(doc(db, 'users', legacyRosterStudentId), {
      ...legacyRosterStudent,
      status: 'pending',
    });
  });
  await seedAdmin(adminRosterId);
  const adminDb = testEnv.authenticatedContext(adminRosterId).firestore();
  const approvalWorkflowStudentDb =
    testEnv.authenticatedContext(approvalWorkflowStudentId).firestore();
  const approvalStudentRef = doc(adminDb, 'users', approvalWorkflowStudentId);
  const rejectionStudentRef = doc(adminDb, 'users', rejectionWorkflowStudentId);
  const roster = await getDocs(
    query(collection(adminDb, 'users'), orderBy('name')),
  );
  assert.ok(roster.docs.some((account) => account.id === approvalWorkflowStudentId));
  const legacyRosterAccount = roster.docs.find(
    (account) => account.id === legacyRosterStudentId,
  );
  assert.ok(legacyRosterAccount);
  assert.equal(legacyRosterAccount.data().lrn, originalProfileLrn);
  assert.equal('studentNo' in legacyRosterAccount.data(), false);
  assert.equal(legacyRosterAccount.data().status, 'pending');
  await assertSucceeds(
    updateDoc(doc(adminDb, 'users', legacyRosterStudentId), {
      status: 'approved',
    }),
  );
  const approvedLegacyRosterAccount = await getDoc(
    doc(adminDb, 'users', legacyRosterStudentId),
  );
  assert.equal(approvedLegacyRosterAccount.data().status, 'approved');
  assert.equal(approvedLegacyRosterAccount.data().lrn, originalProfileLrn);
  assert.equal('studentNo' in approvedLegacyRosterAccount.data(), false);
  assert.equal(
    (await getDoc(doc(approvalWorkflowStudentDb, 'users', approvalWorkflowStudentId)))
      .data().status,
    'pending',
  );
  await assertFails(updateDoc(
    doc(approvalWorkflowStudentDb, 'users', approvalWorkflowStudentId),
    { status: 'approved' },
  ));
  await assertFails(updateDoc(approvalStudentRef, { scoreEarned: 100 }));
  await assertSucceeds(updateDoc(approvalStudentRef, { status: 'approved' }));
  assert.equal(
    (await getDoc(doc(approvalWorkflowStudentDb, 'users', approvalWorkflowStudentId)))
      .data().status,
    'approved',
  );
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', accountDeletionStudentId), {
      ...student(accountDeletionStudentId),
    });
    await setDoc(doc(db, 'activeSessions', accountDeletionStudentId), {
      sessionId: 'target-student-session',
    });
  });
  const accountDeletionBatch = writeBatch(adminDb);
  accountDeletionBatch.delete(doc(adminDb, 'users', accountDeletionStudentId));
  accountDeletionBatch.delete(
    doc(adminDb, 'activeSessions', accountDeletionStudentId),
  );
  await assertSucceeds(accountDeletionBatch.commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal(
      (await getDoc(doc(db, 'users', accountDeletionStudentId))).exists(),
      false,
    );
    assert.equal(
      (await getDoc(doc(db, 'activeSessions', accountDeletionStudentId)))
        .exists(),
      false,
    );
    assert.equal(
      (await getDoc(doc(db, 'users', rejectionWorkflowStudentId))).exists(),
      true,
    );
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'activeSessions', approvalWorkflowStudentId),
      { sessionId: 'active' },
    );
  });
  await assertSucceeds(
    getDoc(doc(approvalWorkflowStudentDb, 'leaderboard', approvalWorkflowStudentId)),
  );
  await assertSucceeds(updateDoc(rejectionStudentRef, { status: 'rejected' }));
  assert.equal(
    (await getDoc(doc(
      testEnv.authenticatedContext(rejectionWorkflowStudentId).firestore(),
      'users',
      rejectionWorkflowStudentId,
    ))).data().status,
    'rejected',
  );
  await assertFails(
    getDoc(doc(
      testEnv.authenticatedContext(rejectionWorkflowStudentId).firestore(),
      'leaderboard',
      rejectionWorkflowStudentId,
    )),
  );
  await assertFails(updateDoc(rejectionStudentRef, { status: 'approved' }));
  console.log(
    'PASS: pending and legacy LRN accounts appear in the admin roster and can be approved/rejected without Student No. migration.',
  );

  await seedStudent(studentId, null);
  await seedStudent(secondStudentId, 35);
  await seedStudent(attackerId, 0);
  await seedStudent(legacyProgressId, null);
  await seedStudent(pendingStudentId, null);
  await seedStudent(existingProgressStudentId, 155);
  await seedStudent(maxProgressStudentId, 3565);
  await seedStudent(legacyLeaderboardStudentId, null);
  await seedStudent(missingScoreFieldsStudentId, null);
  await seedStudent(stringLevelProgressStudentId, 130);
  await seedStudent(levelQuestionAwardStudentId, null);
  await seedStudent(problemAnswerStudentId, null);
  await seedStudentWithoutLrn(noLrnProblemAnswerStudentId);
  await seedStudentWithoutLrn(noLrnNpcProgressStudentId);
  await seedStudentWithoutLrn(noLrnClassroomAttemptStudentId);
  await seedStudent(npcProgressStudentId, null);
  await seedStudent(offlineClaimStudentId, 0);
  await seedStudent(offlineClaimPendingStudentId, 0);
  await seedStudent(offlineClaimNoSessionStudentId, null);
  await seedStudent(offlineClaimConflictStudentId, 0);
  await seedStudent(sequentialNpcStudentId, null);
  await seedStudent(legacyStringScoreStudentId, null);
  await seedStudent(newClassroomCompletionStudentId, null);
  await seedStudent(rejectedClassroomCompletionStudentId, null);
  await seedStudent(profileEditStudentId, null);
  await seedStudent(occupiedLrnStudentId, null);
  await seedStudent(pendingProfileStudentId, null);
  await seedStudent(rejectedProfileStudentId, null);
  await seedStudent('legacy-profile-student', null);
  await seedStudentWithoutSession(noSessionStudentId);
  await seedStudentWithoutSession(offlineClaimNoSessionStudentId);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(
      doc(context.firestore(), 'users', offlineClaimPendingStudentId),
      { status: 'pending' },
    );
    for (const uid of [offlineClaimStudentId, offlineClaimConflictStudentId]) {
      await updateDoc(doc(context.firestore(), 'users', uid), {
        'progress.completedNpcQuestions': [],
        'progress.completedNpcQuestionsByLevel': {},
      });
    }
    await updateDoc(doc(context.firestore(), 'users', noLrnNpcProgressStudentId), {
      'progress.completedNpcQuestions': [],
      'progress.completedNpcQuestionsByLevel': {},
    });
    await deleteDoc(
      doc(context.firestore(), 'activeSessions', offlineClaimConflictStudentId),
    );
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await updateDoc(doc(db, 'users', 'legacy-profile-student'), {
      address: deleteField(),
      grade: deleteField(),
    });
    await updateDoc(doc(db, 'users', pendingProfileStudentId), {
      status: 'pending',
    });
    await updateDoc(doc(db, 'users', rejectedProfileStudentId), {
      status: 'rejected',
    });
    await setDoc(doc(db, 'lrnIndexes', originalProfileLrn), {
      uid: profileEditStudentId,
      createdAt: timestamp,
    });
    await setDoc(doc(db, 'lrnIndexes', occupiedProfileLrn), {
      uid: occupiedLrnStudentId,
      createdAt: timestamp,
    });
    await updateDoc(doc(db, 'users', occupiedLrnStudentId), {
      lrn: occupiedOldLrn,
    });
    await setDoc(doc(db, 'lrnIndexes', occupiedOldLrn), {
      uid: occupiedLrnStudentId,
      createdAt: timestamp,
    });
    await setDoc(
      doc(db, 'leaderboard', legacyStringScoreStudentId),
      {
        uid: legacyStringScoreStudentId,
        displayname: legacyStringScoreStudentId,
        totalscore: '75',
        createdAt: timestamp,
        updatedAt: timestamp,
      },
    );
  });
  {
    const db = testEnv.authenticatedContext(profileEditStudentId).firestore();
    const userRef = doc(db, 'users', profileEditStudentId);
    await assertSucceeds(updateDoc(userRef, { name: 'Updated Name' }));
    await assertSucceeds(updateDoc(userRef, { address: 'Updated address' }));
    await assertSucceeds(updateDoc(userRef, { grade: 'Grade 7' }));
    await assertFails(updateDoc(userRef, { address: deleteField() }));
    await assertFails(updateDoc(userRef, { grade: deleteField() }));
    await assertFails(updateDoc(userRef, { grade: 'Grade 8' }));
    await assertFails(updateDoc(userRef, { email: 'forged@example.test' }));
    const unverifiedEmailDb = testEnv.authenticatedContext(
      profileEditStudentId,
      {
        email: 'unverified@example.test',
        email_verified: false,
      },
    ).firestore();
    await assertFails(updateDoc(
      doc(unverifiedEmailDb, 'users', profileEditStudentId),
      { email: 'unverified@example.test' },
    ));
    const attackerDb = testEnv.authenticatedContext(attackerId).firestore();
    await assertFails(updateDoc(
      doc(attackerDb, 'users', profileEditStudentId),
      { name: 'Unauthorized Name' },
    ));

    await assertFails(updateDoc(userRef, { lrn: updatedProfileLrn }));
    await assertFails(updateDoc(userRef, { studentNo: 'MQ-999999' }));
    const protectedIdentity = (await getDoc(userRef)).data();
    assert.equal(protectedIdentity.lrn, originalProfileLrn);
    assert.equal(protectedIdentity.studentNo, 'MQ-000001');

    const openedProfile = await getDoc(userRef);
    assert.equal(openedProfile.data().name, 'Updated Name');
    assert.equal(openedProfile.data().studentNo, 'MQ-000001');
    await assertSucceeds(updateDoc(userRef, {
      name: 'Saved Profile Name',
      address: 'Saved profile address',
      grade: 'Grade 7',
    }));
    const reopenedDb =
      testEnv.authenticatedContext(profileEditStudentId).firestore();
    const reopenedProfile = await getDoc(
      doc(reopenedDb, 'users', profileEditStudentId),
    );
    assert.equal(reopenedProfile.data().name, 'Saved Profile Name');
    assert.equal(reopenedProfile.data().address, 'Saved profile address');
    assert.equal(reopenedProfile.data().grade, 'Grade 7');
    assert.equal(reopenedProfile.data().studentNo, 'MQ-000001');
    assert.equal(reopenedProfile.data().role, 'student');
    assert.equal(reopenedProfile.data().status, 'approved');
    console.log(
      'PASS: profile data opens, saves to its user document, and persists when reopened without Cloud Functions.',
    );

    const updatedEmail = 'verified@example.test';
    const emailDb = testEnv.authenticatedContext(profileEditStudentId, {
      email: updatedEmail,
      email_verified: true,
    }).firestore();
    await assertSucceeds(updateDoc(
      doc(emailDb, 'users', profileEditStudentId),
      { email: updatedEmail },
    ));
    const photoDb = db;
    await assertSucceeds(runTransaction(photoDb, async (transaction) => {
      const currentUser = await transaction.get(userRef);
      transaction.update(userRef, {
        profilePhotoUrl: 'firestore://profile-photo',
      });
      transaction.set(doc(userRef, 'profileData', 'photo'), {
        data: 'data:image/jpeg;base64,YWJj',
      });
      assert.equal(currentUser.exists(), true);
    }));
    const photoRef = doc(userRef, 'profileData', 'photo');
    await ensureStudentLeaderboardEntry(profileEditStudentId);
    await assertSucceeds(updateDoc(
      doc(photoDb, 'leaderboard', profileEditStudentId),
      {
        profilePhotoUrl: 'firestore://profile-photo',
        updatedAt: serverTimestamp(),
      },
    ));
    await assertSucceeds(
      getDoc(
        doc(
          testEnv.authenticatedContext(secondStudentId).firestore(),
          'users',
          profileEditStudentId,
          'profileData',
          'photo',
        ),
      ),
    );
    const replacementBatch = writeBatch(photoDb);
    replacementBatch.update(userRef, {
      profilePhotoUrl: 'firestore://profile-photo',
    });
    replacementBatch.set(photoRef, {
      data: 'data:image/png;base64,UkVQTEFDRU1FTlQ=',
    });
    await assertFails(replacementBatch.commit());
    assert.equal(
      (await getDoc(photoRef)).data().data,
      'data:image/jpeg;base64,YWJj',
    );

    await assertSucceeds(runTransaction(photoDb, async (transaction) => {
      const currentUser = await transaction.get(userRef);
      if (currentUser.data().profilePhotoUrl !== 'firestore://profile-photo') {
        transaction.update(userRef, {
          profilePhotoUrl: 'firestore://profile-photo',
        });
      }
      transaction.set(photoRef, {
        data: 'data:image/png;base64,UkVQTEFDRU1FTlQ=',
      });
    }));
    assert.equal(
      (await getDoc(photoRef)).data().data,
      'data:image/png;base64,UkVQTEFDRU1FTlQ=',
    );

    await assertFails(runTransaction(photoDb, async (transaction) => {
      const currentUser = await transaction.get(userRef);
      if (currentUser.data().profilePhotoUrl !== 'firestore://profile-photo') {
        transaction.update(userRef, {
          profilePhotoUrl: 'firestore://profile-photo',
        });
      }
      transaction.set(photoRef, {
        data: 'data:image/gif;base64,YWJj',
      });
    }));
    assert.equal(
      (await getDoc(photoRef)).data().data,
      'data:image/png;base64,UkVQTEFDRU1FTlQ=',
    );
    console.log('PASS: repeated profile photo replacement succeeds.');
    console.log('PASS: rejected profile photo replacement preserves the previous photo.');

    const legacyDb =
      testEnv.authenticatedContext('legacy-profile-student').firestore();
    await assertSucceeds(updateDoc(
      doc(legacyDb, 'users', 'legacy-profile-student'),
      { name: 'Legacy Profile Name' },
    ));
    const noSessionDb =
      testEnv.authenticatedContext(noSessionStudentId).firestore();
    await assertFails(updateDoc(
      doc(noSessionDb, 'users', noSessionStudentId),
      { name: 'No Session Name' },
    ));
    for (const deniedUid of [
      pendingProfileStudentId,
      rejectedProfileStudentId,
    ]) {
      const deniedDb = testEnv.authenticatedContext(deniedUid).firestore();
      await assertFails(updateDoc(
        doc(deniedDb, 'users', deniedUid),
        { name: 'Unapproved Name' },
      ));
    }

    const duplicateDb =
      testEnv.authenticatedContext(occupiedLrnStudentId).firestore();
    await assertFails(runTransaction(duplicateDb, async (transaction) => {
      const userRef = doc(duplicateDb, 'users', occupiedLrnStudentId);
      const oldIndex = doc(duplicateDb, 'lrnIndexes', occupiedOldLrn);
      const nextIndex = doc(duplicateDb, 'lrnIndexes', occupiedProfileLrn);
      const user = await transaction.get(userRef);
      await transaction.get(oldIndex);
      await transaction.get(nextIndex);
      transaction.update(userRef, { lrn: occupiedProfileLrn });
      transaction.set(nextIndex, {
        uid: occupiedLrnStudentId,
        createdAt: serverTimestamp(),
      });
      transaction.delete(oldIndex);
    }));
    await assertFails(updateDoc(
      doc(duplicateDb, 'users', occupiedLrnStudentId),
      { lrn: '12-not-a-number' },
    ));
    console.log('PASS: profile grade/email rules and immutable student identifiers.');
  }
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const uid of [
      npcProgressStudentId,
      noSessionStudentId,
      sequentialNpcStudentId,
    ]) {
      await updateDoc(doc(db, 'users', uid), {
        'progress.completedNpcQuestions': [],
        'progress.completedNpcQuestionsByLevel': {},
      });
    }
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const activeSession = await getDoc(
      doc(context.firestore(), 'activeSessions', noSessionStudentId),
    );
    assert.equal(activeSession.exists(), false);
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(
      doc(context.firestore(), 'users', levelQuestionAwardStudentId),
      {
        'progress.levelQuestionAnswers.1': {
          firstOperand: 17,
          secondOperand: 23,
          operation: '+',
          correctAnswer: 40,
        },
        'progress.latestLevelQuestionAnswerLevel': '1',
      },
    );
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', stringLevelProgressStudentId), {
      scoreBaseline: 0,
      scoreEarned: 130,
      gameScore: 130,
      progress: {
        completedLevels: ['1', '2'],
        completedNpcQuestions: questions,
        completedNpcQuestionsByLevel: {
          '1': questions,
          '2': questions,
          '3': questions,
        },
        unlockedLevels: 1,
        maxUnlockedSubLevel: { '1': 2, '2': 1, '3': 1 },
        gameModeFinalScores: { '1': 60, '2': 70 },
        latestCompletedGameModeLevel: '2',
      },
    });
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', missingScoreFieldsStudentId), {
      scoreBaseline: deleteField(),
      scoreEarned: deleteField(),
      gameScore: deleteField(),
    });
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(
      doc(context.firestore(), 'leaderboard', maxProgressStudentId),
      {
        displayname: maxProgressStudentId,
        name: maxProgressStudentId,
        totalscore: 3565,
      },
    );
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'leaderboard', legacyLeaderboardStudentId),
      {
        uid: legacyLeaderboardStudentId,
        displayname: legacyLeaderboardStudentId,
        name: legacyLeaderboardStudentId,
        totalscore: 75,
        createdAt: timestamp,
        updatedAt: timestamp,
      },
    );
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const completedLevels = Array.from({ length: 59 }, (_, index) => index + 1);
    const priorScores = Object.fromEntries(
      completedLevels.map((level) => [String(level), 60]),
    );
    await updateDoc(doc(context.firestore(), 'users', maxProgressStudentId), {
      scoreBaseline: 25,
      scoreEarned: 3540,
      gameScore: 3565,
      progress: {
        completedLevels,
        completedNpcQuestions: questions,
        completedNpcQuestionsByLevel: { '60': questions },
        unlockedLevels: 3,
        maxUnlockedSubLevel: { '1': 20, '2': 20, '3': 20 },
        gameModeFinalScores: priorScores,
        latestCompletedGameModeLevel: '59',
      },
    });
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', pendingStudentId), {
      status: 'pending',
    });
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', existingProgressStudentId), {
      scoreBaseline: 25,
      scoreEarned: 130,
      gameScore: 155,
      progress: {
        completedLevels: [1, 2],
        completedNpcQuestions: questions,
        completedNpcQuestionsByLevel: {
          '1': questions,
          '2': questions,
          '3': questions,
        },
        unlockedLevels: 1,
        maxUnlockedSubLevel: { '1': 2, '2': 1, '3': 1 },
        gameModeFinalScores: { '1': 60, '2': 70 },
        latestCompletedGameModeLevel: '2',
        classroomQuestHistory: {
          'previous-completion': {
            type: 'completion',
            completionTimeSeconds: 42,
            score: 30,
            correctAnswers: 3,
            totalQuestions: 3,
            completedAt: timestamp,
          },
        },
        classroomQuestCompletionTimes: { classroom_quest: 42 },
        classroomQuestResults: {},
      },
    });
  });
  await seedTeacher(teacherId);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(
        context.firestore(),
        'users',
        profileEditStudentId,
        'profileData',
        'photo',
      ),
      { data: 'data:image/png;base64,aGVsbG8=' },
    );
  });
  {
    const profilePhotoPath = [
      'users',
      profileEditStudentId,
      'profileData',
      'photo',
    ];
    await assertSucceeds(getDoc(doc(adminDb, ...profilePhotoPath)));
    const teacherDb = testEnv.authenticatedContext(teacherId).firestore();
    await assertSucceeds(getDoc(doc(teacherDb, ...profilePhotoPath)));
    const studentDb =
      testEnv.authenticatedContext(profileEditStudentId).firestore();
    await assertSucceeds(getDoc(doc(studentDb, ...profilePhotoPath)));
    const unrelatedStudentDb =
      testEnv.authenticatedContext(attackerId).firestore();
    await assertSucceeds(getDoc(doc(unrelatedStudentDb, ...profilePhotoPath)));
  }
  {
    const verifiedTeacherDb = testEnv.authenticatedContext(teacherId, {
      email: 'updated-teacher@example.test',
      email_verified: true,
    }).firestore();
    const teacherRef = doc(verifiedTeacherDb, 'users', teacherId);
    await assertSucceeds(updateDoc(teacherRef, {
      name: 'Updated Teacher Name',
    }));
    await assertSucceeds(updateDoc(teacherRef, {
      email: 'updated-teacher@example.test',
    }));

    const unverifiedTeacherDb = testEnv.authenticatedContext(teacherId, {
      email: 'unverified-teacher@example.test',
      email_verified: false,
    }).firestore();
    await assertFails(updateDoc(
      doc(unverifiedTeacherDb, 'users', teacherId),
      { email: 'unverified-teacher@example.test' },
    ));

    const mismatchedTeacherDb = testEnv.authenticatedContext(teacherId, {
      email: 'different-teacher@example.test',
      email_verified: true,
    }).firestore();
    await assertFails(updateDoc(
      doc(mismatchedTeacherDb, 'users', teacherId),
      { email: 'forged-teacher@example.test' },
    ));
  }
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users', legacyProgressId), {
      ...student(legacyProgressId),
      progress: {
        ...student(legacyProgressId).progress,
        completedNpcQuestionsByLevel: {},
      },
    });
  });

  const problemAnswerDb =
    testEnv.authenticatedContext(problemAnswerStudentId).firestore();
  await assertSucceeds(recordProblemLevelAttempt(
    problemAnswerStudentId,
    'correct-answer',
    40,
    40,
  ));
  await assertSucceeds(recordProblemLevelAttempt(
    problemAnswerStudentId,
    'incorrect-answer',
    41,
    40,
  ));
  assert.equal((await getDoc(doc(
    problemAnswerDb,
    'users',
    problemAnswerStudentId,
    'problemLevelAttempts',
    'correct-answer',
  ))).data().isCorrect, true);
  assert.equal((await getDoc(doc(
    problemAnswerDb,
    'users',
    problemAnswerStudentId,
    'problemLevelAttempts',
    'incorrect-answer',
  ))).data().isCorrect, false);
  await assertFails(recordProblemLevelAttempt(
    problemAnswerStudentId,
    'correct-answer',
    39,
    40,
  ));
  await assertFails(recordProblemLevelAttempt(
    problemAnswerStudentId,
    'another-students-answer',
    40,
    40,
    { userId: secondStudentId },
  ));
  await assertFails(updateDoc(
    doc(problemAnswerDb, 'users', secondStudentId),
    {
      'progress.levelQuestionAnswers.1': {
        firstOperand: 17,
        secondOperand: 23,
        operation: '+',
        correctAnswer: 40,
      },
      'progress.latestLevelQuestionAnswerLevel': '1',
    },
  ));
  await assertFails(recordProblemLevelAttempt(
    noSessionStudentId,
    'no-session-answer',
    40,
    40,
  ));
  await assertSucceeds(updateDoc(
    doc(problemAnswerDb, 'users', problemAnswerStudentId),
    {
      'progress.levelQuestionAnswers.1': {
        firstOperand: 17,
        secondOperand: 23,
        operation: '+',
        correctAnswer: 40,
      },
      'progress.latestLevelQuestionAnswerLevel': '1',
    },
  ));
  const savedProblemProgress = (await getDoc(
    doc(problemAnswerDb, 'users', problemAnswerStudentId),
  )).data().progress;
  assert.equal(savedProblemProgress.levelQuestionAnswers['1'].correctAnswer, 40);
  assert.equal(savedProblemProgress.latestLevelQuestionAnswerLevel, '1');
  const noLrnProblemAnswerDb = testEnv.authenticatedContext(
    noLrnProblemAnswerStudentId,
  ).firestore();
  await assertSucceeds(recordProblemLevelAttempt(
    noLrnProblemAnswerStudentId,
    'registered-profile-correct-answer',
    4,
    4,
    { question: '1 + 3 = ?' },
  ));
  await assertSucceeds(recordProblemLevelAttempt(
    noLrnProblemAnswerStudentId,
    'registered-profile-incorrect-answer',
    5,
    4,
    { question: '1 + 3 = ?' },
  ));
  const noLrnAttemptRef = doc(
    noLrnProblemAnswerDb,
    'users',
    noLrnProblemAnswerStudentId,
    'problemLevelAttempts',
    'registered-profile-correct-answer',
  );
  const noLrnIncorrectAttemptRef = doc(
    noLrnProblemAnswerDb,
    'users',
    noLrnProblemAnswerStudentId,
    'problemLevelAttempts',
    'registered-profile-incorrect-answer',
  );
  const noLrnCorrectAttempt = (await getDoc(noLrnAttemptRef)).data();
  const noLrnIncorrectAttempt = (await getDoc(noLrnIncorrectAttemptRef)).data();
  assert.equal(noLrnCorrectAttempt.question, '1 + 3 = ?');
  assert.equal(noLrnCorrectAttempt.selectedAnswer, 4);
  assert.equal(noLrnCorrectAttempt.isCorrect, true);
  assert.equal(noLrnIncorrectAttempt.question, '1 + 3 = ?');
  assert.equal(noLrnIncorrectAttempt.selectedAnswer, 5);
  assert.equal(noLrnIncorrectAttempt.isCorrect, false);
  await assertSucceeds(updateDoc(
    doc(noLrnProblemAnswerDb, 'users', noLrnProblemAnswerStudentId),
    {
      'progress.levelQuestionAnswers.1': {
        firstOperand: 1,
        secondOperand: 3,
        operation: '+',
        correctAnswer: 4,
      },
      'progress.latestLevelQuestionAnswerLevel': '1',
    },
  ));
  await assertSucceeds(updateDoc(
    doc(noLrnProblemAnswerDb, 'users', noLrnProblemAnswerStudentId),
    {
      'progress.levelQuestionAnswers.2': {
        firstOperand: 1,
        secondOperand: 3,
        operation: '+',
        correctAnswer: 4,
      },
      'progress.latestLevelQuestionAnswerLevel': '2',
    },
  ));
  const noLrnSavedProfile = (await getDoc(
    doc(noLrnProblemAnswerDb, 'users', noLrnProblemAnswerStudentId),
  )).data();
  assert.equal(
    noLrnSavedProfile.progress.levelQuestionAnswers['1'].correctAnswer,
    4,
  );
  assert.equal(
    noLrnSavedProfile.progress.levelQuestionAnswers['2'].correctAnswer,
    4,
  );
  assert.equal(
    noLrnSavedProfile.progress.latestLevelQuestionAnswerLevel,
    '2',
  );
  assert.equal(Object.hasOwn(noLrnSavedProfile, 'lrn'), false);
  console.log(
    'PASS: correct and incorrect Problem Stage attempts and repeated progress saves persist for active students without LRN.',
  );

  await saveGameModeAnswers(studentId);
  await recordClassroomAttempt(studentId, 'classroom-attempt-1');
  await recordClassroomAttempt(studentId, 'classroom-attempt-1');
  await recordClassroomAttempt(
    noLrnClassroomAttemptStudentId,
    'no-lrn-classroom-attempt-1',
  );
  await recordClassroomAttempt(
    noLrnClassroomAttemptStudentId,
    'no-lrn-classroom-attempt-1',
  );
  const noLrnClassroomDb =
    testEnv.authenticatedContext(noLrnClassroomAttemptStudentId).firestore();
  const noLrnClassroomProfile = (await getDoc(
    doc(noLrnClassroomDb, 'users', noLrnClassroomAttemptStudentId),
  )).data();
  assert.equal(noLrnClassroomProfile.progress.questAttempts, 1);
  assert.equal(
    noLrnClassroomProfile.progress.latestClassroomQuestAttemptId,
    'no-lrn-classroom-attempt-1',
  );
  assert.equal(Object.hasOwn(noLrnClassroomProfile, 'lrn'), false);
  assert.equal(
    (await getDoc(doc(
      noLrnClassroomDb,
      'users',
      noLrnClassroomAttemptStudentId,
      'classroomQuestAttempts',
      'no-lrn-classroom-attempt-1',
    ))).exists(),
    true,
  );
  console.log(
    'PASS: Classroom Quest attempt and counter save once on retry with no LRN.',
  );
  await completeGameMode(studentId, 60);
  await completeGameMode(studentId, 60);
  const secondStudentDb = testEnv.authenticatedContext(secondStudentId).firestore();
  await updateDoc(doc(secondStudentDb, 'users', secondStudentId), {
    'progress.levelQuestionAnswers.2': {
      firstOperand: 17,
      secondOperand: 23,
      operation: '+',
      correctAnswer: 40,
    },
    'progress.latestLevelQuestionAnswerLevel': '2',
  });
  await completeGameMode(secondStudentId, 60);
  await assertFails(completeGameMode(legacyProgressId, 60, 2));
  const deniedStoryDb =
    testEnv.authenticatedContext(legacyProgressId).firestore();
  const deniedStoryBefore = (await getDoc(
    doc(deniedStoryDb, 'users', legacyProgressId),
  )).data();
  assert.deepEqual(deniedStoryBefore.progress.completedLevels, []);
  assert.equal(deniedStoryBefore.progress.unlockedLevels, 1);
  assert.equal(
    deniedStoryBefore.progress.gameModeFinalScores['2'],
    undefined,
  );
  const deniedStoryAfter = (await getDoc(
    doc(deniedStoryDb, 'users', legacyProgressId),
  )).data();
  assert.deepEqual(deniedStoryAfter.progress.completedLevels, []);
  assert.equal(deniedStoryAfter.progress.unlockedLevels, 1);
  assert.equal(deniedStoryAfter.progress.gameModeFinalScores['2'], undefined);
  await completeGameMode(existingProgressStudentId, 60, 3);
  await completeGameMode(existingProgressStudentId, 60, 3);
  const completedStoryDb =
    testEnv.authenticatedContext(existingProgressStudentId).firestore();
  await assertFails(updateDoc(
    doc(completedStoryDb, 'users', existingProgressStudentId),
    {
      'progress.completedLevels': [1, 2, 3],
      'progress.unlockedLevels': 1,
      'progress.questAttempts': 0,
      'progress.maxUnlockedSubLevel': {
        '1': 4,
        '2': 1,
        '3': 1,
      },
    },
  ));
  const completedStoryUser = (await getDoc(
    doc(completedStoryDb, 'users', existingProgressStudentId),
  )).data();
  const completedStoryAward = (await getDoc(doc(
    completedStoryDb,
    'users',
    existingProgressStudentId,
    'scoreAwards',
    'game-mode-3',
  ))).data();
  assert.equal(completedStoryUser.progress.gameModeFinalScores['3'], 60);
  assert.deepEqual(completedStoryUser.progress.completedLevels, [1, 2, 3]);
  assert.equal(completedStoryAward.points, 60);
  console.log(
    'PASS: Story completion is committed once by Game Mode; retry is idempotent and the redundant completion write is denied.',
  );
  await assertFails(
    completeOfflineGameModeClaim(legacyProgressId, { level: 2 }),
  );
  await completeOfflineGameModeClaim(offlineClaimStudentId, { score: 65 });
  await completeOfflineGameModeClaim(offlineClaimStudentId, {
    claimId: 'offline-duplicate-retry',
    score: 65,
  });
  const offlineClaimDb =
    testEnv.authenticatedContext(offlineClaimStudentId).firestore();
  const offlineClaimUser = (await getDoc(
    doc(offlineClaimDb, 'users', offlineClaimStudentId),
  )).data();
  const offlineClaimAward = (await getDoc(doc(
    offlineClaimDb,
    'users',
    offlineClaimStudentId,
    'scoreAwards',
    'game-mode-1',
  ))).data();
  const offlineClaimLeaderboard = (await getDoc(
    doc(offlineClaimDb, 'leaderboard', offlineClaimStudentId),
  )).data();
  assert.equal(offlineClaimUser.progress.gameModeFinalScores['1'], 65);
  assert.deepEqual(
    offlineClaimUser.progress.completedNpcQuestionsByLevel['1'],
    questions,
  );
  assert.equal(offlineClaimUser.progress.maxUnlockedSubLevel['1'], 2);
  assert.equal(offlineClaimUser.scoreEarned, 65);
  assert.equal(offlineClaimAward.points, 65);
  assert.equal(
    offlineClaimAward.eventId,
    `offline-game-mode-${offlineClaimStudentId}-1`,
  );
  assert.equal(offlineClaimAward.schemaVersion, 1);
  assert.equal(offlineClaimLeaderboard.totalScore, 65);
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-duplicate-reward',
      score: 70,
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-invalid-module',
      level: 2,
      moduleId: 'integer-operations',
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-inflated-points',
      level: 2,
      points: 1000,
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-inflated-cumulative-score',
      level: 2,
      claimedGameScore: 1000,
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-invalid-claim-schema',
      level: 2,
      schemaVersion: 2,
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      authUid: attackerId,
      userId: offlineClaimStudentId,
      claimId: 'offline-wrong-owner',
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimPendingStudentId, {
      claimId: 'offline-unapproved',
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimNoSessionStudentId, {
      claimId: 'offline-no-session',
    }),
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimConflictStudentId, {
      claimId: 'offline-revoked-session',
    }),
  );
  await assertFails(getDoc(doc(
    testEnv.authenticatedContext(attackerId).firestore(),
    'users',
    offlineClaimStudentId,
    'scoreAwards',
    'game-mode-1',
  )));
  await completeOfflineGameModeClaim(offlineClaimStudentId, {
    claimId: 'offline-game-mode-level-2',
    level: 2,
  });
  const offlineClaimAfterLevelTwo = (await getDoc(
    doc(offlineClaimDb, 'users', offlineClaimStudentId),
  )).data();
  assert.equal(
    offlineClaimAfterLevelTwo.progress.gameModeFinalScores['2'],
    60,
  );
  assert.equal(
    offlineClaimAfterLevelTwo.progress.gameModeFinalScores['1'],
    65,
  );
  await assertFails(
    completeOfflineGameModeClaim(offlineClaimStudentId, {
      claimId: 'offline-game-mode-level-4-locked',
      level: 4,
    }),
  );
  console.log(
    'PASS: bounded offline completion claims validate approved ownership, active sessions, module/level progression, score bounds, and one-time rewards.',
  );
  await completeClassroomQuest(existingProgressStudentId, 37);
  await completeClassroomQuest(existingProgressStudentId, 37);
  await completeGameMode(maxProgressStudentId, 60, 60);
  await completeGameMode(legacyLeaderboardStudentId, 60);
  await completeGameMode(legacyStringScoreStudentId, 60);
  await completeGameMode(missingScoreFieldsStudentId, 60);
  await completeGameMode(stringLevelProgressStudentId, 60, 3);
  const concurrentCompletionId =
    `classroom-completion-${newClassroomCompletionStudentId}`;
  for (let questionNumber = 1; questionNumber <= 3; questionNumber++) {
    await recordClassroomAttempt(
      newClassroomCompletionStudentId,
      `${concurrentCompletionId}-answer-${questionNumber}`,
      questionNumber,
    );
  }
  const concurrentResults = await Promise.allSettled([
    completeClassroomQuest(newClassroomCompletionStudentId, 24, {
      recordAttempts: false,
    }),
    completeClassroomQuest(newClassroomCompletionStudentId, 24, {
      recordAttempts: false,
    }),
  ]);
  const successfulCompletions = concurrentResults.filter(
    (result) => result.status === 'fulfilled',
  ).length;
  assert.ok(successfulCompletions >= 1 && successfulCompletions <= 2);
  await completeClassroomQuest(newClassroomCompletionStudentId, 24, {
    recordAttempts: false,
  });
  await assertFails(
    completeClassroomQuest(
      rejectedClassroomCompletionStudentId,
      24,
      { correctAnswers: 2, totalQuestions: 2 },
    ),
  );

  const levelQuestionAwardDb =
    testEnv.authenticatedContext(levelQuestionAwardStudentId).firestore();
  await assertFails(setDoc(
    doc(levelQuestionAwardDb, 'leaderboard', levelQuestionAwardStudentId),
    {
      uid: levelQuestionAwardStudentId,
      displayName: levelQuestionAwardStudentId,
      totalScore: 10,
      createdAt: timestamp,
      updatedAt: serverTimestamp(),
    },
  ));
  await assertSucceeds(setDoc(
    doc(levelQuestionAwardDb, 'leaderboard', levelQuestionAwardStudentId),
    {
      uid: levelQuestionAwardStudentId,
      displayName: levelQuestionAwardStudentId,
      totalScore: 0,
      createdAt: timestamp,
      updatedAt: serverTimestamp(),
    },
  ));
  await Promise.all([
    awardLevelQuestionPoints(levelQuestionAwardStudentId, 1),
    awardLevelQuestionPoints(levelQuestionAwardStudentId, 1),
  ]);
  console.log('PASS: concurrent level question awards');
  await awardLevelQuestionPoints(levelQuestionAwardStudentId, 1);
  const noAnswerDb = testEnv.authenticatedContext(attackerId).firestore();
  await assertFails(setDoc(
    doc(noAnswerDb, 'users', attackerId, 'scoreAwards', '1'),
    { points: 10, createdAt: serverTimestamp() },
  ));
  await Promise.all([
    awardMissionPoints(levelQuestionAwardStudentId, 5, 'bird-1'),
    awardMissionPoints(levelQuestionAwardStudentId, 5, 'bird-1'),
  ]);
  console.log('PASS: concurrent mission awards');
  await completeNpcQuestion(npcProgressStudentId, 1);
  console.log('PASS: concurrent NPC progress writes');
  await completeNpcQuestion(npcProgressStudentId, 1);
  await completeNpcQuestion(noLrnNpcProgressStudentId, 1);
  const noLrnNpcDb =
    testEnv.authenticatedContext(noLrnNpcProgressStudentId).firestore();
  const noLrnNpcProgress = (await getDoc(
    doc(noLrnNpcDb, 'users', noLrnNpcProgressStudentId),
  )).data().progress;
  assert.deepEqual(noLrnNpcProgress.completedNpcQuestions, [1]);
  assert.deepEqual(noLrnNpcProgress.completedNpcQuestionsByLevel['1'], [1]);
  assert.equal(
    noLrnNpcProgress.latestCompletedNpcQuestionLevel,
    '1',
  );
  assert.equal(
    Object.hasOwn(
      (await getDoc(
        doc(noLrnNpcDb, 'users', noLrnNpcProgressStudentId),
      )).data(),
      'lrn',
    ),
    false,
  );
  console.log('PASS: Game Mode NPC progress saves for an approved student with no LRN.');
  for (let questionNumber = 1; questionNumber <= 6; questionNumber++) {
    await completeNpcQuestion(
      sequentialNpcStudentId,
      questionNumber,
      1,
    );
  }
  await completeNpcQuestion(sequentialNpcStudentId, 4, 1);
  for (let questionNumber = 1; questionNumber <= 6; questionNumber++) {
    await completeNpcQuestion(
      sequentialNpcStudentId,
      questionNumber,
      2,
    );
  }
  await completeNpcQuestion(sequentialNpcStudentId, 6, 2);
  const sequentialNpcDb =
    testEnv.authenticatedContext(sequentialNpcStudentId).firestore();
  await assertFails(updateDoc(doc(sequentialNpcDb, 'users', sequentialNpcStudentId), {
    'progress.completedNpcQuestions': [3],
    'progress.completedNpcQuestionsByLevel': {'1': [3]},
    'progress.latestCompletedNpcQuestionLevel': '1',
  }));
  await assertFails(updateDoc(doc(sequentialNpcDb, 'users', sequentialNpcStudentId), {
    'progress.completedNpcQuestions': [1, 2, 3, 4, 5, 6, 7],
    'progress.completedNpcQuestionsByLevel': {'1': [1, 2, 3, 4, 5, 6, 7]},
    'progress.latestCompletedNpcQuestionLevel': '1',
  }));
  const pendingStudentDb =
    testEnv.authenticatedContext(pendingStudentId).firestore();
  await assertFails(updateDoc(doc(pendingStudentDb, 'users', pendingStudentId), {
    'progress.completedNpcQuestions': [1],
    'progress.completedNpcQuestionsByLevel': {'1': [1]},
    'progress.latestCompletedNpcQuestionLevel': '1',
  }));
  await assertFails(updateDoc(doc(sequentialNpcDb, 'users', npcProgressStudentId), {
    'progress.completedNpcQuestions': [1, 2],
    'progress.completedNpcQuestionsByLevel': {'1': [1, 2]},
    'progress.latestCompletedNpcQuestionLevel': '1',
  }));
  await assertSucceeds(updateDoc(doc(sequentialNpcDb, 'users', sequentialNpcStudentId), {
    'progress.completedNpcQuestionsByLevel.2': deleteField(),
  }));
  await assertFails(updateDoc(doc(sequentialNpcDb, 'users', sequentialNpcStudentId), {
    'progress.completedNpcQuestionsByLevel.1': deleteField(),
  }));
  await assertFails(
    completeNpcQuestion(noSessionStudentId, 1),
  );
  console.log('PASS: sequential NPC questions 1-6 save for multiple levels');
  console.log('PASS: NPC save retries are idempotent and preserve progress');
  console.log('PASS: invalid question sequences and unauthorized NPC writes are rejected');
  console.log('PASS: NPC resets use the separately validated reset rule');
  console.log('PASS: Game Mode progress requires an active session');
  await assertFails(setDoc(
    doc(
      levelQuestionAwardDb,
      'users',
      levelQuestionAwardStudentId,
      'scoreAwards',
      'mission-invalid',
    ),
    { points: 15, createdAt: serverTimestamp() },
  ));
  const levelQuestionAwardEntry = (await getDoc(
    doc(levelQuestionAwardDb, 'leaderboard', levelQuestionAwardStudentId),
  )).data();
  const levelQuestionAward = (await getDoc(
    doc(levelQuestionAwardDb, 'users', levelQuestionAwardStudentId, 'scoreAwards', '1'),
  )).data();
  const npcProgressDb = testEnv.authenticatedContext(npcProgressStudentId).firestore();
  const npcProgress = (await getDoc(
    doc(npcProgressDb, 'users', npcProgressStudentId),
  )).data();
  assert.equal(levelQuestionAwardEntry.totalScore, 15);
  assert.equal(levelQuestionAward.points, 10);
  assert.deepEqual(npcProgress.progress.completedNpcQuestions, [1]);
  assert.deepEqual(npcProgress.progress.completedNpcQuestionsByLevel, {
    '1': [1],
  });

  const db = testEnv.authenticatedContext(studentId).firestore();
  const user = (await getDoc(doc(db, 'users', studentId))).data();
  const createdEntry =
    (await getDoc(doc(db, 'leaderboard', studentId))).data();
  const scoreAward = (await getDoc(
    doc(db, 'users', studentId, 'scoreAwards', 'game-mode-1'),
  )).data();
  const updatedEntry =
    (await getDoc(doc(secondStudentDb, 'leaderboard', secondStudentId))).data();
  const secondStudent =
    (await getDoc(doc(secondStudentDb, 'users', secondStudentId))).data();
  const existingProgressDb =
    testEnv.authenticatedContext(existingProgressStudentId).firestore();
  const existingProgress = (await getDoc(
    doc(existingProgressDb, 'users', existingProgressStudentId),
  )).data();
  const existingLeaderboard = (await getDoc(
    doc(existingProgressDb, 'leaderboard', existingProgressStudentId),
  )).data();
  const maxProgressDb =
    testEnv.authenticatedContext(maxProgressStudentId).firestore();
  const maxProgress = (await getDoc(
    doc(maxProgressDb, 'users', maxProgressStudentId),
  )).data();
  const maxProgressLeaderboard = (await getDoc(
    doc(maxProgressDb, 'leaderboard', maxProgressStudentId),
  )).data();
  const stringLevelDb =
    testEnv.authenticatedContext(stringLevelProgressStudentId).firestore();
  const stringLevelUser = (await getDoc(
    doc(stringLevelDb, 'users', stringLevelProgressStudentId),
  )).data();
  const legacyLeaderboardDb =
    testEnv.authenticatedContext(legacyLeaderboardStudentId).firestore();
  const legacyLeaderboard = (await getDoc(
    doc(legacyLeaderboardDb, 'leaderboard', legacyLeaderboardStudentId),
  )).data();
  const legacyStringScoreDb =
    testEnv.authenticatedContext(legacyStringScoreStudentId).firestore();
  const legacyStringScoreLeaderboard = (await getDoc(
    doc(legacyStringScoreDb, 'leaderboard', legacyStringScoreStudentId),
  )).data();
  const newClassroomDb =
    testEnv.authenticatedContext(newClassroomCompletionStudentId).firestore();
  const newClassroomUser = (await getDoc(
    doc(newClassroomDb, 'users', newClassroomCompletionStudentId),
  )).data();
  const newClassroomLeaderboard = (await getDoc(
    doc(newClassroomDb, 'leaderboard', newClassroomCompletionStudentId),
  )).data();
  const newClassroomAward = (await getDoc(doc(
    newClassroomDb,
    'users',
    newClassroomCompletionStudentId,
    'scoreAwards',
    `classroom-quest-${classroomQuestDayKey()}`,
  ))).data();
  const rejectedClassroomDb =
    testEnv.authenticatedContext(rejectedClassroomCompletionStudentId).firestore();
  const rejectedClassroomUser = (await getDoc(
    doc(rejectedClassroomDb, 'users', rejectedClassroomCompletionStudentId),
  )).data();
  const missingScoreDb =
    testEnv.authenticatedContext(missingScoreFieldsStudentId).firestore();
  const missingScoreUser = (await getDoc(
    doc(missingScoreDb, 'users', missingScoreFieldsStudentId),
  )).data();
  const missingScoreLeaderboard = (await getDoc(
    doc(missingScoreDb, 'leaderboard', missingScoreFieldsStudentId),
  )).data();
  assert.equal(user.progress.gameModeFinalScores['1'], 60);
  assert.equal(user.progress.completedLevels.includes(1), true);
  assert.equal(user.scoreEarned, 60);
  assert.equal(user.gameScore, 60);
  assert.equal(user.progress.questAttempts, 1);
  assert.equal(createdEntry.totalScore, 60);
  assert.equal(scoreAward.points, 60);
  assert.equal(updatedEntry.totalScore, 95);
  assert.equal(secondStudent.progress.levelQuestionAnswers['2'].correctAnswer, 40);
  assert.deepEqual(existingProgress.progress.completedLevels, [1, 2, 3]);
  assert.deepEqual(existingProgress.progress.gameModeFinalScores, {
    '1': 60,
    '2': 70,
    '3': 60,
  });
  assert.equal(existingProgress.scoreEarned, 220);
  assert.equal(existingProgress.gameScore, 245);
  assert.equal(existingLeaderboard.totalScore, 245);
  assert.equal(existingProgress.progress.classroomQuestHistory['previous-completion'].score, 30);
  assert.equal(existingProgress.progress.classroomQuestHistory['classroom-completion-existing-progress-student'].score, 30);
  assert.equal(existingProgress.progress.classroomQuestResults.classroom_quest.status, 'completed');
  assert.equal(existingProgress.progress.classroomQuestResults.classroom_quest.correctAnswers, 3);
  assert.equal(existingProgress.progress.classroomQuestResults.classroom_quest.totalQuestions, 3);
  assert.equal(existingProgress.progress.classroomQuestResults.classroom_quest.score, 30);
  assert.equal(
    existingProgress.progress.classroomQuestResults.classroom_quest.completedAt
      instanceof Timestamp,
    true,
  );
  assert.equal(
    existingProgress.progress.classroomQuestHistory[
      'classroom-completion-existing-progress-student'
    ].completedAt instanceof Timestamp,
    true,
  );
  assert.equal(existingProgress.progress.classroomQuestCompletionTimes.classroom_quest, 37);
  assert.equal(maxProgress.progress.completedLevels.length, 60);
  assert.equal(maxProgress.progress.gameModeFinalScores['60'], 60);
  assert.equal(maxProgress.scoreEarned, 3600);
  assert.equal(maxProgress.gameScore, 3625);
  assert.equal(maxProgressLeaderboard.totalScore, 3625);
  assert.deepEqual(stringLevelUser.progress.completedLevels, ['1', '2', 3]);
  assert.equal(stringLevelUser.progress.gameModeFinalScores['3'], 60);
  assert.equal(Object.hasOwn(maxProgressLeaderboard, 'totalscore'), false);
  assert.equal(Object.hasOwn(maxProgressLeaderboard, 'displayname'), false);
  assert.equal(Object.hasOwn(maxProgressLeaderboard, 'name'), false);
  assert.equal(legacyLeaderboard.totalScore, 135);
  assert.equal(Object.hasOwn(legacyLeaderboard, 'totalscore'), false);
  assert.equal(Object.hasOwn(legacyLeaderboard, 'displayname'), false);
  assert.equal(Object.hasOwn(legacyLeaderboard, 'name'), false);
  assert.equal(legacyStringScoreLeaderboard.totalScore, 135);
  assert.equal(Object.hasOwn(legacyStringScoreLeaderboard, 'totalscore'), false);
  assert.equal(
    newClassroomUser.progress.classroomQuestResults.classroom_quest.score,
    30,
  );
  assert.equal(newClassroomUser.scoreEarned, 30);
  assert.equal(newClassroomUser.gameScore, 30);
  assert.equal(newClassroomLeaderboard.totalScore, 30);
  assert.equal(newClassroomAward.points, 30);
  assert.equal(
    Object.hasOwn(
      rejectedClassroomUser.progress.classroomQuestResults ?? {},
      'classroom_quest',
    ),
    false,
  );
  assert.equal(
    (await getDoc(doc(
      newClassroomDb,
      'users',
      newClassroomCompletionStudentId,
      'classroomQuestDailyCompletions',
      classroomQuestDayKey(),
    ))).exists(),
    true,
  );
  assert.equal(
    (await getDocs(collection(
      newClassroomDb,
      'users',
      newClassroomCompletionStudentId,
      'classroomQuestDailyCompletions',
    ))).size,
    1,
  );
  await assertFails(recordClassroomAttempt(
    newClassroomCompletionStudentId,
    'attempt-after-daily-completion',
  ));
  await assertFails(setDoc(doc(
    newClassroomDb,
    'users',
    newClassroomCompletionStudentId,
    'classroomQuestDailyCompletions',
    '2099-01-01',
  ), {
    uid: newClassroomCompletionStudentId,
    questId: 'classroom_quest',
    dayKey: '2099-01-01',
    completionId: 'forged-completion',
    questionIds: ['worksheet-1', 'worksheet-2', 'worksheet-3'],
    correctAttemptIds: ['a', 'b', 'c'],
    completionTimeSeconds: 24,
    correctAnswers: 3,
    totalQuestions: 3,
    score: 30,
    completedAt: serverTimestamp(),
  }));
  assert.equal(
    (await getDocs(collection(
      rejectedClassroomDb,
      'users',
      rejectedClassroomCompletionStudentId,
      'classroomQuestDailyCompletions',
    ))).size,
    0,
  );
  assert.equal(
    Object.keys(newClassroomUser.progress.classroomQuestHistory).length,
    1,
  );
  assert.equal(missingScoreUser.scoreEarned, 60);
  assert.equal(missingScoreUser.gameScore, 60);
  assert.equal(missingScoreLeaderboard.totalScore, 60);
  assert.equal((await getDoc(
    doc(db, 'users', studentId, 'gameModeAttempts', 'level-1-6'),
  )).exists(), true);

  const ownGameModeHistory = query(
    collection(db, 'users', studentId, 'gameModeAttempts'),
    orderBy('attemptedAt', 'desc'),
  );
  const ownClassroomHistory = query(
    collection(db, 'users', studentId, 'classroomQuestAttempts'),
    orderBy('attemptedAt', 'desc'),
  );
  assert.equal((await assertSucceeds(getDocs(ownGameModeHistory))).size, 6);
  assert.equal((await assertSucceeds(getDocs(ownClassroomHistory))).size, 1);

  const teacherDb = testEnv.authenticatedContext(teacherId).firestore();
  assert.equal((await assertSucceeds(getDocs(query(
    collection(teacherDb, 'users', studentId, 'gameModeAttempts'),
    orderBy('attemptedAt', 'desc'),
  )))).size, 6);
  assert.equal((await assertSucceeds(getDocs(query(
    collection(teacherDb, 'users', studentId, 'classroomQuestAttempts'),
    orderBy('attemptedAt', 'desc'),
  )))).size, 1);
  await assertFails(getDocs(query(
    collection(db, 'users', secondStudentId, 'gameModeAttempts'),
    orderBy('attemptedAt', 'desc'),
  )));
  await assertFails(getDocs(query(
    collection(teacherDb, 'users', pendingStudentId, 'classroomQuestAttempts'),
    orderBy('attemptedAt', 'desc'),
  )));

  const attackerDb = testEnv.authenticatedContext(attackerId).firestore();
  await assertFails(updateDoc(doc(attackerDb, 'leaderboard', attackerId), {
    totalScore: 10,
    updatedAt: serverTimestamp(),
  }));
  assert.equal((await getDoc(
    doc(attackerDb, 'leaderboard', attackerId),
  )).data().totalScore, 0);
  await assertFails(updateDoc(doc(attackerDb, 'leaderboard', attackerId), {
    totalScore: 70,
    updatedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(doc(attackerDb, 'leaderboard', studentId), {
    totalScore: 1060,
    updatedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(doc(attackerDb, 'leaderboard', studentId), {
    profilePhotoUrl: 'assets/images/player/Pride Masc.png',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(setDoc(
    doc(db, 'users', studentId, 'scoreAwards', 'game-mode-2'),
    { points: 60, createdAt: serverTimestamp() },
  ));

  console.log('PASS: Game Mode creates and updates leaderboard with 60 points.');
  console.log(
    'PASS: Spark-compatible profile creation assigns UID-bound Student Nos. and rejects forged identities.',
  );
  console.log('PASS: retry does not duplicate user or leaderboard points.');
  console.log('PASS: Level Question score awards are limited to one award per level.');
  console.log('PASS: Level Question score awards require a saved correct answer.');
  console.log('PASS: mission score award retries are idempotent and limited to 5 or 10 points.');
  console.log('PASS: concurrent NPC progress saves commit one completion.');
  console.log('PASS: a new leaderboard entry must start at zero before awarding points.');
  console.log('PASS: existing scores, completed levels, and progress are preserved.');
  console.log('PASS: Game Mode completion works with 59 existing scores and levels.');
  console.log('PASS: missing legacy score fields initialize without overwriting progress.');
  console.log('PASS: numeric-string legacy leaderboard scores remain awardable.');
  console.log('PASS: Classroom Quest completion saves once and preserves prior history.');
  console.log('PASS: new-student Classroom Quest completion is idempotent.');
  console.log('PASS: daily completion is one-per-Manila-day and atomic across concurrent clients.');
  console.log('PASS: invalid Classroom Quest completion counts are rejected.');
  console.log('PASS: Stage Answer progress remains writable.');
  console.log('PASS: all six Game Mode answer documents remain writable.');
  console.log('PASS: Classroom Quest attempt and count save once on retry.');
  console.log('PASS: student and approved-teacher history reads are scoped correctly.');
  console.log('PASS: standalone score jumps, other owners, and unpaired awards are rejected.');
} finally {
  await testEnv.cleanup();
}