import assert from 'node:assert/strict';
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
  signInWithEmailAndPassword,
  signOut,
} from 'firebase/auth';
import {
  connectFirestoreEmulator,
  doc,
  getDoc,
  getFirestore,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
} from 'firebase/firestore';
import { deleteApp, initializeApp } from 'firebase/app';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import functions from '../functions/lib/index.js';

const projectId = 'demo-mathquest-rules';
const authEmulatorHost =
  process.env.FIREBASE_AUTH_EMULATOR_HOST ?? '127.0.0.1:9099';
const firestoreEmulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
assert.ok(firestoreEmulatorHost, 'FIRESTORE_EMULATOR_HOST is required');

const [firestoreHost, firestorePort] = firestoreEmulatorHost.split(':');
const [authHost, authPort] = authEmulatorHost.split(':');
const rules = await readFile(
  fileURLToPath(new URL('../firestore.rules', import.meta.url)),
  'utf8',
);
const testEnv = await initializeTestEnvironment({
  projectId,
  firestore: { rules },
});
const apps = Array.from({ length: 5 }, (_, index) =>
  initializeApp(
    { apiKey: 'demo-api-key', projectId },
    `registration-flow-${index}-${Date.now()}`,
  ),
);
const auths = apps.map((app) => getAuth(app));
const databases = apps.map((app) => getFirestore(app));
for (const auth of auths) {
  connectAuthEmulator(auth, `http://${authHost}:${authPort}`, {
    disableWarnings: true,
  });
}
for (const db of databases) {
  connectFirestoreEmulator(db, firestoreHost, Number(firestorePort));
}

function testEmail(label) {
  return `${label}-${Date.now()}@example.test`;
}

async function callable(auth, name, data = {}) {
  const user = auth.currentUser;
  assert.ok(user, `Callable ${name} requires an authenticated user`);
  const callableFunction = functions[name];
  assert.equal(
    typeof callableFunction?.run,
    'function',
    `Cloud Function ${name} must be exported`,
  );
  return callableFunction.run({
    auth: { uid: user.uid, token: { email: user.email } },
    data,
  });
}

async function registerStudent(auth, email, name, character = 'character3') {
  let credential;
  try {
    credential = await createUserWithEmailAndPassword(
      auth,
      email,
      'test-password-123',
    );
  } catch (error) {
    if (error.code !== 'auth/email-already-in-use') throw error;
    credential = await signInWithEmailAndPassword(
      auth,
      email,
      'test-password-123',
    );
  }

  const result = await callable(auth, 'registerStudent', {
    name,
    address: 'Test school',
    character,
  });
  assert.match(result.studentNo, /^[1-9]\d*$/);
  const profile = await getDoc(
    doc(databases[auths.indexOf(auth)], 'users', credential.user.uid),
  );
  assert.equal(profile.exists(), true);
  assert.equal(profile.data().uid, credential.user.uid);
  assert.equal(profile.data().email, email);
  assert.equal(profile.data().role, 'student');
  assert.equal(profile.data().status, 'pending');
  assert.equal(profile.data().studentNo, result.studentNo);
  assert.equal(profile.data().character, character);
  const expectedProfileImage = {
    character3: 'assets/images/player/T-rex.png',
    character4: 'assets/images/player/Pride Femme.png',
    character5: 'assets/images/player/Pride Masc.png',
  }[character];
  if (expectedProfileImage) {
    assert.equal(profile.data().profilePhotoUrl, expectedProfileImage);
  }
  return {
    uid: credential.user.uid,
    email,
    studentNo: result.studentNo,
  };
}

async function expectPermissionDenied(operation) {
  await assert.rejects(operation, (error) => error.code === 'permission-denied');
}

