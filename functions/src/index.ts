import { createHash, randomUUID } from "node:crypto";

import { getAuth } from "firebase-admin/auth";
import { initializeApp } from "firebase-admin/app";
import { getStorage } from "firebase-admin/storage";
import {
  DocumentReference,
  DocumentSnapshot,
  FieldPath,
  FieldValue,
  Timestamp,
  Transaction,
  getFirestore,
} from "firebase-admin/firestore";
import {
  onDocumentDeleted,
  onDocumentWritten,
} from "firebase-functions/v2/firestore";
import {
  CallableRequest,
  HttpsError,
  onCall,
} from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

initializeApp();

const db = getFirestore();

const maximumLevel = 60;
const studentNumberCounterRef = db
  .collection("systemCounters")
  .doc("studentNumbers");
const studentNumberSchemaVersion = 2;
const studentNumberMigrationLeaseMs = 10 * 60 * 1000;

function profileImagePathForCharacter(character: unknown): string {
  switch (character) {
  case "girl":
    return "assets/images/player/girl.png";
  case "character3":
    return "assets/images/player/T-rex.png";
  case "character4":
    return "assets/images/player/Pride Femme.png";
  case "character5":
    return "assets/images/player/Pride Masc.png";
  default:
    return "assets/images/player/boy.png";
  }
}

function requireUid(request: CallableRequest<unknown>): string {
  const uid = request.auth?.uid;

  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in to continue.");
  }

  return uid;
}

function lrnIndexId(lrn: string): string {
  return createHash("sha256").update(lrn).digest("hex");
}

async function requireCurrentSession(
  request: CallableRequest<unknown>,
): Promise<string> {
  const uid = requireUid(request);

  const session = await db
    .collection("activeSessions")
    .doc(uid)
    .get();

  if (!session.exists) {
    throw new HttpsError(
      "permission-denied",
      "This device session is no longer active.",
    );
  }

  return uid;
}

function numericStudentNumber(value: unknown): number {
  if (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0
  ) {
    return value;
  }
  if (typeof value === "string" && /^\d+$/.test(value)) {
    const parsed = Number(value);
    if (Number.isSafeInteger(parsed)) return parsed;
  }
  return 0;
}

