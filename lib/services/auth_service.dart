import 'dart:math';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_account.dart';
import 'leaderboard_service.dart';

enum SaveAuthorizationStatus {
  signedOut,
  sessionExpired,
  accountNotApproved,
  authorized,
  temporarilyUnableToVerify,
  securityVerificationFailed,
  unableToVerify,
}

class AuthService {
  static const String firestoreProfilePhotoUrl = 'firestore://profile-photo';
  static const String _pendingEmailChangeKeyPrefix =
      'pending_profile_email_change_';

  static FirebaseAuth get _auth {
    try {
      return FirebaseAuth.instance;
    } on FirebaseException {
      throw StateError(
          'Firebase Auth is not available because Firebase is not initialized.');
    } catch (_) {
      throw StateError(
          'Firebase Auth is not available because Firebase is not initialized.');
    }
  }

  static CollectionReference<Map<String, dynamic>> get _users {
    try {
      return FirebaseFirestore.instance.collection('users');
    } on FirebaseException {
      throw StateError(
          'Firebase Firestore is not available because Firebase is not initialized.');
    } catch (_) {
      throw StateError(
          'Firebase Firestore is not available because Firebase is not initialized.');
    }
  }

  static DocumentReference<Map<String, dynamic>> _profilePhotoDocument(
    String uid,
  ) =>
      _users.doc(uid).collection('profileData').doc('photo');