let stage = 'initialize registration test';
try {
  const [adminAuth, studentAuth, simultaneousAuth, legacyAuth, invalidAuth] =
    auths;
  const [adminDb, studentDb, , legacyDb, invalidDb] = databases;

  stage = 'create administrator, super administrator, and teacher records';
  const adminEmail = testEmail('admin');
  const adminCredential = await createUserWithEmailAndPassword(
    adminAuth,
    adminEmail,
    'test-password-123',
  );
  const adminUid = adminCredential.user.uid;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', adminUid), {
      uid: adminUid,
      email: adminEmail,
      name: 'Test Administrator',
      role: 'admin',
      status: 'approved',
    });
    await setDoc(doc(db, 'activeSessions', adminUid), {
      sessionId: 'test-administrator-session',
    });
    await setDoc(doc(db, 'users', 'test-super-admin'), {
      role: 'super_admin',
      status: 'approved',
    });
    await setDoc(doc(db, 'users', 'test-teacher'), {
      role: 'teacher',
      status: 'approved',
    });
  });

  stage = 'verify administrator can establish a login session';
  const adminSession = await callable(adminAuth, 'claimLoginSession', {
    deviceId: 'test-administrator-device-123',
  });
  assert.equal(typeof adminSession.sessionId, 'string');

  stage = 'migrate a legacy UID-based Student No.';
  const legacyEmail = testEmail('legacy-student');
  const legacyCredential = await createUserWithEmailAndPassword(
    legacyAuth,
    legacyEmail,
    'test-password-123',
  );
  const legacyUid = legacyCredential.user.uid;
  await signOut(legacyAuth);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users', legacyUid), {
      uid: legacyUid,
      email: legacyEmail,
      name: 'Legacy Student',
      address: 'Legacy school',
      role: 'student',
      status: 'approved',
      studentNo: `MQ-${legacyUid}`,
      createdAt: Timestamp.fromDate(new Date('2022-01-01T00:00:00Z')),
    });
  });
  const migration = await callable(adminAuth, 'ensureStudentNumbers');
  assert.equal(migration.assigned, 0);
  assert.equal(
    (await getDoc(doc(adminDb, 'users', legacyUid))).data().studentNo,
    `MQ-${legacyUid}`,
  );
  assert.equal(
    (await getDoc(doc(adminDb, 'users', 'test-super-admin'))).data()
      .studentNo,
    undefined,
  );
  assert.equal(
    (await getDoc(doc(adminDb, 'users', 'test-teacher'))).data().studentNo,
    undefined,
  );

  stage = 'ensure invalid registration does not consume a Student No.';
  await signInWithEmailAndPassword(
    legacyAuth,
    legacyEmail,
    'test-password-123',
  );
  await assert.rejects(
    callable(legacyAuth, 'registerStudent', {
      name: '',
      address: 'Test school',
    }),
    (error) => error.code === 'invalid-argument',
  );
  await signOut(legacyAuth);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const counter = await getDoc(
      doc(context.firestore(), 'systemCounters', 'studentNumbers'),
    );
    assert.equal(counter.data().lastNumber, 0);
  });

  stage = 'register two students concurrently with unique sequence values';
  const [firstStudent, secondStudent] = await Promise.all([
    registerStudent(
      studentAuth,
      testEmail('first-student'),
      'First Test Student',
    ),
    registerStudent(
      simultaneousAuth,
      testEmail('second-student'),
      'Second Test Student',
      'character4',
    ),
  ]);
  assert.deepEqual(
    [firstStudent.studentNo, secondStudent.studentNo].sort(),
    ['1', '2'],
  );

  stage = 'confirm registration retry retains its assigned number';
  const retried = await callable(studentAuth, 'registerStudent', {
    name: 'Changed Retry Name',
    address: 'Changed school',
  });
  assert.equal(retried.studentNo, firstStudent.studentNo);
  assert.equal(
    (await getDoc(doc(studentDb, 'users', firstStudent.uid))).data().name,
    'First Test Student',
  );

  stage = 'restrict pending login and preserve approval status';
  await assert.rejects(
    callable(simultaneousAuth, 'claimLoginSession', {
      deviceId: 'pending-student-device-123',
    }),
    (error) => error.code === 'failed-precondition',
  );
  await updateDoc(doc(adminDb, 'users', firstStudent.uid), {
    status: 'approved',
  });
  const approvedStudentSession = await callable(
    studentAuth,
    'claimLoginSession',
    { deviceId: 'approved-student-device-123' },
  );
  assert.equal(typeof approvedStudentSession.sessionId, 'string');
  await callable(studentAuth, 'syncMyLeaderboard');
  assert.equal(
    (await getDoc(doc(studentDb, 'leaderboard', firstStudent.uid))).data()
      .profilePhotoUrl,
    'assets/images/player/T-rex.png',
  );
  assert.equal(
    (await getDoc(doc(adminDb, 'users', firstStudent.uid))).data().studentNo,
    firstStudent.studentNo,
  );
  const releasedStudentSession = await callable(
    studentAuth,
    'releaseLoginSession',
    {
      deviceId: 'approved-student-device-123',
      sessionId: approvedStudentSession.sessionId,
    },
  );
  assert.equal(releasedStudentSession.released, true);
  await updateDoc(doc(adminDb, 'users', secondStudent.uid), {
    status: 'rejected',
  });
  const rejectedProfile = await getDoc(
    doc(adminDb, 'users', secondStudent.uid),
  );
  assert.equal(rejectedProfile.data().status, 'rejected');
  assert.equal(rejectedProfile.data().studentNo, secondStudent.studentNo);

  stage = 'reject client-assigned Student Nos. and standalone counter updates';
  const invalidCredential = await createUserWithEmailAndPassword(
    invalidAuth,
    testEmail('forged-student'),
    'test-password-123',
  );
  const invalidUid = invalidCredential.user.uid;
  await expectPermissionDenied(
    setDoc(doc(invalidDb, 'users', invalidUid), {
      uid: invalidUid,
      email: invalidCredential.user.email,
      role: 'student',
      status: 'pending',
      name: 'Forged Student',
      address: 'Test school',
      studentNo: '999',
      character: 'boy',
      profilePhotoUrl: '',
      tutorialEligible: true,
      tutorialCompleted: false,
      createdAt: serverTimestamp(),
    }),
  );
  const studentNumberCounter = await getDoc(
    doc(invalidDb, 'systemCounters', 'studentNumbers'),
  );
  assert.equal(studentNumberCounter.exists(), true);
  await expectPermissionDenied(
    updateDoc(doc(invalidDb, 'systemCounters', 'studentNumbers'), {
      lastNumber: studentNumberCounter.data().lastNumber + 1,
    }),
  );

  stage = 'reject student edits to the assigned Student No.';
  await signOut(studentAuth);
  await signInWithEmailAndPassword(
    studentAuth,
    firstStudent.email,
    'test-password-123',
  );
  assert.equal(
    (await getDoc(doc(studentDb, 'users', firstStudent.uid))).data()
      .profilePhotoUrl,
    'assets/images/player/T-rex.png',
  );
  await setDoc(doc(studentDb, 'activeSessions', firstStudent.uid), {
    deviceId: 'test-device-identifier-123',
    sessionId: 'test-session-identifier-1234567890123456',
    claimedAt: serverTimestamp(),
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const [collection, documentId] of [
      ['profileData', 'photo'],
      ['classroomQuestAttempts', 'attempt-1'],
      ['classroomQuestDailyCompletions', '2026-11-23'],
      ['gameModeAttempts', 'attempt-1'],
      ['problemLevelAttempts', 'attempt-1'],
      ['scoreAwards', 'game-mode-1'],
      ['legacyNestedRecords', 'record-1'],
    ]) {
      await setDoc(
        doc(db, 'users', firstStudent.uid, collection, documentId),
        { uid: firstStudent.uid },
      );
    }
    await setDoc(
      doc(db, 'users', secondStudent.uid, 'gameModeAttempts', 'other-attempt'),
      { uid: secondStudent.uid },
    );
    await setDoc(doc(db, 'activeSessions', secondStudent.uid), {
      sessionId: 'other-student-session',
    });
    await setDoc(doc(db, 'leaderboard', secondStudent.uid), {
      uid: secondStudent.uid,
    });
    await setDoc(doc(db, 'lrnIndexes', 'target-student-index'), {
      uid: firstStudent.uid,
    });
    await setDoc(doc(db, 'lrnIndexes', 'other-student-index'), {
      uid: secondStudent.uid,
    });
  });
  await expectPermissionDenied(
    updateDoc(doc(studentDb, 'users', firstStudent.uid), {
      studentNo: '999',
    }),
  );
  await updateDoc(doc(studentDb, 'users', firstStudent.uid), {
    name: 'Edited Test Student',
  });
  const ensuredNumber = await callable(studentAuth, 'ensureStudentNumber');
  assert.equal(ensuredNumber.studentNo, firstStudent.studentNo);
  assert.equal(
    (await getDoc(doc(studentDb, 'users', firstStudent.uid))).data().studentNo,
    firstStudent.studentNo,
  );

  stage = 'delete one student without changing other numbers or counter';
  const singleDeletion = await callable(adminAuth, 'deleteStudentAccount', {
    uid: firstStudent.uid,
  });
  assert.equal(singleDeletion.deleted, true);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal((await getDoc(doc(db, 'users', firstStudent.uid))).exists(), false);
    for (const [collection, documentId] of [
      ['profileData', 'photo'],
      ['classroomQuestAttempts', 'attempt-1'],
      ['classroomQuestDailyCompletions', '2026-11-23'],
      ['gameModeAttempts', 'attempt-1'],
      ['problemLevelAttempts', 'attempt-1'],
      ['scoreAwards', 'game-mode-1'],
      ['legacyNestedRecords', 'record-1'],
    ]) {
      assert.equal(
        (
          await getDoc(
            doc(db, 'users', firstStudent.uid, collection, documentId),
          )
        ).exists(),
        false,
        `${collection}/${documentId} should be deleted`,
      );
    }
    assert.equal(
      (await getDoc(doc(db, 'activeSessions', firstStudent.uid))).exists(),
      false,
    );
    assert.equal(
      (await getDoc(doc(db, 'leaderboard', firstStudent.uid))).exists(),
      false,
    );
    assert.equal((await getDoc(doc(db, 'users', secondStudent.uid))).exists(), true);
    assert.equal(
      (
        await getDoc(
          doc(
            db,
            'users',
            secondStudent.uid,
            'gameModeAttempts',
            'other-attempt',
          ),
        )
      ).exists(),
      true,
    );
    assert.equal(
      (await getDoc(doc(db, 'activeSessions', secondStudent.uid))).exists(),
      true,
    );
    assert.equal(
      (await getDoc(doc(db, 'leaderboard', secondStudent.uid))).exists(),
      true,
    );
    assert.equal(
      (await getDoc(doc(db, 'lrnIndexes', 'target-student-index'))).exists(),
      false,
    );
    assert.equal(
      (await getDoc(doc(db, 'lrnIndexes', 'other-student-index'))).exists(),
      true,
    );
  });
  await signOut(studentAuth);
  await assert.rejects(
    signInWithEmailAndPassword(
      studentAuth,
      firstStudent.email,
      'test-password-123',
    ),
    (error) => error.code === 'auth/user-not-found',
  );
  await simultaneousAuth.currentUser.reload();
  const deletionRetry = await callable(adminAuth, 'deleteStudentAccount', {
    uid: firstStudent.uid,
  });
  assert.equal(deletionRetry.deleted, true);
  assert.equal(
    (await getDoc(doc(adminDb, 'users', secondStudent.uid))).data().studentNo,
    secondStudent.studentNo,
  );
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const counter = await getDoc(
      doc(context.firestore(), 'systemCounters', 'studentNumbers'),
    );
    assert.equal(counter.data().lastNumber, 2);
  });

  stage = 'delete remaining student profiles and reset the counter';
  for (const student of [secondStudent, {
    uid: legacyUid,
    email: legacyEmail,
  }]) {
    const result = await callable(adminAuth, 'deleteStudentAccount', {
      uid: student.uid,
    });
    assert.equal(result.deleted, true);
    assert.equal((await getDoc(doc(adminDb, 'users', student.uid))).exists(), false);
  }
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const counter = await getDoc(
      doc(context.firestore(), 'systemCounters', 'studentNumbers'),
    );
    assert.equal(counter.data().lastNumber, 0);
  });
  assert.equal(
    (await getDoc(doc(adminDb, 'users', adminUid))).exists(),
    true,
  );
  assert.equal(
    (await getDoc(doc(adminDb, 'users', 'test-super-admin'))).exists(),
    true,
  );

  await signOut(legacyAuth);
  const recreatedCredential = await createUserWithEmailAndPassword(
    legacyAuth,
    legacyEmail,
    'test-password-123',
  );
  const recreated = await callable(legacyAuth, 'registerStudent', {
    name: 'Legacy Student Again',
    address: 'Test school',
    character: 'character5',
  });
  assert.equal(recreated.studentNo, '1');
  assert.equal(
    (
      await getDoc(doc(legacyDb, 'users', recreatedCredential.user.uid))
    ).data().profilePhotoUrl,
    'assets/images/player/Pride Masc.png',
  );

  console.log(
    'PASS: registration, student account and nested-data deletion, Authentication removal, idempotent deletion retry, unaffected student preservation, Student No. retention, and administrator protection.',
  );
} catch (error) {
  console.error(`Registration emulator test failed during ${stage}:`, error);
  throw error;
} finally {
  await Promise.all(auths.map((auth) => signOut(auth).catch(() => {})));
  await Promise.all(apps.map((app) => deleteApp(app)));
  await testEnv.cleanup();
}
