import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/screens/register_screen.dart';

Future<void> _enterValidRegistration(WidgetTester tester) async {
  final fields = find.byType(TextFormField);
  expect(fields, findsNWidgets(6));
  await tester.enterText(fields.at(1), 'Student Name');
  await tester.enterText(fields.at(2), 'School Address');
  await tester.enterText(fields.at(3), 'student@example.com');
  await tester.enterText(fields.at(4), 'password123');
  await tester.enterText(fields.at(5), 'password123');
}

Widget _registrationApp({
  required StudentRegistrationHandler onRegister,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RegisterScreen(onRegister: onRegister),
              ),
            ),
            child: const Text('Open Registration'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('registration fields have persistent labels on phone and desktop',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in [const Size(320, 568), const Size(1510, 768)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
            home: RegisterScreen(
                onRegister: ({
          required email,
          required password,
          required name,
          required address,
          required character,
        }) async =>
                    '41')),
      );
      await tester.pumpAndSettle();

      for (final label in [
        'Student No.',
        'Name',
        'Address',
        'Email',
        'Password',
        'Confirm Password',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(
        find.text(
          'Please use an email address that you or your parent/guardian can access. This will help you recover your account if you forget your password.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('submits all registration details and selected character',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    Map<String, String>? submitted;
    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) async {
        submitted = {
          'email': email,
          'password': password,
          'name': name,
          'address': address,
          'character': character,
        };
        return '42';
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Girl'));
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(submitted, {
      'email': 'student@example.com',
      'password': 'password123',
      'name': 'Student Name',
      'address': 'School Address',
      'character': 'girl',
    });
    expect(find.text('Student No.'), findsOneWidget);
    expect(find.textContaining('42'), findsNWidgets(2));
    expect(find.text('Continue to Login'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(TextFormField).first,
              matching: find.byType(TextField),
            ),
          )
          .readOnly,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores repeated submissions while registration is in progress',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    var registrationCalls = 0;
    final registration = Completer<String>();
    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) {
        registrationCalls++;
        return registration.future;
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    final submitButtonCenter = tester.getCenter(submitButton);
    await tester.tapAt(submitButtonCenter);
    await tester.tapAt(submitButtonCenter);
    await tester.pump();

    expect(registrationCalls, 1);
    registration.complete('43');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shows the committed Student No. when a delayed registration completes',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    var registrationCalls = 0;
    final registration = Completer<String>();
    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) {
        registrationCalls++;
        return registration.future;
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pump();

    expect(registrationCalls, 1);
    expect(find.text('Account Created'), findsNothing);
    registration.complete('44');
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Your Student No. is 44. Save this number. '
        'Wait for admin approval before signing in.',
      ),
      findsOneWidget,
    );
    expect(find.text('Account Created'), findsOneWidget);
    expect(registrationCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shows actual Firebase Auth code and message on registration error',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) async {
        throw FirebaseAuthException(
          code: 'operation-not-allowed',
          message: 'Email sign-in is disabled.',
        );
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Registration failed (operation-not-allowed): Email sign-in is disabled.',
      ),
      findsOneWidget,
    );
    expect(find.text('Create Account'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows actual Firestore code and message on profile write error',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) async {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message: 'The registration profile failed rule validation.',
        );
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Firestore denied profile creation (permission-denied): The registration profile failed rule validation.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the callable registration error without mislabeling it',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) async {
        throw FirebaseFunctionsException(
          code: 'internal',
          message: 'Registration failed while attempting to '
              'atomically save the student profile and Student No. '
              '(backend code: 9). Retry with the same email and password.',
        );
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Registration failed while attempting to atomically save the student profile and Student No. (backend code: 9). Retry with the same email and password.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Firestore registration failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains when the registration function is not deployed',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);

    await tester.pumpWidget(_registrationApp(
      onRegister: ({
        required email,
        required password,
        required name,
        required address,
        required character,
      }) async {
        throw FirebaseFunctionsException(
          code: 'not-found',
          message: 'NOT_FOUND: registerStudent',
        );
      },
    ));
    await tester.tap(find.text('Open Registration'));
    await tester.pumpAndSettle();
    await _enterValidRegistration(tester);
    final submitButton = find.text('Create Account').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The registration service is not deployed for this Firebase project. An administrator must deploy the Firebase Functions before registration can continue.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
