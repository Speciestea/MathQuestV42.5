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
  deleteDoc,
  getDoc,
  getFirestore,
  runTransaction,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
} from 'firebase/firestore';
import { deleteApp, initializeApp } from 'firebase/app';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

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
    `spark-registration-${index}-${Date.now()}`,
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

function testEmail(index) {
  return `spark-student-${index}-${Date.now()}@example.test`;
}

async function createAuthStudent(auth, label) {
  return createUserWithEmailAndPassword(
    auth,
    testEmail(label),
    'test-password-123',
  );
}

async function loginStudent(auth, db, email, deviceId) {
  const credential = await signInWithEmailAndPassword(
    auth,
    email,
    'test-password-123',
  );
  const sessionRef = doc(db, 'activeSessions', credential.user.uid);
  const sessionId = `test-session-${deviceId}-0123456789abcdef`;
  let claimedSession = false;

  try {
    await runTransaction(db, async (transaction) => {
      const session = await transaction.get(sessionRef);
      if (session.exists()) {
        if (session.data().deviceId !== deviceId) {
          throw new Error('Already active on another device.');
        }
        return;
      }
      transaction.set(sessionRef, {
        deviceId,
        sessionId,
        claimedAt: serverTimestamp(),
      });
    });
    claimedSession = true;

    const profileSnapshot = await getDoc(
      doc(db, 'users', credential.user.uid),
    );
    if (!profileSnapshot.exists()) {
      throw new Error('Student profile not found.');
    }
    const profile = profileSnapshot.data();
    if (profile.status !== 'approved') {
      throw new Error('Account pending admin approval.');
    }
    if (profile.role !== 'student') {
      throw new Error('Account has no valid role.');
    }
    return { uid: credential.user.uid, profile, sessionId };
  } catch (error) {
    if (claimedSession) await deleteDoc(sessionRef).catch(() => {});
    await signOut(auth);
    throw error;
  }
}

async function restoreStudentSession(auth, db, uid, deviceId, sessionId) {
  const [sessionSnapshot, profileSnapshot] = await Promise.all([
    getDoc(doc(db, 'activeSessions', uid)),
    getDoc(doc(db, 'users', uid)),
  ]);
  assert.equal(sessionSnapshot.exists(), true);
  assert.equal(sessionSnapshot.data().deviceId, deviceId);
  assert.equal(sessionSnapshot.data().sessionId, sessionId);
  assert.equal(auth.currentUser.uid, uid);
  const profile = profileSnapshot.data();
  assert.equal(profile.status, 'approved');
  assert.equal(profile.role, 'student');
  return profile;
}

async function registerStudent(auth, db, { name, character = 'boy' }) {
  const credential = auth.currentUser;
  assert.ok(credential, 'Registration requires an authenticated user');
  const userRef = doc(db, 'users', credential.uid);
  const counterRef = doc(db, 'systemCounters', 'studentNumbers');

  let attemptedLastNumber;
  let studentNo;
  let contentionRetries = 0;
  while (studentNo === undefined) {
    try {
      studentNo = await runTransaction(db, async (transaction) => {
        const [userSnapshot, counterSnapshot] = await Promise.all([
          transaction.get(userRef),
          transaction.get(counterRef),
        ]);
        assert.equal(userSnapshot.exists(), false);
        assert.equal(counterSnapshot.exists(), true);
        const counter = counterSnapshot.data();
        assert.equal(counter.schemaVersion, 2);
        assert.equal(counter.migrationState, 'complete');
        attemptedLastNumber = counter.lastNumber;

        const nextNumber = counter.lastNumber + 1;
        const assignedStudentNo = String(nextNumber);
        const profileImage = {
          boy: 'assets/images/player/boy.png',
          girl: 'assets/images/player/girl.png',
          character3: 'assets/images/player/T-rex.png',
          character4: 'assets/images/player/Pride Femme.png',
          character5: 'assets/images/player/Pride Masc.png',
        }[character];
        transaction.update(counterRef, {
          lastNumber: nextNumber,
          updatedAt: serverTimestamp(),
        });
        transaction.set(userRef, {
          uid: credential.uid,
          email: credential.email,
          role: 'student',
          status: 'pending',
          name,
          address: 'Test school',
          studentNo: assignedStudentNo,
          character,
          profilePhotoUrl: profileImage,
          tutorialEligible: true,
          tutorialCompleted: false,
          createdAt: serverTimestamp(),
        });
        return assignedStudentNo;
      });
    } catch (error) {
      if (
        error.code !== 'permission-denied' ||
        attemptedLastNumber === undefined ||
        contentionRetries >= 20
      ) {
        throw error;
      }
      const latestCounter = await getDoc(counterRef);
      if (latestCounter.data().lastNumber <= attemptedLastNumber) throw error;
      contentionRetries++;
      await new Promise((resolve) =>
        setTimeout(resolve, Math.min(25 * contentionRetries, 500)),
      );
    }
  }

  const savedProfile = await getDoc(userRef);
  assert.equal(savedProfile.exists(), true);
  assert.equal(savedProfile.data().uid, credential.uid);
  assert.equal(savedProfile.data().studentNo, studentNo);
  assert.equal(savedProfile.data().lrn, undefined);
  return { uid: credential.uid, studentNo };
}