async function migrateStudentNumbers(): Promise<number> {
  const migrationToken = randomUUID();

  for (let attempt = 0; attempt < 1080; attempt++) {
    const state = await db.runTransaction(async (transaction) => {
      const counterSnapshot = await transaction.get(studentNumberCounterRef);
      const counter = counterSnapshot.data();
      if (
        counter?.schemaVersion === studentNumberSchemaVersion &&
        counter?.migrationState === "complete"
      ) {
        return "complete" as const;
      }

      const startedAt = counter?.migrationStartedAt;
      if (
        counter?.migrationState === "running" &&
        startedAt instanceof Timestamp &&
        Timestamp.now().toMillis() - startedAt.toMillis() <
          studentNumberMigrationLeaseMs
      ) {
        return "running" as const;
      }

      const previousNumber = counter?.lastNumber;
      transaction.set(studentNumberCounterRef, {
        lastNumber:
          typeof previousNumber === "number" &&
            Number.isSafeInteger(previousNumber) &&
            previousNumber >= 0
            ? previousNumber
            : 0,
        schemaVersion: studentNumberSchemaVersion,
        migrationState: "running",
        migrationToken,
        migrationStartedAt: Timestamp.now(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return "claimed" as const;
    });

    if (state === "complete") return 0;
    if (state === "running") {
      await new Promise((resolve) => setTimeout(resolve, 500));
      continue;
    }

    try {
      const studentsSnapshot = await db
        .collection("users")
        .where("role", "==", "student")
        .get();
      const highestExistingNumber = studentsSnapshot.docs.reduce(
        (highest, student) =>
          Math.max(highest, numericStudentNumber(student.data().studentNo)),
        0,
      );

      await db.runTransaction(async (transaction) => {
        const counterSnapshot = await transaction.get(studentNumberCounterRef);
        if (counterSnapshot.data()?.migrationToken !== migrationToken) {
          throw new HttpsError(
            "aborted",
            "Student No. migration ownership changed. Retry the operation.",
          );
        }
        const previousNumber = counterSnapshot.data()?.lastNumber;
        transaction.set(studentNumberCounterRef, {
          lastNumber: Math.max(
            highestExistingNumber,
            typeof previousNumber === "number" &&
                Number.isSafeInteger(previousNumber) &&
                previousNumber >= 0
              ? previousNumber
              : 0,
          ),
          schemaVersion: studentNumberSchemaVersion,
          migrationState: "complete",
          updatedAt: FieldValue.serverTimestamp(),
        });
      });
      return 0;
    } catch (error) {
      await db.runTransaction(async (transaction) => {
        const counterSnapshot = await transaction.get(studentNumberCounterRef);
        if (counterSnapshot.data()?.migrationToken === migrationToken) {
          transaction.set(studentNumberCounterRef, {
            ...counterSnapshot.data(),
            migrationState: "failed",
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      });
      throw error;
    }
  }

  throw new HttpsError(
    "deadline-exceeded",
    "Student No. migration is still running. Retry shortly.",
  );
}

async function allocateStudentNumber(
  transaction: Transaction,
  counterSnapshot: DocumentSnapshot,
): Promise<string> {
  const counter = counterSnapshot.data();
  const lastNumber = counter?.lastNumber;
  if (
    !counterSnapshot.exists ||
    counter?.schemaVersion !== studentNumberSchemaVersion ||
    counter?.migrationState !== "complete" ||
    !Number.isSafeInteger(lastNumber) ||
    lastNumber < 0
  ) {
    throw new HttpsError(
      "failed-precondition",
      "Student No. numbering is not ready. Retry after migration completes.",
    );
  }

  const nextNumber = lastNumber + 1;
  if (!Number.isSafeInteger(nextNumber)) {
    throw new HttpsError(
      "resource-exhausted",
      "No more Student No. values can be assigned.",
    );
  }
  const counterUpdate = {
    lastNumber: nextNumber,
    updatedAt: FieldValue.serverTimestamp(),
  };
  transaction.update(studentNumberCounterRef, counterUpdate);
  return String(nextNumber);
}

async function assignStudentNumber(uid: string): Promise<string | null> {
  const userRef = db.collection("users").doc(uid);
  return db.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    if (!userSnapshot.exists || userSnapshot.data()?.role !== "student") {
      return null;
    }
    const userData = userSnapshot.data()!;
    const currentNumber = userData.studentNo;
    if (typeof currentNumber === "string" && currentNumber.trim()) {
      return currentNumber;
    }
    if (currentNumber !== undefined && currentNumber !== null &&
        currentNumber !== "") {
      throw new HttpsError(
        "failed-precondition",
        "The saved Student No. has an invalid value.",
      );
    }

    const counterSnapshot = await transaction.get(studentNumberCounterRef);
    const studentNo = await allocateStudentNumber(
      transaction,
      counterSnapshot,
    );
    transaction.update(userRef, { studentNo });
    return studentNo;
  });
}

export const registerStudent = onCall(
  { timeoutSeconds: 540 },
  async (request) => {
    const uid = requireUid(request);
    let stage = "verify Firebase Authentication account";

    try {
    const authUser = await getAuth().getUser(uid);
    stage = "initialize the Student No. sequence";
    await migrateStudentNumbers();

    const name =
      typeof request.data?.name === "string"
        ? request.data.name.trim()
        : "";

    const address =
      typeof request.data?.address === "string"
        ? request.data.address.trim()
        : "";

    const allowedCharacters = new Set([
      "boy",
      "girl",
      "character3",
      "character4",
      "character5",
    ]);
    const character =
      typeof request.data?.character === "string" &&
      allowedCharacters.has(request.data.character)
        ? request.data.character
        : "boy";

    const email = authUser.email?.trim().toLowerCase();

    if (
      !email ||
      !name ||
      name.length > 100 ||
      !address ||
      address.length > 300
    ) {
      throw new HttpsError(
        "invalid-argument",
        "A valid name, address, and email are required.",
      );
    }

    const userRef = db.collection("users").doc(uid);

    let studentNo = "";
    stage = "atomically save the student profile and Student No.";
    await db.runTransaction(async (transaction) => {
      const [userSnapshot, counterSnapshot] = await Promise.all([
        transaction.get(userRef),
        transaction.get(studentNumberCounterRef),
      ]);

      if (userSnapshot.exists) {
        const existing = userSnapshot.data();
        if (existing?.email !== email || existing?.role !== "student") {
          throw new HttpsError(
            "already-exists",
            "This account is already registered.",
          );
        }
        if (existing.studentNo !== undefined &&
            existing.studentNo !== null &&
            existing.studentNo !== "") {
          if (typeof existing.studentNo !== "string" ||
              !existing.studentNo.trim()) {
            throw new HttpsError(
              "failed-precondition",
              "The saved Student No. has an invalid value.",
            );
          }
          studentNo = existing.studentNo;
          return;
        }
        studentNo = await allocateStudentNumber(
          transaction,
          counterSnapshot,
        );
        transaction.update(userRef, { studentNo });
        return;
      }

      studentNo = await allocateStudentNumber(transaction, counterSnapshot);

      transaction.create(userRef, {
        uid,
        email,
        role: "student",
        status: "pending",
        name,
        address,
        studentNo,
        character,
        profilePhotoUrl: profileImagePathForCharacter(character),
        tutorialEligible: true,
        tutorialCompleted: false,
        createdAt: FieldValue.serverTimestamp(),
      });
    });

    return {
      registered: true,
      studentNo,
    };
    } catch (error) {
      if (error instanceof HttpsError) throw error;

      const errorCode =
        error && typeof error === "object" && "code" in error
          ? String(error.code)
          : "unknown";
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      logger.error("Student registration failed.", {
        uid,
        stage,
        errorCode,
        errorMessage,
        errorStack: error instanceof Error ? error.stack : undefined,
      });

      if (
        errorCode === "unavailable" ||
        errorCode === "deadline-exceeded" ||
        errorCode === "aborted"
      ) {
        throw new HttpsError(
          "unavailable",
          "Registration could not reach Firebase reliably. Your account is safe; retry with the same email and password.",
        );
      }
      if (errorCode === "auth/user-not-found") {
        throw new HttpsError(
          "unauthenticated",
          "The sign-in account could not be verified. Sign in again and retry.",
        );
      }
      throw new HttpsError(
        "internal",
        `Registration failed while attempting to ${stage} ` +
          `(backend code: ${errorCode}). Retry with the same email and password. ` +
          "If this continues, contact support with the time of the attempt.",
      );
    }
  },
);

export const ensureStudentNumber = onCall(async (request) => {
  const uid = await requireCurrentSession(request);
  await migrateStudentNumbers();
  const user = await db.collection("users").doc(uid).get();
  if (user.data()?.role !== "student") {
    throw new HttpsError(
      "failed-precondition",
      "Only student accounts can receive a Student No.",
    );
  }
  const studentNo = await assignStudentNumber(uid);
  if (!studentNo) {
    throw new HttpsError(
      "not-found",
      "The student profile could not be found.",
    );
  }
  return { studentNo };
});

export const ensureStudentNumbers = onCall(
  { timeoutSeconds: 540 },
  async (request) => {
    const uid = await requireCurrentSession(request);
    const admin = await db.collection("users").doc(uid).get();
    if (
      admin.data()?.role !== "admin" ||
      admin.data()?.status !== "approved"
    ) {
      throw new HttpsError(
        "permission-denied",
        "Only an approved administrator can migrate Student No. values.",
      );
    }

    const assigned = await migrateStudentNumbers();
    return { assigned };
  },
);

export const deleteStudentAccount = onCall(async (request) => {
  const adminUid = await requireCurrentSession(request);
  const adminSnapshot = await db.collection("users").doc(adminUid).get();
  if (
    adminSnapshot.data()?.role !== "admin" ||
    adminSnapshot.data()?.status !== "approved"
  ) {
    throw new HttpsError(
      "permission-denied",
      "Only an approved administrator can delete accounts.",
    );
  }

  const targetUid =
    typeof request.data?.uid === "string" ? request.data.uid.trim() : "";
  if (!targetUid || targetUid === adminUid || targetUid.includes("/")) {
    throw new HttpsError("invalid-argument", "A valid account UID is required.");
  }

  const userRef = db.collection("users").doc(targetUid);
  const targetSnapshot = await userRef.get();
  const target = targetSnapshot.data();
  if (
    targetSnapshot.exists &&
    !["student", "teacher"].includes(String(target?.role).toLowerCase())
  ) {
    throw new HttpsError(
      "permission-denied",
      "Administrator accounts cannot be deleted here.",
    );
  }

  let authenticationAccountExists = false;
  let authenticationAccountCouldNotBeVerified = false;
  if (!targetSnapshot.exists) {
    try {
      await getAuth().getUser(targetUid);
      authenticationAccountExists = true;
    } catch (error) {
      if (typeof error === "object" &&
        error !== null &&
        "code" in error &&
        error.code === "auth/user-not-found") {
        authenticationAccountExists = false;
      } else {
        authenticationAccountCouldNotBeVerified = true;
        logger.error("Unable to verify the Authentication account", {
          uid: targetUid,
          error,
        });
      }
    }
  }

  const cleanupErrors: unknown[] = [];
  const activeSessionRef = db.collection("activeSessions").doc(targetUid);
  try {
    await activeSessionRef.delete();
  } catch (error) {
    cleanupErrors.push(error);
    logger.error("Unable to remove the account's active session", {
      uid: targetUid,
      error,
    });
  }

  const userCollections = await userRef.listCollections().catch((error) => {
    cleanupErrors.push(error);
    logger.error("Unable to list the account's subcollections", {
      uid: targetUid,
      error,
    });
    return [];
  });
  const cleanupTasks: Promise<unknown>[] = [
    db.recursiveDelete(db.collection("leaderboard").doc(targetUid)),
    deleteLegacyProfilePhoto(targetUid, target?.profilePhotoUrl),
    deleteLrnIndexesForUid(
      targetUid,
      typeof target?.lrn === "string" ? target.lrn.trim() : "",
    ),
    ...userCollections.map((collection) => db.recursiveDelete(collection)),
  ];
  const cleanupResults = await Promise.allSettled(cleanupTasks);
  for (const result of cleanupResults) {
    if (result.status === "rejected") {
      cleanupErrors.push(result.reason);
    }
  }
  if (cleanupErrors.length > 0) {
    logger.error("Some account data could not be removed", {
      uid: targetUid,
      errors: cleanupErrors,
    });
    throw new HttpsError(
      "internal",
      "Some account data could not be removed. Retry the deletion.",
    );
  }

  if (authenticationAccountCouldNotBeVerified) {
    throw new HttpsError(
      "internal",
      "The Authentication account could not be verified. Retry the deletion.",
    );
  }
  if (!targetSnapshot.exists && authenticationAccountExists) {
    throw new HttpsError(
      "failed-precondition",
      "The account profile is missing, so its role cannot be verified.",
    );
  }

  if (targetSnapshot.exists) {
    try {
      await getAuth().deleteUser(targetUid);
    } catch (error) {
      const authenticationUserWasAlreadyRemoved =
        typeof error === "object" &&
        error !== null &&
        "code" in error &&
        error.code === "auth/user-not-found";
      if (!authenticationUserWasAlreadyRemoved) {
        logger.error("Unable to delete the Firebase Authentication account", {
          uid: targetUid,
          error,
        });
        throw new HttpsError(
          "internal",
          "The Authentication account could not be deleted. Retry the deletion.",
        );
      }
    }
  }

  if (targetSnapshot.exists) {
    await db.runTransaction(async (transaction) => {
      const currentSnapshot = await transaction.get(userRef);
      if (!currentSnapshot.exists) return;

      const counterSnapshot = await transaction.get(studentNumberCounterRef);
      const currentTarget = currentSnapshot.data()!;
      let remainingStudents: DocumentSnapshot[] = [];
      if (currentTarget.role === "student") {
        const students = await transaction.get(
          db.collection("users").where("role", "==", "student"),
        );
        remainingStudents = students.docs.filter(
          (student) => student.id !== targetUid,
        );
      }

      transaction.delete(userRef);
      if (
        currentTarget.role === "student" &&
        remainingStudents.length === 0 &&
        counterSnapshot.exists &&
        counterSnapshot.data()?.migrationState === "complete"
      ) {
        transaction.update(studentNumberCounterRef, {
          lastNumber: 0,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    });
  }

  return { deleted: true };
});

async function deleteLegacyProfilePhoto(
  uid: string,
  photoUrl: unknown,
): Promise<void> {
  if (
    typeof photoUrl !== "string" ||
    (!photoUrl.startsWith("gs://") &&
      !photoUrl.startsWith("https://firebasestorage.googleapis.com/"))
  ) {
    return;
  }

  await getStorage()
    .bucket()
    .file(`profiles/${uid}/profile-photo`)
    .delete({ ignoreNotFound: true });
}

async function deleteLrnIndexesForUid(
  uid: string,
  lrn: string,
): Promise<void> {
  const refs = new Map<string, DocumentReference>();
  const matchingIndexes = await db
    .collection("lrnIndexes")
    .where("uid", "==", uid)
    .get();
  for (const snapshot of matchingIndexes.docs) {
    refs.set(snapshot.ref.path, snapshot.ref);
  }

  if (/^\d{12}$/.test(lrn)) {
    const candidates = [
      db.collection("lrnIndexes").doc(lrnIndexId(lrn)),
      db.collection("lrnIndexes").doc(lrn),
    ];
    const snapshots = await Promise.all(
      candidates.map((reference) => reference.get()),
    );
    for (const [index, snapshot] of snapshots.entries()) {
      if (snapshot.data()?.uid === uid) {
        refs.set(snapshot.ref.path, candidates[index]);
      }
    }
  }

  await Promise.all(Array.from(refs.values(), (reference) => reference.delete()));
}

export const completeFirstTimeTutorial = onCall(async (request) => {
  const uid = await requireCurrentSession(request);
  const userRef = db.collection("users").doc(uid);
  const userSnapshot = await userRef.get();
  const user = userSnapshot.data();

  if (!userSnapshot.exists || user?.tutorialEligible !== true) {
    throw new HttpsError(
      "failed-precondition",
      "This account is not eligible for the first-time tutorial.",
    );
  }

  if (user.tutorialCompleted !== true) {
    await userRef.update({
      tutorialCompleted: true,
    });
  }

  return { completed: true };
});

export const getTeacherAnalytics = onCall(async (request) => {
  let stage = "verify teacher session and role";
  try {
    const uid = await requireCurrentSession(request);
    const teacherSnapshot = await db.collection("users").doc(uid).get();
    const teacher = teacherSnapshot.data();

    if (
      !teacherSnapshot.exists ||
      teacher?.role !== "teacher" ||
      teacher.status !== "approved"
    ) {
      throw new HttpsError(
        "permission-denied",
        "Only approved teacher accounts can view student analytics.",
      );
    }

    stage = "query student profiles";
    const studentsSnapshot = await db
      .collection("users")
      .where("role", "==", "student")
      .select(
        "name",
        "status",
        "gameScore",
        "scoreBaseline",
        "scoreEarned",
        "progress",
      )
      .get();
    stage = "parse student progress";
    const students = studentsSnapshot.docs.map((studentSnapshot) => {
      const student = studentSnapshot.data();

    const rawProgress = student.progress;
    const hasProgressRecord =
      rawProgress !== null &&
      typeof rawProgress === "object" &&
      !Array.isArray(rawProgress) &&
      Object.keys(rawProgress).length > 0;
    const progress = hasProgressRecord
      ? (rawProgress as Record<string, unknown>)
        : {};
    const legacyScore =
      typeof student.scoreBaseline === "number" &&
      Number.isSafeInteger(student.scoreBaseline) &&
      student.scoreBaseline >= 0 &&
      typeof student.scoreEarned === "number" &&
      Number.isSafeInteger(student.scoreEarned) &&
      student.scoreEarned >= 0
        ? student.scoreBaseline + student.scoreEarned
        : null;
    const completedLevels = Array.isArray(progress.completedLevels)
      ? [
          ...new Set(
            progress.completedLevels.filter(
              (level): level is number =>
                typeof level === "number" &&
                Number.isInteger(level) &&
                level >= 1 &&
                level <= maximumLevel,
            ),
          ),
        ].sort((first, second) => first - second)
      : [];
    const gameModeScores: Record<string, number> = {};
    const rawGameModeScores = progress.gameModeFinalScores;
    if (
      rawGameModeScores !== null &&
      typeof rawGameModeScores === "object" &&
      !Array.isArray(rawGameModeScores)
    ) {
      for (const [level, score] of Object.entries(rawGameModeScores)) {
        const levelNumber = Number(level);
        if (
          Number.isInteger(levelNumber) &&
          levelNumber >= 1 &&
          levelNumber <= maximumLevel &&
          typeof score === "number" &&
          Number.isInteger(score) &&
          score >= 0 &&
          score <= 70
        ) {
          gameModeScores[level] = score;
        }
      }
    }

    const rawQuestResults = progress.classroomQuestResults;
    const questResults =
      rawQuestResults !== null &&
      typeof rawQuestResults === "object" &&
      !Array.isArray(rawQuestResults)
        ? (rawQuestResults as Record<string, unknown>)
        : {};
    const rawQuest = questResults.classroom_quest;
    const quest =
      rawQuest !== null &&
      typeof rawQuest === "object" &&
      !Array.isArray(rawQuest)
        ? (rawQuest as Record<string, unknown>)
        : null;
    const rawCompletionTimes = progress.classroomQuestCompletionTimes;
    const completionTimes =
      rawCompletionTimes !== null &&
      typeof rawCompletionTimes === "object" &&
      !Array.isArray(rawCompletionTimes)
        ? (rawCompletionTimes as Record<string, unknown>)
        : {};
    const completionTime = completionTimes.classroom_quest;
    const savedCompletionTime =
      typeof completionTime === "number" &&
      Number.isSafeInteger(completionTime) &&
      completionTime >= 0
        ? completionTime
        : null;

    const legacyNpcQuestions = Array.isArray(progress.completedNpcQuestions)
      ? progress.completedNpcQuestions.filter(
          (question): question is number =>
            typeof question === "number" &&
            Number.isInteger(question) &&
            question >= 1 &&
            question <= 6,
        )
      : [];
    const rawNpcByLevel = progress.completedNpcQuestionsByLevel;
    const npcByLevel =
      rawNpcByLevel !== null &&
      typeof rawNpcByLevel === "object" &&
      !Array.isArray(rawNpcByLevel)
        ? (rawNpcByLevel as Record<string, unknown>)
        : {};
    const completedNpcQuestionCount = Object.entries(npcByLevel).reduce(
      (count, [level, questions]) => {
        if (level === "1" || !Array.isArray(questions)) {
          return count;
        }
        return (
          count +
          new Set(
            questions.filter(
              (question): question is number =>
                typeof question === "number" &&
                Number.isInteger(question) &&
                question >= 1 &&
                question <= 6,
            ),
          ).size
        );
      },
      Object.prototype.hasOwnProperty.call(npcByLevel, "1")
        ? 0
        : new Set(legacyNpcQuestions).size,
    );
    const savedScore =
      typeof student.gameScore === "number" &&
      Number.isSafeInteger(student.gameScore) &&
      student.gameScore >= 0
        ? student.gameScore
        : legacyScore;

      return {
        uid: studentSnapshot.id,
        name:
          typeof student.name === "string" && student.name.trim()
            ? student.name.trim()
            : "Student",
        status: typeof student.status === "string" ? student.status : "unknown",
        hasProgressRecord,
        gameScore: savedScore,
        completedLevels,
        questAttempts:
          typeof progress.questAttempts === "number" &&
          Number.isSafeInteger(progress.questAttempts) &&
          progress.questAttempts >= 0
            ? progress.questAttempts
            : 0,
        classroomQuest:
          quest === null && savedCompletionTime === null
            ? null
            : {
                score:
                  typeof quest?.score === "number" &&
                  Number.isSafeInteger(quest.score) &&
                  quest.score >= 0
                    ? quest.score
                    : null,
                correctAnswers:
                  typeof quest?.correctAnswers === "number" &&
                  Number.isSafeInteger(quest.correctAnswers) &&
                  quest.correctAnswers >= 0
                    ? quest.correctAnswers
                    : null,
                totalQuestions:
                  typeof quest?.totalQuestions === "number" &&
                  Number.isSafeInteger(quest.totalQuestions) &&
                  quest.totalQuestions >= 0
                    ? quest.totalQuestions
                    : null,
                completionTimeSeconds:
                  typeof quest?.completionTimeSeconds === "number" &&
                  Number.isSafeInteger(quest.completionTimeSeconds) &&
                  quest.completionTimeSeconds >= 0
                    ? quest.completionTimeSeconds
                    : savedCompletionTime,
              },
        gameModeFinalScores: gameModeScores,
        completedNpcQuestionCount,
      };
    });
    students.sort((first, second) => first.name.localeCompare(second.name));

    logger.info("Teacher analytics loaded.", {
      studentCount: students.length,
      studentsWithProgress: students.filter((student) =>
        student.hasProgressRecord
      ).length,
    });
    return { students };
  } catch (error) {
    const errorCode =
      error instanceof HttpsError
        ? error.code
        : typeof error === "object" &&
            error !== null &&
            "code" in error &&
            typeof error.code === "string"
          ? error.code
          : "unexpected";
    logger.error("Teacher analytics request failed.", {
      stage,
      code: errorCode,
    });
    if (error instanceof HttpsError) throw error;
    throw new HttpsError(
      "internal",
      `Unable to load teacher analytics while attempting to ${stage}.`,
    );
  }
});

export const claimLoginSession = onCall(async (request) => {
  let stage = "validating login";

  try {
    const uid = requireUid(request);

    const deviceId = request.data?.deviceId;

    if (
      typeof deviceId !== "string" ||
      deviceId.length < 16 ||
      deviceId.length > 128
    ) {
      throw new HttpsError(
        "invalid-argument",
        "A valid device identifier is required.",
      );
    }

    stage = "checking the account profile";

    const user = await db
      .collection("users")
      .doc(uid)
      .get();

    const userData = user.data();

    if (
      !user.exists ||
      userData?.status !== "approved"
    ) {
      throw new HttpsError(
        "failed-precondition",
        "This account is not approved.",
      );
    }

    if (
      userData.role === "student" &&
      typeof userData.lrn === "string" &&
      /^\d{12}$/.test(userData.lrn.trim())
    ) {
      stage = "checking the account LRN";

      const duplicateLrns = await db
        .collection("users")
        .where("lrn", "==", userData.lrn.trim())
        .limit(2)
        .get();

      if (duplicateLrns.size > 1) {
        throw new HttpsError(
          "failed-precondition",
          "This LRN is assigned to multiple accounts. Ask an administrator to resolve the duplicate records.",
        );
      }
    }

    const sessionId = randomUUID();

    const sessionRef = db
      .collection("activeSessions")
      .doc(uid);

    const now = Date.now();

    stage = "claiming the device session";

    await db.runTransaction(async (transaction) => {
      const existing =
        await transaction.get(sessionRef);

      const data = existing.data();

      const expiry =
        data?.expiresAt instanceof Timestamp
          ? data.expiresAt.toMillis()
          : 0;

      const existingSessionIsActive =
        existing.exists &&
        (
          data?.persistent === true ||
          expiry > now
        );

      if (
        existingSessionIsActive &&
        data?.deviceId !== deviceId
      ) {
        throw new HttpsError(
          "permission-denied",
          "This account is already active on another device. Sign out there first.",
        );
      }

      transaction.set(sessionRef, {
        deviceId,
        sessionId,
        persistent: true,
        claimedAt: FieldValue.serverTimestamp(),
      });
    });

    stage =
      "updating Firebase Authentication session claims";

    const authUser =
      await getAuth().getUser(uid);

    try {
      await getAuth().setCustomUserClaims(uid, {
        ...authUser.customClaims,
        mathQuestSessionId: sessionId,
      });
    } catch (error) {
      await db.runTransaction(async (transaction) => {
        const current =
          await transaction.get(sessionRef);

        if (
          current.data()?.sessionId === sessionId
        ) {
          transaction.delete(sessionRef);
        }
      });

      throw error;
    }

    return {
      sessionId,
    };
  } catch (error) {
    logger.error(
      "Unable to establish a device login session.",
      {
        stage,
        code:
          error instanceof HttpsError
            ? error.code
            : "unexpected",
      },
    );

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError(
      "internal",
      `Unable to establish device session while ${stage}.`,
    );
  }
});

export const heartbeatLoginSession = onCall(
  async (request) => {
    const uid = requireUid(request);

    const sessionId =
      request.data?.sessionId;

    const deviceId =
      request.data?.deviceId;

    if (
      typeof sessionId !== "string" ||
      typeof deviceId !== "string"
    ) {
      throw new HttpsError(
        "invalid-argument",
        "A valid device session is required.",
      );
    }

    if (
      request.auth?.token.mathQuestSessionId !==
      sessionId
    ) {
      throw new HttpsError(
        "permission-denied",
        "This device session is no longer active.",
      );
    }

    const sessionRef = db
      .collection("activeSessions")
      .doc(uid);

    await db.runTransaction(async (transaction) => {
      const session =
        await transaction.get(sessionRef);

      if (
        !session.exists ||
        session.data()?.sessionId !== sessionId ||
        session.data()?.deviceId !== deviceId
      ) {
        throw new HttpsError(
          "permission-denied",
          "This device session is no longer active.",
        );
      }

      transaction.update(sessionRef, {
        lastSeenAt:
          FieldValue.serverTimestamp(),
      });
    });

    return {
      active: true,
    };
  },
);

export const releaseLoginSession = onCall(
  async (request) => {
    const uid = requireUid(request);

    const sessionId =
      request.data?.sessionId;

    const deviceId =
      request.data?.deviceId;

    if (
      typeof sessionId !== "string" ||
      typeof deviceId !== "string"
    ) {
      throw new HttpsError(
        "invalid-argument",
        "A valid device session is required.",
      );
    }

    const sessionRef = db
      .collection("activeSessions")
      .doc(uid);

    const released =
      await db.runTransaction(async (transaction) => {
        const session =
          await transaction.get(sessionRef);

        if (
          !session.exists ||
          session.data()?.sessionId !== sessionId ||
          session.data()?.deviceId !== deviceId
        ) {
          return false;
        }

        transaction.delete(sessionRef);

        return true;
      });

    if (released) {
      const authUser =
        await getAuth().getUser(uid);

      const claims = {
        ...authUser.customClaims,
      };

      if (
        claims.mathQuestSessionId ===
        sessionId
      ) {
        delete claims.mathQuestSessionId;

        await getAuth().setCustomUserClaims(
          uid,
          claims,
        );
      }
    }

    return {
      released,
    };
  },
);

export const clearLoginSession = onCall(
  async (request) => {
    const adminUid =
      await requireCurrentSession(request);

    const admin =
      await db
        .collection("users")
        .doc(adminUid)
        .get();

    if (admin.data()?.role !== "admin") {
      throw new HttpsError(
        "permission-denied",
        "Only admins can clear a login session.",
      );
    }

    const targetUid =
      request.data?.targetUid;

    if (
      typeof targetUid !== "string" ||
      targetUid.length === 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "A valid account UID is required.",
      );
    }

    if (targetUid === adminUid) {
      throw new HttpsError(
        "failed-precondition",
        "You cannot clear your own active session.",
      );
    }

    await db
      .collection("activeSessions")
      .doc(targetUid)
      .delete();

    try {
      const targetUser =
        await getAuth().getUser(targetUid);

      const claims = {
        ...targetUser.customClaims,
      };

      delete claims.mathQuestSessionId;

      await getAuth().setCustomUserClaims(
        targetUid,
        claims,
      );
    } catch (error) {
      if (
        !(
          error instanceof Error
        ) ||
        !("code" in error) ||
        error.code !== "auth/user-not-found"
      ) {
        throw error;
      }
    }

    return {
      cleared: true,
    };
  },
);

export const approveExistingAccountAsTeacher = onCall(
  async (request) => {
    let stage = "verifying the admin session";
    try {
      const adminUid = await requireCurrentSession(request);

      stage = "validating the target account UID";
      const targetUid = request.data?.targetUid;
      if (
        typeof targetUid !== "string" ||
        targetUid.trim().length === 0 ||
        targetUid.includes("/")
      ) {
        throw new HttpsError(
          "invalid-argument",
          "A valid account UID is required.",
        );
      }

      if (targetUid === adminUid) {
        throw new HttpsError(
          "failed-precondition",
          "An admin account cannot be converted to a teacher account.",
        );
      }

      stage = "verifying the target Firebase Authentication account";
      try {
        await getAuth().getUser(targetUid);
      } catch (error) {
        if (
          error instanceof Error &&
          "code" in error &&
          error.code === "auth/user-not-found"
        ) {
          throw new HttpsError(
            "failed-precondition",
            "The selected account has no matching Firebase Authentication user.",
          );
        }
        throw error;
      }

      const adminRef = db.collection("users").doc(adminUid);
      const targetRef = db.collection("users").doc(targetUid);
      stage = "reading admin and target Firestore profiles";
      const result = await db.runTransaction(async (transaction) => {
        const adminSnapshot = await transaction.get(adminRef);
        const targetSnapshot = await transaction.get(targetRef);

        if (adminSnapshot.data()?.role !== "admin") {
          throw new HttpsError(
            "permission-denied",
            "Only admins can approve teacher accounts.",
          );
        }
        if (!targetSnapshot.exists) {
          throw new HttpsError(
            "not-found",
            "The selected account was not found.",
          );
        }

        const target = targetSnapshot.data();
        if (target?.role === "teacher" && target.status === "approved") {
          return { approved: true, alreadyApproved: true };
        }

        if (
          target?.role !== "student" ||
          (target.status !== "pending" && target.status !== "approved")
        ) {
          throw new HttpsError(
            "failed-precondition",
            "Only an existing student account can be approved as a teacher.",
          );
        }

        transaction.update(targetRef, {
          role: "teacher",
          status: "approved",
        });
        return { approved: true, alreadyApproved: false };
      });

      return result;
    } catch (error) {
      if (error instanceof HttpsError) throw error;

      const errorMessage =
        error instanceof Error ? error.message : String(error);
      logger.error("Teacher account approval failed.", {
        stage,
        errorMessage,
        errorStack: error instanceof Error ? error.stack : undefined,
        errorCode:
          error && typeof error === "object" && "code" in error
            ? String(error.code)
            : "unknown",
      });
      throw new HttpsError(
        "internal",
        `Teacher approval failed while ${stage}: ${errorMessage}`,
      );
    }
  },
);

export const cleanupDeletedUser =
  onDocumentDeleted(
    "users/{uid}",
    async (event) => {
      const uid = event.params.uid;

      const userData =
        event.data?.data();

      const sessionRef =
        db
          .collection("activeSessions")
          .doc(uid);

      const batch = db.batch();

      batch.delete(sessionRef);

      const rawLrn =
        userData?.lrn;

      if (
        typeof rawLrn === "string" &&
        /^\d{12}$/.test(rawLrn.trim())
      ) {
        const normalizedLrn = rawLrn.trim();
        const lrnCollection = db.collection("lrnIndexes");
        const lrnRefs = [
          lrnCollection.doc(lrnIndexId(normalizedLrn)),
          lrnCollection.doc(normalizedLrn),
        ];
        const lrnSnapshots = await Promise.all(
          lrnRefs.map((reference) => reference.get()),
        );

        for (const [index, snapshot] of lrnSnapshots.entries()) {
          if (snapshot.data()?.uid === uid) {
            batch.delete(lrnRefs[index]);
          }
        }
      }

      await batch.commit();

      if (userData?.role === "student") {
        await db.runTransaction(async (transaction) => {
          const [studentsSnapshot, counterSnapshot] = await Promise.all([
            transaction.get(
              db.collection("users").where("role", "==", "student"),
            ),
            transaction.get(studentNumberCounterRef),
          ]);
          if (
            studentsSnapshot.empty &&
            counterSnapshot.data()?.migrationState === "complete" &&
            counterSnapshot.data()?.lastNumber !== 0
          ) {
            transaction.update(studentNumberCounterRef, {
              lastNumber: 0,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        });
      }
    },
  );

type ProgressScoreAward = {
  id: string;
  points: number;
};

function progressScoreAwards(
  userData: FirebaseFirestore.DocumentData | undefined,
): Map<string, ProgressScoreAward> {
  const progress = userData?.progress;
  const awards = new Map<string, ProgressScoreAward>();
  const finalScores = progress?.gameModeFinalScores;
  if (
    finalScores &&
    typeof finalScores === "object" &&
    !Array.isArray(finalScores)
  ) {
    for (const [rawLevel, rawScore] of Object.entries(
      finalScores as Record<string, unknown>,
    )) {
      const level = Number(rawLevel);
      if (
        !Number.isInteger(level) ||
        level < 1 ||
        level > maximumLevel ||
        typeof rawScore !== "number" ||
        !Number.isSafeInteger(rawScore) ||
        rawScore <= 0 ||
        rawScore > 70
      ) {
        continue;
      }

      const id = `game-mode-${level}`;
      awards.set(id, { id, points: rawScore });
    }
  }

  return awards;
}

async function reconcileProgressScoreAwards(uid: string): Promise<void> {
  const userRef = db.collection("users").doc(uid);

  await db.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    if (!userSnapshot.exists) return;

    const awards = [
      ...progressScoreAwards(userSnapshot.data()).values(),
    ];
    const awardCollection = userRef.collection("scoreAwards");
    const awardSnapshot = await transaction.get(awardCollection);
    const existingAwards = new Map(
      awardSnapshot.docs.map((document) => [document.id, document]),
    );
    const staleAwards = awardSnapshot.docs.filter(
      (document) =>
        document.id.startsWith("npc-") ||
        document.id.startsWith("game-level-"),
    );
    const unrecordedAwards = awards.filter(
      (award) => !existingAwards.has(award.id),
    );
    if (staleAwards.length === 0 && unrecordedAwards.length === 0) return;

    const userData = userSnapshot.data()!;
    const baseline = userData.scoreBaseline ?? 0;
    const earned = userData.scoreEarned ?? 0;
    if (
      !Number.isSafeInteger(baseline) ||
      baseline < 0 ||
      !Number.isSafeInteger(earned) ||
      earned < 0
    ) {
      throw new HttpsError(
        "failed-precondition",
        "The saved score data is invalid.",
      );
    }

    const stalePoints = staleAwards.reduce((total, award) => {
      const points = award.data().points;
      if (!Number.isSafeInteger(points) || points < 0) {
        throw new HttpsError(
          "failed-precondition",
          "The saved score award data is invalid.",
        );
      }
      return total + points;
    }, 0);
    const newEarned = earned - stalePoints +
      unrecordedAwards.reduce((total, award) => total + award.points, 0);
    if (newEarned < 0) {
      throw new HttpsError(
        "failed-precondition",
        "The saved score data is invalid.",
      );
    }
    const gameScore = baseline + newEarned;
    if (!Number.isSafeInteger(gameScore)) {
      throw new HttpsError(
        "out-of-range",
        "The saved score is outside the supported range.",
      );
    }

    for (const award of unrecordedAwards) {
      transaction.create(
        awardCollection.doc(award.id),
        {
          points: award.points,
          createdAt: FieldValue.serverTimestamp(),
        },
      );
    }
    for (const award of staleAwards) {
      transaction.delete(award.ref);
    }
    transaction.update(userRef, {
      scoreEarned: newEarned,
      gameScore,
    });
  });
}

async function updateLeaderboard(
  uid: string,
  userData: FirebaseFirestore.DocumentData,
) {
  const leaderboardRef =
    db
      .collection("leaderboard")
      .doc(uid);

  if (
    userData.role !== "student" ||
    userData.status !== "approved"
  ) {
    await leaderboardRef.delete();
    return;
  }

  const displayName =
    typeof userData.name === "string" &&
    userData.name.trim()
      ? userData.name
          .trim()
          .slice(0, 80)
      : "Player";

  const totalScore = userData.gameScore ?? 0;
  if (
    !Number.isSafeInteger(totalScore) ||
    totalScore < 0
  ) {
    throw new HttpsError(
      "failed-precondition",
      `The saved score for ${uid} is invalid.`,
    );
  }

  await leaderboardRef.set({
    uid,
    displayName,
    totalScore,
    profilePhotoUrl:
      typeof userData.profilePhotoUrl === "string" &&
        userData.profilePhotoUrl
        ? userData.profilePhotoUrl
        : profileImagePathForCharacter(userData.character),
    updatedAt:
      FieldValue.serverTimestamp(),
  });
}

export const completeGameMode = onCall(async (request) => {
  const uid = await requireCurrentSession(request);
  const level = request.data?.level;
  const score = request.data?.score;
  if (
    !Number.isInteger(level) ||
    level < 1 ||
    level > maximumLevel ||
    !Number.isInteger(score) ||
    score < 60 ||
    score > 70
  ) {
    throw new HttpsError(
      "invalid-argument",
      "A valid completed Game Mode level and score are required.",
    );
  }

  const userRef = db.collection("users").doc(uid);
  const leaderboardRef = db.collection("leaderboard").doc(uid);
  const awardRef = userRef.collection("scoreAwards").doc(`game-mode-${level}`);

  try {
    await db.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      if (!userSnapshot.exists) {
        throw new HttpsError("not-found", "User profile not found.");
      }
      const userData = userSnapshot.data()!;
      if (
        userData.role !== "student" ||
        userData.status !== "approved"
      ) {
        throw new HttpsError(
          "permission-denied",
          "Only approved student accounts can complete Game Mode levels.",
        );
      }

      const progress =
        userData.progress &&
        typeof userData.progress === "object" &&
        !Array.isArray(userData.progress)
          ? userData.progress as FirebaseFirestore.DocumentData
          : {};
      const finalScores =
        progress.gameModeFinalScores &&
        typeof progress.gameModeFinalScores === "object" &&
        !Array.isArray(progress.gameModeFinalScores)
          ? progress.gameModeFinalScores as Record<string, unknown>
          : {};
      const existingScore = finalScores[String(level)];
      if (existingScore !== undefined) {
        if (existingScore !== score) {
          throw new HttpsError(
            "already-exists",
            "A completed Game Mode score cannot be changed.",
          );
        }
        return;
      }

      const questionsByLevel =
        progress.completedNpcQuestionsByLevel &&
        typeof progress.completedNpcQuestionsByLevel === "object" &&
        !Array.isArray(progress.completedNpcQuestionsByLevel)
          ? progress.completedNpcQuestionsByLevel as Record<string, unknown>
          : {};
      const completedQuestions = questionsByLevel[String(level)] ??
        (level === 1 ? progress.completedNpcQuestions : []);
      if (
        !Array.isArray(completedQuestions) ||
        ![1, 2, 3, 4, 5, 6].every((question) =>
          completedQuestions.includes(question),
        )
      ) {
        throw new HttpsError(
          "failed-precondition",
          "All six NPC questions must be completed before saving this score.",
        );
      }

      const leaderboardSnapshot = await transaction.get(leaderboardRef);
      const awardSnapshot = await transaction.get(awardRef);
      const existingAward = awardSnapshot.data();
      if (awardSnapshot.exists && existingAward?.points !== score) {
        throw new HttpsError(
          "failed-precondition",
          "A conflicting Game Mode score award already exists.",
        );
      }

      const baseline = userData.scoreBaseline ?? 0;
      const earned = userData.scoreEarned ?? 0;
      if (
        !Number.isSafeInteger(baseline) ||
        baseline < 0 ||
        !Number.isSafeInteger(earned) ||
        earned < 0
      ) {
        throw new HttpsError(
          "failed-precondition",
          "The saved score data is invalid.",
        );
      }

      const completedLevels = new Set<number>(
        Array.isArray(progress.completedLevels)
          ? progress.completedLevels.filter(
            (completedLevel: unknown): completedLevel is number =>
              typeof completedLevel === "number" &&
              Number.isInteger(completedLevel) &&
              completedLevel >= 1 &&
              completedLevel <= maximumLevel,
          )
          : [],
      );
      completedLevels.add(level);

      const mainLevel = Math.floor((level - 1) / 20) + 1;
      const displayNumber = level % 20 === 0 ? 20 : level % 20;
      const rawSublevels = progress.maxUnlockedSubLevel;
      const sublevels: Record<string, number> = {
        "1": 1,
        "2": 1,
        "3": 1,
        ...(rawSublevels &&
        typeof rawSublevels === "object" &&
        !Array.isArray(rawSublevels)
          ? rawSublevels as Record<string, number>
          : {}),
      };
      const nextSublevel = displayNumber + 1;
      if (
        nextSublevel <= 20 &&
        nextSublevel > (sublevels[String(mainLevel)] ?? 1)
      ) {
        sublevels[String(mainLevel)] = nextSublevel;
      }
      const unlockedLevels =
        displayNumber === 20 && mainLevel < 3
          ? Math.max(progress.unlockedLevels ?? 1, mainLevel + 1)
          : progress.unlockedLevels ?? 1;

      const newEarned = awardSnapshot.exists ? earned : earned + score;
      const newGameScore = baseline + newEarned;
      if (!Number.isSafeInteger(newGameScore)) {
        throw new HttpsError(
          "out-of-range",
          "The saved score is outside the supported range.",
        );
      }

      transaction.update(userRef, {
        "progress.completedLevels": [...completedLevels].sort((a, b) => a - b),
        "progress.unlockedLevels": unlockedLevels,
        "progress.maxUnlockedSubLevel": sublevels,
        [`progress.gameModeFinalScores.${level}`]: score,
        "progress.latestCompletedGameModeLevel": String(level),
        ...(awardSnapshot.exists
          ? {}
          : {
            scoreEarned: newEarned,
            gameScore: newGameScore,
          }),
      });

      if (!awardSnapshot.exists) {
        transaction.create(awardRef, {
          points: score,
          createdAt: FieldValue.serverTimestamp(),
        });
      }

      const leaderboardData = leaderboardSnapshot.data();
      const oldTotalScore = leaderboardData?.totalScore ?? 0;
      if (!Number.isSafeInteger(oldTotalScore) || oldTotalScore < 0) {
        throw new HttpsError(
          "failed-precondition",
          "The saved leaderboard score is invalid.",
        );
      }
      const addedScore = awardSnapshot.exists ? 0 : score;
      const displayName =
        typeof userData.name === "string" && userData.name.trim()
          ? userData.name.trim().slice(0, 80)
          : "Player";
      const leaderboardUpdate = {
        uid,
        displayName,
        totalScore: oldTotalScore + addedScore,
        profilePhotoUrl:
          typeof userData.profilePhotoUrl === "string" &&
            userData.profilePhotoUrl
            ? userData.profilePhotoUrl
            : profileImagePathForCharacter(userData.character),
        createdAt:
          leaderboardData?.createdAt ??
          userData.createdAt ??
          FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (leaderboardSnapshot.exists) {
        transaction.update(leaderboardRef, leaderboardUpdate);
      } else {
        transaction.set(leaderboardRef, leaderboardUpdate);
      }
    });
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    logger.error("Unable to save completed Game Mode score.", {
      uid,
      level,
      score,
      code: error instanceof Error && "code" in error
        ? error.code
        : "unknown",
      error,
    });
    throw new HttpsError(
      "internal",
      "Unable to save the completed Game Mode score.",
    );
  }

  return { saved: true, level, score };
});

export const syncLeaderboardFromUser =
  onDocumentWritten(
    {
      document: "users/{uid}",
      retry: true,
    },
    async (event) => {
      const uid = event.params.uid;

      const after =
        event.data?.after;

      if (!after?.exists) {
        await db
          .collection("leaderboard")
          .doc(uid)
          .delete();

        return;
      }

      const userData =
        after.data();

      if (!userData) {
        await db
          .collection("leaderboard")
          .doc(uid)
          .delete();

        return;
      }

      await reconcileProgressScoreAwards(uid);

      const latestUser =
        await db.collection("users").doc(uid).get();
      if (!latestUser.exists) {
        await db.collection("leaderboard").doc(uid).delete();
        return;
      }

      await updateLeaderboard(uid, latestUser.data()!);
    },
  );

export const syncMyLeaderboard =
  onCall(async (request) => {
    const uid =
      await requireCurrentSession(
        request,
      );

    const userSnapshot =
      await db
        .collection("users")
        .doc(uid)
        .get();

    if (!userSnapshot.exists) {
      throw new HttpsError(
        "not-found",
        "Your user profile could not be found.",
      );
    }

    const userData =
      userSnapshot.data()!;

    if (
      userData.role !== "student" ||
      userData.status !== "approved"
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Only approved student accounts can use the leaderboard.",
      );
    }

    await reconcileProgressScoreAwards(uid);
    const latestUserSnapshot = await db
      .collection("users")
      .doc(uid)
      .get();
    if (!latestUserSnapshot.exists) {
      throw new HttpsError(
        "not-found",
        "Your user profile could not be found.",
      );
    }
    const latestUserData = latestUserSnapshot.data()!;
    await updateLeaderboard(
      uid,
      latestUserData,
    );

    const score = latestUserData.gameScore ?? 0;

    return {
      uid,
      totalScore: score,
    };
  });

export const backfillLeaderboard =
  onCall({ timeoutSeconds: 540 }, async (request) => {
    const uid =
      await requireCurrentSession(
        request,
      );

    const adminSnapshot =
      await db
        .collection("users")
        .doc(uid)
        .get();

    if (
      adminSnapshot.data()?.role !==
      "admin"
    ) {
      throw new HttpsError(
        "permission-denied",
        "Only admins can backfill the leaderboard.",
      );
    }

    const rawScores = request.data?.scores;
    if (!Array.isArray(rawScores)) {
      throw new HttpsError(
        "invalid-argument",
        "Provide the authoritative score export as a scores array.",
      );
    }

    const importedScores = new Map<string, number>();
    for (const row of rawScores) {
      const rowUid =
        row && typeof row === "object" && "uid" in row
          ? row.uid
          : undefined;
      const rawScore =
        row && typeof row === "object" && "totalScore" in row
          ? row.totalScore
          : undefined;
      if (
        typeof rowUid !== "string" ||
        rowUid.length === 0 ||
        rowUid.includes("/") ||
        !Number.isSafeInteger(rawScore) ||
        (rawScore as number) < 0 ||
        importedScores.has(rowUid)
      ) {
        throw new HttpsError(
          "invalid-argument",
          "Each score row must contain a unique UID and a non-negative integer totalScore.",
        );
      }
      importedScores.set(rowUid, rawScore as number);
    }

    const users =
      db.collection("users");

    let cursor:
      FirebaseFirestore.QueryDocumentSnapshot
      | undefined;

    const allUsers: FirebaseFirestore.QueryDocumentSnapshot[] = [];
    while (true) {
      let query =
        users
          .orderBy(
            FieldPath.documentId(),
          )
          .limit(400);

      if (cursor) {
        query =
          query.startAfter(cursor);
      }

      const page =
        await query.get();

      if (page.empty) {
        break;
      }

      allUsers.push(...page.docs);

      if (page.size < 400) {
        break;
      }

      cursor =
        page.docs[
          page.docs.length - 1
        ];
    }

    const approvedStudents = allUsers.filter((user) => {
      const data = user.data();
      return data.role === "student" && data.status === "approved";
    });
    const approvedIds = new Set(
      approvedStudents.map((user) => user.id),
    );
    const unknownUids = [...importedScores.keys()].filter(
      (studentUid) => !approvedIds.has(studentUid),
    );
    if (unknownUids.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        `The score export contains UIDs that are not approved students: ${unknownUids.slice(0, 5).join(", ")}.`,
      );
    }

    const missingUids = approvedStudents
      .filter((user) => {
        const userData = user.data();
        return (
          userData.scoreBaseline === undefined &&
          !importedScores.has(user.id)
        );
      })
      .map((user) => user.id);
    if (missingUids.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        `No saved baseline score was found for these approved students: ${missingUids.slice(0, 5).join(", ")}.`,
      );
    }

    let processed = 0;
    for (const user of approvedStudents) {
      const userRef = users.doc(user.id);
      const leaderboardRef =
        db.collection("leaderboard").doc(user.id);

      await db.runTransaction(async (transaction) => {
        const latest = await transaction.get(userRef);
        if (!latest.exists) return;

        const userData = latest.data()!;
        if (
          userData.role !== "student" ||
          userData.status !== "approved"
        ) {
          return;
        }

        const baseline =
          userData.scoreBaseline ??
          importedScores.get(user.id);
        const earned = userData.scoreEarned ?? 0;
        if (
          !Number.isSafeInteger(baseline) ||
          (baseline as number) < 0 ||
          !Number.isSafeInteger(earned) ||
          earned < 0 ||
          !Number.isSafeInteger((baseline as number) + earned)
        ) {
          throw new HttpsError(
            "failed-precondition",
            `The score export or saved score for ${user.id} is invalid.`,
          );
        }

        const displayName =
          typeof userData.name === "string" &&
          userData.name.trim()
            ? userData.name.trim().slice(0, 80)
            : "Player";
        const totalScore = (baseline as number) + earned;

        transaction.set(
          userRef,
          {
            scoreBaseline: baseline,
            scoreEarned: earned,
            gameScore: totalScore,
          },
          { merge: true },
        );
        transaction.set(leaderboardRef, {
          uid: user.id,
          displayName,
          totalScore,
          profilePhotoUrl:
            typeof userData.profilePhotoUrl === "string" &&
              userData.profilePhotoUrl
              ? userData.profilePhotoUrl
              : profileImagePathForCharacter(userData.character),
          updatedAt: FieldValue.serverTimestamp(),
        });
      });
      processed += 1;
    }

    return {
      processed,
    };
  });