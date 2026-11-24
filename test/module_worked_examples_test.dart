import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/screens/module_lesson_screen.dart';
import 'package:flutter_mathquest/services/user_progress_service.dart';
import 'package:flutter_mathquest/worksheet_lesson_data.dart';

void main() {
  test('every existing module has a complete, distinct worked example', () {
    const expectedAnswers = {
      'Adding Unlike Fractions': '11/12',
      'Dividing Fractions': '9/10',
      'Adding Decimals': '6.35',
      'Identifying Plane and Solid Figures':
          'The ball is a solid figure; the coin face is a plane figure.',
      'Calculating Speed': '28 km/h',
      'Area of a Composite Figure': '21 square units',
      'Surface Area of a Cube': '54 square centimeters',
      'Listing Possible Outcomes': '6 combinations',
      'Subtracting a Negative Integer': '−5',
    };

    for (final moduleId in worksheetModuleIds) {
      final examples = moduleWorkedExamples
          .where((example) => example.moduleId == moduleId)
          .toList();
      expect(examples, isNotEmpty, reason: moduleId);
      for (final example in examples) {
        expect(example.problem, isNotEmpty);
        expect(example.solutionSteps.length, greaterThanOrEqualTo(2));
        expect(example.solutionSteps.every((step) => step.isNotEmpty), isTrue);
        expect(example.finalAnswer, isNotEmpty);
        expect(example.finalAnswer, expectedAnswers[example.title]);
        expect(example.gameModeTip, isNotEmpty);
        expect(
          worksheetLessons
              .where((lesson) => lesson.moduleId == moduleId)
              .any((lesson) => lesson.question == example.problem),
          isFalse,
          reason: 'Worked examples should not copy a Game Mode question.',
        );
      }
    }
  });

  testWidgets('each unlocked module displays its problem-solving examples',
      (tester) async {
    final progress = UserProgress(
      completedLevels: const [8, 15, 20, 25, 30, 35, 41, 42],
      completedNpcQuestions: const [],
      unlockedLevels: 1,
      questAttempts: 0,
      maxUnlockedSubLevel: const {},
    );
    final access = WorksheetModuleAccess(
      sessionVerified: true,
      progress: progress,
      usingCachedProgress: true,
    );

    for (final moduleId in worksheetModuleIds) {
      final moduleIndex = worksheetModuleIds.indexOf(moduleId);
      final examples = moduleWorkedExamples
          .where((example) => example.moduleId == moduleId)
          .toList();
      await tester.pumpWidget(
        MaterialApp(
          home: ModuleLessonScreen(
            key: ValueKey(moduleId),
            module: {
              'id': moduleId,
              'name': worksheetModuleNames[moduleIndex],
            },
            loadModuleAccess: ({required refreshFromServer}) async => access,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Step-by-Step Problem-Solving'), findsOneWidget);
      expect(find.text('Problem'), findsWidgets);
      expect(find.text('Solution'), findsWidgets);
      expect(find.text('Step-by-Step Explanation'), findsWidgets);
      expect(find.text('Final Answer'), findsWidgets);
      expect(find.text('Try This Method in Game Mode'), findsWidgets);
      for (final example in examples) {
        expect(find.text(example.problem), findsOneWidget);
        expect(find.text(example.finalAnswer), findsWidgets);
      }
      expect(find.text('This module is locked.'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