async function expectPermissionDenied(operation) {
  await assert.rejects(operation, (error) =>
    error.code === 'permission-denied' ||
    error.code === 'firestore/permission-denied');
}

let stage = 'initialize Spark registration emulator test';
try {
  stage = 'seed initialized counter and legacy LRN student account';
  const legacyCredential = await createAuthStudent(auths[4], 'legacy');
  const legacyUid = legacyCredential.user.uid;
  const legacyEmail = legacyCredential.user.email;
  const legacyProfile = {
    uid: legacyUid,
    email: legacyEmail,
    role: 'student',
    status: 'approved',
    name: 'Legacy Student',
    address: 'Legacy school',
    lrn: '123456789012',
    scoreEarned: 120,
    gameScore: 120,
    progress: { completedLevels: [1, 2], unlockedLevels: 3 },
  };
  const legacyLrnIndex = {
    uid: legacyUid,
    createdAt: Timestamp.fromDate(new Date('2024-01-01T00:00:00Z')),
  };
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'systemCounters', 'studentNumbers'), {
      lastNumber: 0,
      schemaVersion: 2,
      migrationState: 'complete',
    });
    await setDoc(doc(db, 'users', legacyUid), legacyProfile);
    await setDoc(doc(db, 'lrnIndexes', legacyProfile.lrn), legacyLrnIndex);
  });

  stage = 'assign first Student No. from zero baseline';
  await createAuthStudent(auths[0], 0);
  const first = await registerStudent(auths[0], databases[0], {
    name: 'First Student',
  });
  assert.equal(first.studentNo, '1');
  const firstEmail = auths[0].currentUser.email;

  stage = 'enforce approval before Spark student login';
  const firstProfileRef = doc(databases[0], 'users', first.uid);
  await assert.rejects(
    loginStudent(
      auths[0],
      databases[0],
      auths[0].currentUser.email,
      'first-device-identifier-123',
    ),
    /Account pending admin approval/,
  );
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(
      doc(context.firestore(), 'users', first.uid),
      { status: 'approved' },
    );
  });

  stage = 'log in approved new student without changing Student No.';
  const firstLogin = await loginStudent(
    auths[0],
    databases[0],
    firstEmail,
    'first-device-identifier-123',
  );
  assert.equal(firstLogin.profile.studentNo, '1');
  const firstSessionId = firstLogin.sessionId;

  stage = 'restore approved student session without changing Student No.';
  const restoredProfile = await restoreStudentSession(
    auths[0],
    databases[0],
    first.uid,
    'first-device-identifier-123',
    firstSessionId,
  );
  assert.equal(restoredProfile.studentNo, '1');

  stage = 'reject login from a second device';
  await assert.rejects(
    loginStudent(
      auths[3],
      databases[3],
      firstEmail,
      'second-device-identifier-456',
    ),
    /Already active on another device/,
  );
  await signOut(auths[0]);

  stage = 'assign unique consecutive Student Nos. concurrently';
  await Promise.all([
    createAuthStudent(auths[1], 1),
    createAuthStudent(auths[2], 2),
  ]);
  const concurrentResults = await Promise.allSettled([
    registerStudent(auths[1], databases[1], {
      name: 'Concurrent Student One',
      character: 'girl',
    }),
    registerStudent(auths[2], databases[2], {
      name: 'Concurrent Student Two',
      character: 'character4',
    }),
  ]);
  if (concurrentResults.some((result) => result.status === 'rejected')) {
    console.error(
      'Concurrent registration outcomes:',
      concurrentResults.map((result) =>
        result.status === 'fulfilled'
          ? result.value
          : { code: result.reason?.code, message: result.reason?.message },
      ),
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const currentCounter = await getDoc(
        doc(context.firestore(), 'systemCounters', 'studentNumbers'),
      );
      console.error(
        'Counter after concurrent registration attempt:',
        currentCounter.data(),
      );
    });
  }
  assert.ok(
    concurrentResults.every((result) => result.status === 'fulfilled'),
    'Concurrent registrations must both commit successfully.',
  );
  const concurrent = concurrentResults.map((result) => result.value);
  assert.deepEqual(
    concurrent.map((student) => student.studentNo).sort(),
    ['2', '3'],
  );

  stage = 'reject unpaired and forged counter/profile writes';
  await createAuthStudent(auths[3], 3);
  const attacker = auths[3].currentUser;
  assert.ok(attacker);
  const attackerDb = databases[3];
  const attackerCounterRef = doc(
    attackerDb,
    'systemCounters',
    'studentNumbers',
  );
  const attackerUserRef = doc(attackerDb, 'users', attacker.uid);

  await expectPermissionDenied(
    runTransaction(attackerDb, async (transaction) => {
      const counter = await transaction.get(attackerCounterRef);
      transaction.update(attackerCounterRef, {
        lastNumber: counter.data().lastNumber + 1,
        updatedAt: serverTimestamp(),
      });
    }),
  );
  await expectPermissionDenied(
    setDoc(attackerUserRef, {
      uid: attacker.uid,
      email: attacker.email,
      role: 'student',
      status: 'pending',
      name: 'Forged Student',
      address: 'Test school',
      studentNo: '999',
      character: 'boy',
      profilePhotoUrl: 'assets/images/player/boy.png',
      tutorialEligible: true,
      tutorialCompleted: false,
      createdAt: serverTimestamp(),
    }),
  );
  await expectPermissionDenied(
    runTransaction(attackerDb, async (transaction) => {
      const counter = await transaction.get(attackerCounterRef);
      const next = counter.data().lastNumber + 2;
      transaction.update(attackerCounterRef, {
        lastNumber: next,
        updatedAt: serverTimestamp(),
      });
      transaction.set(attackerUserRef, {
        uid: attacker.uid,
        email: attacker.email,
        role: 'student',
        status: 'pending',
        name: 'Skipped Student',
        address: 'Test school',
        studentNo: String(next),
        character: 'boy',
        profilePhotoUrl: 'assets/images/player/boy.png',
        tutorialEligible: true,
        tutorialCompleted: false,
        createdAt: serverTimestamp(),
      });
    }),
  );
  await expectPermissionDenied(
    runTransaction(databases[0], async (transaction) => {
      const profileRef = doc(databases[0], 'users', first.uid);
      const profile = await transaction.get(profileRef);
      transaction.update(profileRef, { studentNo: '999' });
      assert.equal(profile.data().studentNo, '1');
    }),
  );

  stage = 'verify counter and existing student data remain correct';
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const counter = await getDoc(
      doc(db, 'systemCounters', 'studentNumbers'),
    );
    assert.equal(counter.data().lastNumber, 3);
    const profile = await getDoc(doc(db, 'users', legacyUid));
    assert.deepEqual(profile.data(), legacyProfile);
    const lrnIndex = await getDoc(
      doc(db, 'lrnIndexes', legacyProfile.lrn),
    );
    assert.deepEqual(lrnIndex.data(), legacyLrnIndex);
  });
  stage = 'log in legacy LRN account without assigning a Student No.';
  await signOut(auths[4]);
  const legacyLogin = await loginStudent(
    auths[4],
    databases[4],
    legacyEmail,
    'legacy-device-identifier-789',
  );
  assert.equal(legacyLogin.profile.studentNo, undefined);
  assert.equal(legacyLogin.profile.lrn, legacyProfile.lrn);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const profile = await getDoc(
      doc(context.firestore(), 'users', legacyUid),
    );
    assert.deepEqual(profile.data(), legacyProfile);
  });

  console.log(
    'PASS: Spark client transactions assign IDs 1, 2, 3 sequentially and concurrently without duplicates.',
  );
  console.log(
    'PASS: Rules reject counter-only writes, forged/skipped Student Nos., and changes to assigned IDs.',
  );
  console.log(
    'PASS: Existing LRN, Student No., progress, scores, and LRN index remain unchanged.',
  );
  console.log(
    'PASS: Approved students log in and restore sessions without a Student Number callable or ID reassignment.',
  );
  console.log(
    'PASS: Pending accounts are rejected, second-device login is blocked, and LRN-only legacy accounts remain unchanged.',
  );
} catch (error) {
  console.error(`Spark registration test failed during ${stage}:`, error);
  throw error;
} finally {
  await Promise.all(auths.map((auth) => signOut(auth).catch(() => {})));
  await Promise.all(apps.map((app) => deleteApp(app)));
  await testEnv.cleanup();
}