  static Future<void> _logProfileSaveContext(
    String uid, {
    String? requestedName,
    String? requestedAddress,
    String? requestedPhotoDataUrl,
  }) async {
    try {
      final userSnapshot = await _users.doc(uid).get(
            const GetOptions(source: Source.server),
          );
      final account = userSnapshot.data();
      final sessionSnapshot = await _sessions.doc(uid).get(
            const GetOptions(source: Source.server),
          );
      final photoSnapshot = await _profilePhotoDocument(uid).get(
        const GetOptions(source: Source.server),
      );
      final storedName = account?['name'];
      final storedAddress = account?['address'];
      final photoDataIsValid = requestedPhotoDataUrl == null ||
          (requestedPhotoDataUrl.length <= 830000 &&
              RegExp(
                r'^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',
              ).hasMatch(requestedPhotoDataUrl));
      debugPrint(
        'Profile save context: project=${FirebaseFirestore.instance.app.options.projectId}, '
        'authUidMatchesTarget=${currentUser?.uid == uid}, '
        'userDocumentExists=${userSnapshot.exists}, '
        'storedUidMatches=${account?['uid'] == null || account?['uid'] == uid}, '
        'role=${account?['role'] ?? '(missing)'}, '
        'status=${account?['status'] ?? '(missing)'}, '
        'activeSessionExists=${sessionSnapshot.exists}, '
        'lrnPresent=${account?.containsKey('lrn') ?? false}, '
        'storedNameValid=${storedName is String && storedName.isNotEmpty && storedName.length <= 100}, '
        'storedAddressValid=${storedAddress is String && storedAddress.length <= 300}, '
        'requestedNameValid=${requestedName == null || (requestedName.isNotEmpty && requestedName.length <= 100)}, '
        'requestedAddressValid=${requestedAddress == null || requestedAddress.length <= 300}, '
        'photoDocumentExists=${photoSnapshot.exists}, '
        'photoDataShapeValid=$photoDataIsValid.',
      );
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Unable to read profile-save authorization context '
        '(uid=$uid, plugin=${error.plugin}, code=${error.code}, '
        'message=${error.message ?? '(none)'}).',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static CollectionReference<Map<String, dynamic>> get _sessions {
    try {
      return FirebaseFirestore.instance.collection('activeSessions');
    } on FirebaseException {
      throw StateError(
          'Firebase Firestore is not available because Firebase is not initialized.');
    } catch (_) {
      throw StateError(
          'Firebase Firestore is not available because Firebase is not initialized.');
    }
  }

  static FirebaseFunctions get _functions => FirebaseFunctions.instance;

  static Future<void> ensureStudentNumbersForAdmin() async {
    final result = await _functions
        .httpsCallable('ensureStudentNumbers')
        .call<Map<String, dynamic>>();
    if (result.data['assigned'] is! int) {
      throw StateError(
        'The Student No. migration service returned an invalid result.',
      );
    }
  }

  static const _deviceIdKey = 'mathquest_device_id';
  static const _sessionIdKeyPrefix = 'mathquest_session_id_';
  static String? _verifiedSessionUid;
  static String? _verifiedSessionCacheKey;
  static String? _verifiedStudentOfflineSessionCacheKey;
  static StreamSubscription<String?>? _authStateSubscription;
  static final StreamController<void> _sessionInvalidations =
      StreamController<void>.broadcast(sync: true);

  static Stream<void> get sessionInvalidations => _sessionInvalidations.stream;

  static bool _isTemporaryNetworkFailure(String code) => const {
        'deadline-exceeded',
        'network-request-failed',
        'unavailable',
      }.contains(code);

  @visibleForTesting
  static bool preservesVerifiedSessionForFailureCode(String code) =>
      _isTemporaryNetworkFailure(code);

  @visibleForTesting
  static bool shouldInvalidateVerifiedSessionForUid({
    required String? verifiedUid,
    required String? currentUid,
  }) =>
      verifiedUid != null && verifiedUid != currentUid;

  @visibleForTesting
  static bool canEstablishStudentOfflineAuthorization({
    required String role,
    required String status,
  }) =>
      role.trim().toLowerCase() == 'student' &&
      status.trim().toLowerCase() == 'approved';

  @visibleForTesting
  static String? verifiedSessionCacheKeyFor({
    required String? uid,
    required String? deviceId,
    required String? sessionId,
    required String? verifiedCacheKey,
  }) {
    if (uid == null ||
        deviceId == null ||
        deviceId.length < 16 ||
        sessionId == null ||
        sessionId.isEmpty) {
      return null;
    }

    final cacheKey = '$uid:$deviceId:$sessionId';
    return cacheKey == verifiedCacheKey ? cacheKey : null;
  }

  static void invalidateCurrentVerifiedSession() {
    _verifiedSessionUid = null;
    _verifiedSessionCacheKey = null;
    _verifiedStudentOfflineSessionCacheKey = null;
    _sessionInvalidations.add(null);
  }

  static void _ensureAuthStateListener({Stream<String?>? authStateChanges}) {
    _authStateSubscription ??=
        (authStateChanges ?? _auth.authStateChanges().map((user) => user?.uid))
            .listen(
      _handleAuthStateUidChange,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
            'Unable to observe auth changes for verified session: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
  }

  static void _handleAuthStateUidChange(String? currentUid) {
    if (shouldInvalidateVerifiedSessionForUid(
      verifiedUid: _verifiedSessionUid,
      currentUid: currentUid,
    )) {
      invalidateCurrentVerifiedSession();
    }
  }

  static void _rememberVerifiedSession(
    UserAccount account,
    String deviceId,
    String sessionId,
  ) {
    final uid = account.uid;
    final cacheKey = '$uid:$deviceId:$sessionId';
    _verifiedSessionUid = uid;
    _verifiedSessionCacheKey = cacheKey;
    _verifiedStudentOfflineSessionCacheKey =
        canEstablishStudentOfflineAuthorization(
      role: account.role,
      status: account.status,
    )
            ? cacheKey
            : null;
    _ensureAuthStateListener();
  }

  @visibleForTesting
  static void listenForAuthStateChangesForTesting(Stream<String?> changes) {
    _ensureAuthStateListener(authStateChanges: changes);
  }

  @visibleForTesting
  static void rememberVerifiedSessionForTesting({
    required String uid,
    required String role,
    required String status,
    required String deviceId,
    required String sessionId,
  }) {
    _verifiedSessionUid = uid;
    _verifiedSessionCacheKey = '$uid:$deviceId:$sessionId';
    _verifiedStudentOfflineSessionCacheKey =
        canEstablishStudentOfflineAuthorization(role: role, status: status)
            ? _verifiedSessionCacheKey
            : null;
  }

  @visibleForTesting
  static String? get verifiedSessionCacheKeyForTesting =>
      _verifiedSessionCacheKey;

  @visibleForTesting
  static String? get verifiedStudentOfflineSessionCacheKeyForTesting =>
      _verifiedStudentOfflineSessionCacheKey;

  @visibleForTesting
  static Future<void> resetVerifiedSessionForTesting() async {
    invalidateCurrentVerifiedSession();
    await _authStateSubscription?.cancel();
    _authStateSubscription = null;
  }

  static Future<String?> currentVerifiedSessionCacheKey() async {
    final user = currentUser;
    if (shouldInvalidateVerifiedSessionForUid(
      verifiedUid: _verifiedSessionUid,
      currentUid: user?.uid,
    )) {
      invalidateCurrentVerifiedSession();
      return null;
    }
    if (user == null || _verifiedSessionUid != user.uid) return null;

    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_deviceIdKey);
    final sessionId = preferences.getString('$_sessionIdKeyPrefix${user.uid}');
    final currentUserAfterRead = currentUser;
    if (shouldInvalidateVerifiedSessionForUid(
      verifiedUid: _verifiedSessionUid,
      currentUid: currentUserAfterRead?.uid,
    )) {
      invalidateCurrentVerifiedSession();
      return null;
    }

    final verifiedCacheKey = verifiedSessionCacheKeyFor(
      uid: user.uid,
      deviceId: deviceId,
      sessionId: sessionId,
      verifiedCacheKey: _verifiedSessionCacheKey,
    );
    if (verifiedCacheKey == null) {
      invalidateCurrentVerifiedSession();
    }
    return verifiedCacheKey;
  }

  static Future<String?> currentVerifiedStudentOfflineSessionCacheKey() async {
    final sessionKey = await currentVerifiedSessionCacheKey();
    if (sessionKey == null ||
        _verifiedStudentOfflineSessionCacheKey != sessionKey) {
      return null;
    }
    return sessionKey;
  }

  static User? get currentUser {
    try {
      return FirebaseAuth.instance.currentUser;
    } on FirebaseException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<SaveAuthorizationStatus>
      checkCurrentSaveAuthorizationStatus() async {
    final user = currentUser;
    if (shouldInvalidateVerifiedSessionForUid(
      verifiedUid: _verifiedSessionUid,
      currentUid: user?.uid,
    )) {
      invalidateCurrentVerifiedSession();
    }
    if (user == null) {
      invalidateCurrentVerifiedSession();
      return SaveAuthorizationStatus.signedOut;
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      final deviceId = preferences.getString(_deviceIdKey);
      final cachedSessionId =
          preferences.getString('$_sessionIdKeyPrefix${user.uid}');
      if (deviceId == null ||
          deviceId.length < 16 ||
          cachedSessionId == null ||
          cachedSessionId.isEmpty) {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.sessionExpired;
      }

      final sessionSnapshot = await _sessions.doc(user.uid).get(
            const GetOptions(source: Source.server),
          );
      final session = sessionSnapshot.data();
      if (!sessionSnapshot.exists ||
          session?['deviceId'] != deviceId ||
          session?['sessionId'] != cachedSessionId) {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.sessionExpired;
      }

      final accountSnapshot = await _users.doc(user.uid).get(
            const GetOptions(source: Source.server),
          );
      final account = accountSnapshot.data();
      if (account == null ||
          account['role']?.toString().toLowerCase() != 'student' ||
          account['status']?.toString().toLowerCase() != 'approved') {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.accountNotApproved;
      }
      if (currentUser?.uid != user.uid) {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.signedOut;
      }
      return SaveAuthorizationStatus.authorized;
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Unable to verify save authorization after permission denial: '
        'plugin=${error.plugin}, code=${error.code}, '
        'message=${error.message}.',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (error.code == 'unauthenticated') {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.signedOut;
      }
      if (error.code == 'permission-denied') {
        invalidateCurrentVerifiedSession();
        return SaveAuthorizationStatus.securityVerificationFailed;
      }
      if (_isTemporaryNetworkFailure(error.code)) {
        return SaveAuthorizationStatus.temporarilyUnableToVerify;
      }
      return SaveAuthorizationStatus.unableToVerify;
    } catch (error, stackTrace) {
      debugPrint(
        'Unable to verify save authorization after permission denial: '
        'exceptionType=${error.runtimeType}, message=$error.',
      );
      debugPrintStack(stackTrace: stackTrace);
      return SaveAuthorizationStatus.unableToVerify;
    }
  }

  static Future<String> savePermissionDeniedMessage(String feature) async {
    final status = await checkCurrentSaveAuthorizationStatus();
    return switch (status) {
      SaveAuthorizationStatus.signedOut =>
        'You have been signed out. Sign in again before saving $feature.',
      SaveAuthorizationStatus.sessionExpired =>
        'Your active session is no longer valid. Sign in again before saving $feature.',
      SaveAuthorizationStatus.accountNotApproved =>
        'Your student account is not approved for saving $feature. Contact your teacher or administrator.',
      SaveAuthorizationStatus.authorized =>
        'Firestore denied this $feature save even though your active student session is valid. Contact support.',
      SaveAuthorizationStatus.temporarilyUnableToVerify =>
        'Firestore denied this $feature save, but the session could not be verified. Check your connection and sign in again if needed.',
      SaveAuthorizationStatus.securityVerificationFailed =>
        'Firestore denied this $feature save because the account or session could not be authorized. Sign in again or contact support.',
      SaveAuthorizationStatus.unableToVerify =>
        'Firestore denied this $feature save, but the session could not be verified. Check your connection and sign in again if needed.',
    };
  }

  static Future<UserAccount?> restoreSignedInAccount() async {
    final restoreTimer = Stopwatch()..start();
    invalidateCurrentVerifiedSession();
    final user = _auth.currentUser;
    if (user == null) return null;

    final uid = user.uid;
    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_deviceIdKey);
    final cachedSessionId = preferences.getString('$_sessionIdKeyPrefix$uid');
    if (deviceId == null ||
        deviceId.length < 16 ||
        cachedSessionId == null ||
        cachedSessionId.isEmpty) {
      await _discardLocalSession(uid);
      return null;
    }

    final firestoreReadTimer = Stopwatch()..start();
    final snapshots = await Future.wait([
      _sessions.doc(uid).get(const GetOptions(source: Source.server)),
      _users.doc(uid).get(const GetOptions(source: Source.server)),
    ]);
    final sessionSnapshot = snapshots[0];
    final accountSnapshot = snapshots[1];
    if (kDebugMode) {
      debugPrint(
        '[AuthService] Startup session/account server reads completed in '
        '${firestoreReadTimer.elapsedMilliseconds} ms.',
      );
    }
    final session = sessionSnapshot.data();
    if (!sessionSnapshot.exists ||
        session?['deviceId'] != deviceId ||
        session?['sessionId'] != cachedSessionId) {
      debugPrint(
        '[AuthService] Persisted Firebase user has no matching active device '
        'session: uid=$uid, sessionExists=${sessionSnapshot.exists}, '
        'deviceMatches=${session?['deviceId'] == deviceId}, '
        'sessionMatches=${session?['sessionId'] == cachedSessionId}.',
      );
      await _discardLocalSession(uid);
      return null;
    }

    final accountData = accountSnapshot.data();
    var account = accountData == null
        ? null
        : UserAccount.fromJson({...accountData, 'uid': accountSnapshot.id});
    final storedUid = accountData?['uid'];
    final validAccount = account != null &&
        (storedUid == null || storedUid == uid) &&
        account.isApproved &&
        (account.role.toLowerCase() == 'student' ||
            account.isTeacher ||
            account.isAdmin);
    if (!validAccount) {
      debugPrint(
        '[AuthService] Persisted Firebase user has no valid approved account: '
        'uid=$uid, accountExists=${accountSnapshot.exists}, '
        'storedUid=${storedUid ?? '(none)'}, '
        'role=${account?.role ?? '(none)'}, '
        'status=${account?.status ?? '(none)'}.',
      );
      await _releaseLoginSession(uid, deviceId, cachedSessionId);
      await _discardLocalSession(uid);
      return null;
    }

    await preferences.setString('current_user_email', account.email);
    await preferences.setString('current_user_name', account.name);
    await preferences.setString('current_user_role', account.role);
    await preferences.setString('current_user_student_no', account.studentNo);
    await preferences.setString('current_user_lrn', account.lrn);
    await preferences.setString('current_user_address', account.address);
    _rememberVerifiedSession(account, deviceId, cachedSessionId);
    if (kDebugMode) {
      debugPrint(
        '[AuthService] Session restore completed in '
        '${restoreTimer.elapsedMilliseconds} ms.',
      );
    }
    return account;
  }

  static Future<void> _discardLocalSession(String uid) async {
    invalidateCurrentVerifiedSession();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_sessionIdKeyPrefix$uid');
    await _auth.signOut();
  }

  static Future<UserAccount> signIn(String email, String password) async {
    invalidateCurrentVerifiedSession();
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
    final uid = credential.user!.uid;
    String? sessionId;
    String? deviceId;
    try {
      deviceId = await _getDeviceId();
      sessionId = await _claimLoginSession(uid, deviceId);

      var account = await getAccount(uid);
      if (account == null) {
        throw StateError(
          'Your account profile is missing for UID $uid. '
          'Create the users document with this exact ID in the same Firebase project.',
        );
      }
      if (!account.isApproved) {
        throw StateError('Account pending admin approval.');
      }
      if (account.role.toLowerCase() == 'student') {
        account = await _getAccountFromServer(uid);
        if (account == null) {
          throw StateError(
            'The student profile could not be verified after sign-in.',
          );
        }
        if (!account.isApproved) {
          throw StateError('Account pending admin approval.');
        }
        if (account.role.toLowerCase() != 'student') {
          throw StateError('Account has no valid role.');
        }
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_sessionIdKeyPrefix$uid',
        sessionId,
      );
      _rememberVerifiedSession(account, deviceId, sessionId);
      return account;
    } catch (_) {
      var failedSessionId = sessionId;
      failedSessionId ??= sessionId;
      if (failedSessionId != null && deviceId != null) {
        try {
          await _releaseLoginSession(uid, deviceId, failedSessionId);
        } catch (error, stackTrace) {
          debugPrint('Unable to release failed login session: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
      await _auth.signOut();
      rethrow;
    }
  }

  static Future<UserAccount> register({
    required String email,
    required String password,
    required String name,
    required String address,
    required String character,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    UserCredential credential;
    var createdAuthUser = false;
    var operation = 'create Firebase Authentication account';
    try {
      credential = await _auth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      createdAuthUser = true;
    } on FirebaseAuthException catch (error) {
      debugPrint(
        'Student registration authentication attempt failed '
        '(operation=create account, code=${error.code}, '
        'message=${error.message ?? '(none)'}).',
      );
      if (error.code != 'email-already-in-use') rethrow;
      operation = 'sign in to recover existing Firebase Authentication account';
      try {
        credential = await _auth.signInWithEmailAndPassword(
          email: normalizedEmail,
          password: password,
        );
      } on FirebaseAuthException catch (recoveryError, stackTrace) {
        debugPrint(
          'Student registration recovery sign-in failed '
          '(code=${recoveryError.code}, '
          'message=${recoveryError.message ?? '(none)'}).',
        );
        debugPrintStack(stackTrace: stackTrace);
        rethrow;
      }
    }

    final authUser = credential.user;
    if (authUser == null) {
      debugPrint(
        'Student registration failed: Firebase Auth returned no user '
        'after authentication.',
      );
      throw StateError('Firebase Auth did not return an authenticated user.');
    }
    var profileTransactionCommitted = false;
    try {
      operation = 'verify authenticated account';
      final idToken = await authUser.getIdToken();
      if (idToken == null ||
          idToken.isEmpty ||
          _auth.currentUser?.uid != authUser.uid) {
        throw StateError(
          'The authenticated Firebase user could not be verified before '
          'creating the student profile.',
        );
      }

      operation = 'create or recover Firestore student profile';
      final userRef = _users.doc(authUser.uid);
      final counterRef =
          FirebaseFirestore.instance.collection('systemCounters').doc(
                'studentNumbers',
              );
      final normalizedName = name.trim();
      final normalizedAddress = address.trim();
      final normalizedCharacter = UserAccount.normalizeCharacterId(character);
      int? attemptedLastNumber;
      var contentionRetries = 0;
      late String assignedStudentNo;
      while (true) {
        try {
          assignedStudentNo = await FirebaseFirestore.instance
              .runTransaction<String>((transaction) async {
            final userSnapshot = await transaction.get(userRef);
            final counterSnapshot = await transaction.get(counterRef);

            if (userSnapshot.exists) {
              throw StateError(
                'A student profile already exists for this account. '
                'Sign in instead.',
              );
            }

            final counter = counterSnapshot.data();
            final lastNumber = counter?['lastNumber'];
            if (!counterSnapshot.exists ||
                lastNumber is! int ||
                lastNumber < 0 ||
                lastNumber >= 9007199254740991 ||
                counter?['schemaVersion'] != 2 ||
                counter?['migrationState'] != 'complete') {
              throw StateError(
                'Student Number registration is not initialized. '
                'Contact an administrator.',
              );
            }
            attemptedLastNumber = lastNumber;

            final nextNumber = lastNumber + 1;
            final studentNo = nextNumber.toString();
            transaction.update(counterRef, {
              'lastNumber': nextNumber,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            transaction.set(userRef, {
              'uid': authUser.uid,
              'email': normalizedEmail,
              'role': 'student',
              'status': 'pending',
              'name': normalizedName,
              'address': normalizedAddress,
              'studentNo': studentNo,
              'character': normalizedCharacter,
              'profilePhotoUrl': UserAccount.profileImageAssetPathForCharacter(
                normalizedCharacter,
              ),
              'tutorialEligible': true,
              'tutorialCompleted': false,
              'createdAt': FieldValue.serverTimestamp(),
            });
            return studentNo;
          });
          profileTransactionCommitted = true;
          break;
        } on FirebaseException catch (error) {
          if (!const {'permission-denied', 'aborted'}.contains(error.code) ||
              attemptedLastNumber == null ||
              contentionRetries >= 20) {
            rethrow;
          }

          final latestCounter = await counterRef.get(
            const GetOptions(source: Source.server),
          );
          final latestNumber = latestCounter.data()?['lastNumber'];
          final attemptedNumber = attemptedLastNumber;
          if (latestNumber is! int ||
              attemptedNumber == null ||
              latestNumber <= attemptedNumber) {
            rethrow;
          }

          contentionRetries++;
          final delayMilliseconds = 25 * contentionRetries;
          await Future<void>.delayed(
            Duration(
              milliseconds: delayMilliseconds > 500 ? 500 : delayMilliseconds,
            ),
          );
        }
      }
      final studentNo = assignedStudentNo;
      final account = UserAccount(
        uid: authUser.uid,
        email: normalizedEmail,
        role: 'student',
        status: 'pending',
        name: normalizedName,
        address: normalizedAddress,
        studentNo: studentNo,
        character: normalizedCharacter,
        profilePhotoUrl:
            UserAccount.profileImageAssetPathForCharacter(normalizedCharacter),
      );
      debugPrint(
        'Student registration profile saved '
        '(uid=${authUser.uid}, studentNo=${account.studentNo}).',
      );

      operation = 'initialize registration leaderboard entry';
      try {
        await LeaderboardService.createRegistrationEntry(
          uid: authUser.uid,
          displayName: name,
        );
      } catch (error, stackTrace) {
        debugPrint(
            'Unable to initialize pending student leaderboard entry: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return account;
    } catch (error, stackTrace) {
      final code = error is FirebaseException ? error.code : 'not-applicable';
      debugPrint(
        'Student registration failed: operation=$operation, '
        'authUserCreated=$createdAuthUser, uid=${authUser.uid}, '
        'type=${error.runtimeType}, code=$code, error=$error.',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (createdAuthUser &&
          !profileTransactionCommitted &&
          _auth.currentUser?.uid == authUser.uid) {
        try {
          final profile = await _users.doc(authUser.uid).get(
                const GetOptions(source: Source.server),
              );
          if (!profile.exists) {
            await authUser.delete();
            debugPrint(
              'Removed Firebase Authentication account without a saved '
              'student profile (uid=${authUser.uid}).',
            );
          }
        } catch (cleanupError, cleanupStackTrace) {
          debugPrint(
            'Unable to verify or remove the newly created Authentication '
            'account after registration failed '
            '(uid=${authUser.uid}, error=$cleanupError). '
            'The same email and password can be used to retry registration.',
          );
          debugPrintStack(stackTrace: cleanupStackTrace);
        }
      }
      rethrow;
    } finally {
      try {
        await _auth.signOut();
      } catch (error, stackTrace) {
        debugPrint('Unable to sign out after registration: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  static Future<UserAccount?> getAccount(String uid) async {
    final snapshot = await _users.doc(uid).get();
    if (!snapshot.exists) return null;
    return UserAccount.fromJson({...snapshot.data()!, 'uid': snapshot.id});
  }

  static Future<UserAccount?> _getAccountFromServer(String uid) async {
    final snapshot = await _users.doc(uid).get(
          const GetOptions(source: Source.server),
        );
    if (!snapshot.exists) return null;
    return UserAccount.fromJson({...snapshot.data()!, 'uid': snapshot.id});
  }

  static Future<List<UserAccount>> loadAccounts({
    bool forceServer = false,
  }) async {
    final query = _users.orderBy('name');
    final snapshot = forceServer
        ? await query.get(const GetOptions(source: Source.server))
        : await query.get();
    return snapshot.docs
        .map((doc) => UserAccount.fromJson({...doc.data(), 'uid': doc.id}))
        .toList();
  }

  static Stream<List<UserAccount>> watchAccounts() {
    return _users.orderBy('name').snapshots().map(
          (snapshot) => snapshot.docs
              .map(
                (doc) => UserAccount.fromJson({...doc.data(), 'uid': doc.id}),
              )
              .toList(),
        );
  }

  static Future<void> sendStudentPasswordResetEmail({
    required String studentUid,
    required String registeredEmail,
  }) async {
    final admin = currentUser;
    if (admin == null) {
      throw StateError('Sign in as an administrator before continuing.');
    }

    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_deviceIdKey);
    final sessionId = preferences.getString('$_sessionIdKeyPrefix${admin.uid}');
    if (deviceId == null || sessionId == null || sessionId.isEmpty) {
      throw StateError('The administrator device session is not valid.');
    }

    final adminRef = _users.doc(admin.uid);
    final sessionRef = _sessions.doc(admin.uid);
    final studentRef = _users.doc(studentUid);
    final snapshots = await Future.wait([
      adminRef.get(const GetOptions(source: Source.server)),
      sessionRef.get(const GetOptions(source: Source.server)),
      studentRef.get(const GetOptions(source: Source.server)),
    ]);
    final adminData = snapshots[0].data();
    final sessionData = snapshots[1].data();
    final studentData = snapshots[2].data();
    if (currentUser?.uid != admin.uid ||
        adminData?['role']?.toString().toLowerCase() != 'admin' ||
        adminData?['status']?.toString().toLowerCase() != 'approved' ||
        sessionData?['deviceId'] != deviceId ||
        sessionData?['sessionId'] != sessionId) {
      throw StateError(
        'The current account does not have a valid administrator session.',
      );
    }

    final normalizedEmail = registeredEmail.trim().toLowerCase();
    if (studentData == null ||
        studentData['role']?.toString().toLowerCase() != 'student' ||
        studentData['email']?.toString().trim().toLowerCase() !=
            normalizedEmail) {
      throw StateError(
        'The selected student account or registered email has changed. '
        'Reload the student list and try again.',
      );
    }

    await _auth.sendPasswordResetEmail(email: normalizedEmail);
  }

  static Future<void> approveAccountAsTeacher(String uid) async {
    final targetUid = uid.trim();
    if (targetUid.isEmpty || targetUid.contains('/')) {
      throw ArgumentError.value(uid, 'uid');
    }

    final targetRef = _users.doc(targetUid);
    await FirebaseFirestore.instance.runTransaction<void>((transaction) async {
      final snapshot = await transaction.get(targetRef);
      if (!snapshot.exists) {
        throw StateError('The selected account no longer exists.');
      }

      final account = snapshot.data()!;
      final role = account['role'];
      final status = account['status'];
      if (role == 'teacher' && status == 'approved') {
        return;
      }
      if (role != 'student' || (status != 'pending' && status != 'approved')) {
        throw StateError(
          'Only an existing student account can be approved as a teacher.',
        );
      }

      transaction.update(targetRef, {
        'role': 'teacher',
        'status': 'approved',
      });
    });
  }

  static Future<void> approveStudentAccount(String uid) =>
      _updatePendingStudentStatus(uid, 'approved');

  static Future<void> rejectStudentAccount(String uid) =>
      _updatePendingStudentStatus(uid, 'rejected');

  static Future<void> _updatePendingStudentStatus(
    String uid,
    String status,
  ) async {
    if (status != 'approved' && status != 'rejected') {
      throw ArgumentError.value(status, 'status');
    }
    final targetUid = uid.trim();
    if (targetUid.isEmpty || targetUid.contains('/')) {
      throw ArgumentError.value(uid, 'uid');
    }

    final targetRef = _users.doc(targetUid);
    await FirebaseFirestore.instance.runTransaction<void>((transaction) async {
      final snapshot = await transaction.get(targetRef);
      if (!snapshot.exists) {
        throw StateError('The selected account no longer exists.');
      }

      final account = snapshot.data()!;
      if (account['role'] != 'student' || account['status'] != 'pending') {
        throw StateError('Only pending student accounts can be updated.');
      }

      transaction.update(targetRef, {'status': status});
    });
  }

  static Future<void> updateAccount(UserAccount account) {
    final currentLrn = account.lrn.trim();
    return _users.doc(account.uid).get().then((snapshot) {
      if ((snapshot.data()?['lrn']?.toString() ?? '') != currentLrn ||
          (snapshot.data()?['studentNo']?.toString() ?? '') !=
              account.studentNo) {
        throw StateError('An account Student No. cannot be changed.');
      }
      final data = account.toJson()..remove('uid');
      return _users.doc(account.uid).update(data);
    });
  }

  static Future<void> deleteAccount(UserAccount account) async {
    final uid = account.uid.trim();
    if (uid.isEmpty || uid.contains('/')) {
      throw ArgumentError.value(account.uid, 'account.uid');
    }

    final userRef = _users.doc(uid);
    final snapshot = await userRef.get(
      const GetOptions(source: Source.server),
    );
    if (!snapshot.exists) {
      throw StateError('The selected account no longer exists.');
    }

    final role = snapshot.data()?['role']?.toString().toLowerCase();
    if (role != 'student' && role != 'teacher') {
      throw StateError('Only student or teacher accounts can be deleted here.');
    }

    final batch = FirebaseFirestore.instance.batch()
      ..delete(userRef)
      ..delete(_sessions.doc(uid));
    await batch.commit();
  }

  static Future<void> updateCurrentProfile({
    required String name,
    required String address,
    String? grade,
  }) async {
    final user = currentUser;
    if (user == null) throw StateError('Not signed in.');
    final userDocument = _users.doc(user.uid);
    final requestedGrade = grade?.trim();
    final updates = <String, dynamic>{};
    try {
      final snapshot = await userDocument.get(
        const GetOptions(source: Source.server),
      );
      final account = snapshot.data();
      if (!snapshot.exists || account == null) {
        throw StateError('The current user profile no longer exists.');
      }

      if (account['name'] != name) updates['name'] = name;
      if (account['address'] != address) updates['address'] = address;
      if (requestedGrade != null && account['grade'] != requestedGrade) {
        updates['grade'] = requestedGrade;
      }
      if (updates.isEmpty) {
        debugPrint(
          'Firestore profile fields are already current '
          '(uid=${user.uid}); skipping unchanged update.',
        );
        return;
      }

      await userDocument.update(updates);
      debugPrint(
        'Firestore profile fields update succeeded '
        '(uid=${user.uid}, fields=${updates.keys.toList()}).',
      );
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Firestore profile fields update failed '
        '(uid=${user.uid}, path=${userDocument.path}, '
        'fields=${updates.keys.toList()}, '
        'plugin=${error.plugin}, code=${error.code}, '
        'message=${error.message ?? '(none)'}).',
      );
      debugPrintStack(stackTrace: stackTrace);
      await _logProfileSaveContext(
        user.uid,
        requestedName: name,
        requestedAddress: address,
      );
      rethrow;
    }
  }

  static Future<void> requestCurrentEmailChange({
    required String newEmail,
    required String currentPassword,
  }) async {
    final user = currentUser;
    if (user == null || user.email == null) throw StateError('Not signed in.');
    final credential = EmailAuthProvider.credential(
      email: user.email!,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
    await user.verifyBeforeUpdateEmail(newEmail.trim());
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_pendingEmailChangeKeyPrefix${user.uid}',
        newEmail.trim().toLowerCase(),
      );
    } catch (error, stackTrace) {
      debugPrint('Could not cache pending profile email change: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static Future<String?> getPendingCurrentEmailChange() async {
    final user = currentUser;
    if (user == null) return null;
    final preferences = await SharedPreferences.getInstance();
    final pendingEmail = preferences.getString(
      '$_pendingEmailChangeKeyPrefix${user.uid}',
    );
    if (pendingEmail == null || pendingEmail.trim().isEmpty) return null;
    return pendingEmail.trim().toLowerCase();
  }

  static Future<void> syncVerifiedCurrentEmail() async {
    final user = currentUser;
    if (user == null) return;
    final preferences = await SharedPreferences.getInstance();
    final pendingEmail = preferences.getString(
      '$_pendingEmailChangeKeyPrefix${user.uid}',
    );
    if (pendingEmail == null || pendingEmail.isEmpty) return;
    await user.reload();
    final refreshedUser = currentUser;
    final email = refreshedUser?.email?.trim().toLowerCase();
    if (refreshedUser == null ||
        email == null ||
        email.isEmpty ||
        email != pendingEmail ||
        !refreshedUser.emailVerified) {
      return;
    }
    await refreshedUser.getIdToken(true);
    try {
      await _users.doc(refreshedUser.uid).update({'email': email});
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Firestore verified-email synchronization failed '
        '(uid=${refreshedUser.uid}, '
        'path=users/${refreshedUser.uid}, operation=update, '
        'fields=[email], plugin=${error.plugin}, code=${error.code}, '
        'message=${error.message ?? '(none)'}).',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
    await preferences.remove(
      '$_pendingEmailChangeKeyPrefix${refreshedUser.uid}',
    );
  }

  static Future<String?> getCurrentProfilePhotoData() async {
    final user = currentUser;
    if (user == null) throw StateError('Not signed in.');
    final snapshot = await _profilePhotoDocument(user.uid).get();
    final data = snapshot.data()?['data'];
    return data is String ? data : null;
  }

  static Future<void> updateCurrentProfilePhotoData(
    String? photoDataUrl,
  ) async {
    final user = currentUser;
    if (user == null) throw StateError('Not signed in.');
    final firestore = FirebaseFirestore.instance;
    final userDocument = _users.doc(user.uid);
    final photoDocument = _profilePhotoDocument(user.uid);
    final profilePhotoUrl = photoDataUrl == null || photoDataUrl.isEmpty
        ? ''
        : firestoreProfilePhotoUrl;
    var isStudent = false;
    final operations = <String>[
      'read ${userDocument.path}',
    ];
    try {
      await firestore.runTransaction((transaction) async {
        final userSnapshot = await transaction.get(userDocument);
        if (!userSnapshot.exists) {
          throw StateError('The current user profile no longer exists.');
        }
        isStudent =
            userSnapshot.data()?['role']?.toString().toLowerCase() == 'student';

        final photoSnapshot = profilePhotoUrl.isEmpty
            ? await transaction.get(photoDocument)
            : null;
        if (userSnapshot.data()?['profilePhotoUrl'] != profilePhotoUrl) {
          transaction.update(userDocument, {
            'profilePhotoUrl': profilePhotoUrl,
          });
          operations.add(
            'update ${userDocument.path} fields=[profilePhotoUrl]',
          );
        }
        if (profilePhotoUrl.isEmpty) {
          if (photoSnapshot?.exists == true) {
            transaction.delete(photoDocument);
            operations.add('delete ${photoDocument.path}');
          }
        } else {
          transaction.set(photoDocument, {'data': photoDataUrl});
          operations.add('set ${photoDocument.path} fields=[data]');
        }
      });
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Firestore profile photo transaction failed '
        '(uid=${user.uid}, operations=${operations.join('; ')}; '
        'plugin=${error.plugin}, code=${error.code}, '
        'message=${error.message ?? '(none)'}).',
      );
      debugPrintStack(stackTrace: stackTrace);
      await _logProfileSaveContext(
        user.uid,
        requestedPhotoDataUrl: photoDataUrl,
      );
      rethrow;
    }
    if (isStudent) {
      await LeaderboardService.ensureCurrentEntry();
    }
  }

  static Future<String> _getDeviceId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_deviceIdKey);
    if (existing != null && existing.length >= 16) return existing;

    final random = Random.secure();
    final deviceId = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await preferences.setString(_deviceIdKey, deviceId);
    return deviceId;
  }

  static Future<String> _claimLoginSession(String uid, String deviceId) {
    final sessionRef = _sessions.doc(uid);
    return FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(sessionRef);
      if (snapshot.exists) {
        final data = snapshot.data()!;
        if (data['deviceId'] != deviceId) {
          throw StateError(
            'This account is already active on another device. '
            'Sign out there first, or ask an admin to clear its session.',
          );
        }
        final existingSessionId = data['sessionId'];
        if (existingSessionId is! String || existingSessionId.isEmpty) {
          throw StateError(
            'This device session is incomplete. Ask an administrator to clear it.',
          );
        }
        return existingSessionId;
      }

      final sessionId = _generateSessionId();
      transaction.set(sessionRef, {
        'deviceId': deviceId,
        'sessionId': sessionId,
        'claimedAt': FieldValue.serverTimestamp(),
      });
      return sessionId;
    });
  }

  static String _generateSessionId() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<void> _releaseLoginSession(
    String uid,
    String deviceId,
    String sessionId,
  ) async {
    final sessionRef = _sessions.doc(uid);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(sessionRef);
      if (!snapshot.exists) return;
      final data = snapshot.data()!;
      if (data['deviceId'] == deviceId && data['sessionId'] == sessionId) {
        transaction.delete(sessionRef);
      }
    });
  }

  static Future<void> signOut() async {
    final currentUid = _auth.currentUser?.uid;
    final uid = currentUid;
    invalidateCurrentVerifiedSession();
    try {
      final preferences = await SharedPreferences.getInstance();
      String? sessionId = uid == null
          ? null
          : preferences.getString('$_sessionIdKeyPrefix$uid');
      if (uid != null && _auth.currentUser != null) {
        final deviceId = await _getDeviceId();
        if (sessionId == null) {
          final snapshot = await _sessions.doc(uid).get();
          final data = snapshot.data();
          if (data?['deviceId'] == deviceId && data?['sessionId'] is String) {
            sessionId = data!['sessionId'] as String;
          }
        }
        if (sessionId != null) {
          await _releaseLoginSession(uid, deviceId, sessionId);
        }
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Unable to release the server session during sign-out; '
        'signing out locally: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (uid != null) {
        try {
          final preferences = await SharedPreferences.getInstance();
          await preferences.remove('$_sessionIdKeyPrefix$uid');
        } catch (error, stackTrace) {
          debugPrint('Unable to clear the local session marker: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
      await _auth.signOut();
    }
  }

  static Future<void> clearAccountLoginSession(String uid) async {
    await _sessions.doc(uid).delete();
  }
}
