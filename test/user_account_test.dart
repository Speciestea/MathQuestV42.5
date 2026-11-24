import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/models/user_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('does not create a synthetic administrator for an empty local store',
      () async {
    SharedPreferences.setMockInitialValues({});

    await UserAccount.ensureDefaultAdmin();

    expect(await UserAccount.loadAll(), isEmpty);
  });

  test('migrates a legacy local student account without adding an admin',
      () async {
    SharedPreferences.setMockInitialValues({
      'user_email': 'student@example.com',
      'user_password': 'legacy-local-password',
      'user_name': 'Legacy Student',
      'user_address': 'School',
      'user_lrn': '001234567890',
    });

    await UserAccount.ensureDefaultAdmin();

    final accounts = await UserAccount.loadAll();
    expect(accounts, hasLength(1));
    expect(accounts.single.email, 'student@example.com');
    expect(accounts.single.role, 'student');
    expect(accounts.single.lrn, '001234567890');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('user_password'), isFalse);
    expect(prefs.containsKey('user_email'), isFalse);
  });

  test('preserves an existing local administrator without synthesizing one',
      () async {
    SharedPreferences.setMockInitialValues({
      UserAccount.prefsKey: '[{"email":"existing@example.com",'
          '"role":"admin","status":"approved","name":"Existing Admin",'
          '"address":""}]',
    });

    await UserAccount.ensureDefaultAdmin();

    final accounts = await UserAccount.loadAll();
    expect(accounts, hasLength(1));
    expect(accounts.single.email, 'existing@example.com');
    expect(accounts.single.isAdmin, isTrue);
  });

  test('serializes the selected character with the user profile', () {
    final account = UserAccount(
      email: 'student@example.com',
      role: 'student',
      status: 'pending',
      name: 'Student',
      address: 'School',
      lrn: '123456789012',
      character: 'girl',
      profilePhotoUrl: 'https://example.com/profile-photo',
    );

    expect(account.toJson()['character'], 'girl');
    expect(
      UserAccount.fromJson(account.toJson()).profilePhotoUrl,
      'https://example.com/profile-photo',
    );
  });

  test('reads and preserves Student No. without removing legacy LRN data', () {
    final account = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'approved',
      'name': 'Student',
      'address': 'School',
      'studentNo': 'MQ-000123',
      'lrn': '001234567890',
    });

    expect(account.studentNo, 'MQ-000123');
    expect(account.lrn, '001234567890');
    expect(
        account.copyWith(name: 'Updated').toJson()['studentNo'], 'MQ-000123');
    expect(account.toJson()['lrn'], '001234567890');
  });

  test('persists either selected registration character', () {
    for (final character in [
      'boy',
      'girl',
      'character3',
      'character4',
      'character5',
    ]) {
      final account = UserAccount(
        email: 'student@example.com',
        role: 'student',
        status: 'pending',
        name: 'Student',
        address: 'School',
        lrn: '123456789012',
        character: character,
      );

      expect(account.toJson()['character'], character);
      expect(UserAccount.fromJson(account.toJson()).character, character);
    }
  });

  test('maps selected characters to their profile image assets', () {
    expect(
      UserAccount.profileImageAssetPathForCharacter('character3'),
      'assets/images/player/T-rex.png',
    );
    expect(
      UserAccount.profileImageAssetPathForCharacter('character4'),
      'assets/images/player/Pride Femme.png',
    );
    expect(
      UserAccount.profileImageAssetPathForCharacter('character5'),
      'assets/images/player/Pride Masc.png',
    );
  });

  test('defaults legacy profiles to boy', () {
    final account = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'pending',
      'name': 'Student',
      'address': 'School',
      'lrn': '123456789012',
    });

    expect(account.character, 'boy');
    expect(account.profilePhotoUrl, isEmpty);
  });

  test('recognizes teacher roles from the Firestore account profile', () {
    final teacher = UserAccount.fromJson({
      'uid': 'SG58XfeEt9eP7xdUoFaC7vT7Zte2',
      'email': 'teacher@example.com',
      'role': 'teacher',
      'status': 'approved',
      'name': 'Rhodney Nano',
    });

    expect(teacher.isTeacher, isTrue);
    expect(teacher.isAdmin, isFalse);
    expect(teacher.isApproved, isTrue);

    final student = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'approved',
      'name': 'Student',
    });
    expect(student.isTeacher, isFalse);
  });

  test('only approved accounts qualify for login access', () {
    for (final status in ['pending', 'rejected']) {
      final account = UserAccount.fromJson({
        'email': 'student@example.com',
        'role': 'student',
        'status': status,
        'name': 'Student',
      });

      expect(account.isApproved, isFalse);
    }

    final approved = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'approved',
      'name': 'Student',
    });
    expect(approved.isApproved, isTrue);
  });

  test('does not infer a student role when profile role data is missing', () {
    final account = UserAccount.fromJson({
      'email': 'unknown@example.com',
      'status': 'approved',
      'name': 'Unknown Role',
    });

    expect(account.role, isEmpty);
    expect(account.isTeacher, isFalse);
    expect(account.isAdmin, isFalse);
  });

  test('persists an inline profile photo in the account record', () {
    const photoDataUrl = 'data:image/jpeg;base64,YWJj';
    final account = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'approved',
      'name': 'Student',
      'address': 'School',
      'lrn': '123456789012',
      'profilePhotoUrl': photoDataUrl,
    });

    expect(account.toJson()['profilePhotoUrl'], photoDataUrl);
  });

  test('reads and preserves an explicitly stored gender', () {
    final account = UserAccount.fromJson({
      'email': 'teacher@example.com',
      'role': 'teacher',
      'status': 'approved',
      'name': 'Teacher',
      'gender': 'Female',
    });

    expect(account.gender, 'Female');
    expect(account.toJson()['gender'], 'Female');
    expect(account.copyWith(name: 'Updated').gender, 'Female');
  });

  test('leaves unspecified gender empty without inferring from other fields',
      () {
    final account = UserAccount.fromJson({
      'email': 'teacher@example.com',
      'role': 'teacher',
      'status': 'approved',
      'name': 'Jane Teacher',
      'character': 'girl',
    });

    expect(account.gender, isEmpty);
    expect(account.toJson().containsKey('gender'), isFalse);
  });

  test('stores student grade separately from the account role', () {
    final account = UserAccount.fromJson({
      'email': 'student@example.com',
      'role': 'student',
      'status': 'approved',
      'name': 'Student',
      'grade': 'Grade 7',
      'lrn': '001234567890',
    });

    expect(account.role, 'student');
    expect(account.grade, 'Grade 7');
    expect(account.lrn, '001234567890');
    expect(account.copyWith(grade: 'Grade 7').toJson()['role'], 'student');
  });

  test('sorts displayed accounts by case-insensitive name with safe fallbacks',
      () {
    UserAccount account({
      required String uid,
      required String name,
      required String email,
    }) =>
        UserAccount(
          uid: uid,
          email: email,
          role: 'student',
          status: 'approved',
          name: name,
          address: '',
          lrn: '',
        );

    final unsorted = [
      account(uid: 'z', name: '  ', email: 'zebra@example.com'),
      account(uid: 'b', name: 'alice smith', email: 'b@example.com'),
      account(uid: 'a', name: 'Alice Smith', email: 'a@example.com'),
      account(uid: 'c', name: 'Bob Jones', email: 'bob@example.com'),
    ];

    final sorted = UserAccount.sortAccountsByDisplayName(unsorted);

    expect(
      sorted.map((account) => account.uid).toList(),
      ['a', 'b', 'c', 'z'],
    );
    expect(unsorted.first.uid, 'z');
  });
}
