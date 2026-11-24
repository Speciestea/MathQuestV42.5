import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/screens/home_screen.dart';

const _practiceExplanation =
    'Practice Mode allows you to practice and improve your mathematical '
    'skills anytime, even without an internet connection. You can answer '
    'questions and challenge yourself at your own pace. Your scores in '
    'Practice Mode are for personal practice only and will not be '
    'submitted to or affect the official Leaderboards or Rankings. Use '
    'this mode to review what you have learned, strengthen your '
    'problem-solving skills, and prepare yourself for the main game. '
    'Remember, Practice Mode is designed for learning and improvement, '
    'so feel free to practice as much as you want!';

Future<void> _expectPracticeStep(WidgetTester tester) async {
  for (var step = 0; step < 10; step++) {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  expect(find.text('Practice Mode'), findsNWidgets(2));
  expect(find.text(_practiceExplanation), findsOneWidget);
  expect(find.text('11/11'), findsOneWidget);
  final practiceCard = find.byKey(const ValueKey('home-menu-Practice Mode'));
  expect(practiceCard, findsOneWidget);
  expect(
    tester.getRect(practiceCard).top,
    greaterThan(
      tester
          .getRect(
            find.byKey(const ValueKey('home-menu-Leaderboard')),
          )
          .top,
    ),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('first-time Home tutorial explains and targets Practice Mode',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 852);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(tutorialStatusCheck: () async => true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to MathQuest!'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-help-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-help-button')));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to MathQuest!'), findsOneWidget);
    await _expectPracticeStep(tester);
  });

  testWidgets("Adventurer's Guide explains Practice Mode", (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 852);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(tutorialStatusCheck: () async => false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome to MathQuest!'), findsNothing);
    expect(find.byKey(const ValueKey('home-help-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-help-button')));
    await tester.pumpAndSettle();

    await _expectPracticeStep(tester);
  });
}
