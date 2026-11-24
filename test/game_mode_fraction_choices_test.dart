import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/game/npc_question.dart';
import 'package:flutter_mathquest/worksheet_lesson_data.dart';

double _fractionValue(String value) {
  final mixed = RegExp(r'^(-?)(\d+)\s+(\d+)/(\d+)$').firstMatch(value);
  if (mixed != null) {
    final sign = mixed.group(1) == '-' ? -1 : 1;
    return sign *
        (int.parse(mixed.group(2)!) +
            int.parse(mixed.group(3)!) / int.parse(mixed.group(4)!));
  }

  final fraction = RegExp(r'^(-?\d+)(?:/(\d+))?$').firstMatch(value);
  if (fraction == null) {
    throw FormatException('Expected a fraction answer, got "$value".');
  }
  return int.parse(fraction.group(1)!) /
      (fraction.group(2) == null ? 1 : int.parse(fraction.group(2)!));
}

double _numericValue(String value) {
  final match = RegExp(r'^(-?\d+(?:\.\d+)?)(.*)$').firstMatch(value);
  if (match == null) {
    throw FormatException('Expected a numeric answer, got "$value".');
  }
  return double.parse(match.group(1)!);
}

void _expectUniqueFractionChoices(NpcQuestion question, double expected) {
  expect(question.choices, hasLength(3));
  expect(
    question.choices.map(_fractionValue).toSet(),
    hasLength(3),
  );
  expect(
    question.choices.where(
      (choice) => (_fractionValue(choice) - expected).abs() < 0.0000001,
    ),
    hasLength(1),
  );
  expect(
    _fractionValue(question.choices[question.correctAnswerIndex]),
    closeTo(expected, 0.0000001),
  );
}

void _expectUniqueNumericChoices(NpcQuestion question) {
  final answer = question.choices[question.correctAnswerIndex];
  final expected = _numericValue(answer);
  final values = question.choices.map(_numericValue).toSet();

  expect(question.choices, hasLength(3));
  expect(values, hasLength(3));
  expect(
    question.choices.where(
      (choice) => (_numericValue(choice) - expected).abs() < 0.0000001,
    ),
    hasLength(1),
  );
  for (final choice in question.choices) {
    expect((_numericValue(choice) - expected).abs(), lessThanOrEqualTo(1));
  }
}

void main() {
  test('fraction worksheet questions use unique nearby Game Mode choices', () {
    final lessons = worksheetLessons
        .where((lesson) => lesson.moduleId == 'fraction-add-subtract');
    var index = 0;
    for (final lesson in lessons) {
      final question = NpcQuestion.forLevel(
        1,
        1,
        questionSeed: index++,
      );
      expect(question.prompt, lesson.question);
      _expectUniqueFractionChoices(
        question,
        _fractionValue(lesson.correctAnswer),
      );
      for (final choice in question.choices) {
        expect(
          (_fractionValue(choice) - _fractionValue(lesson.correctAnswer)).abs(),
          lessThanOrEqualTo(1),
        );
      }
    }
  });

  test('mixed-number addition and subtraction answers are accurate', () {
    for (final (seed, expected) in [(2, 3.75), (3, 2.75)]) {
      final question = NpcQuestion.forLevel(
        1,
        1,
        questionSeed: seed,
      );
      final expression = RegExp(
        r'Calculate (\d+) (\d+)/(\d+) ([+−]) (\d+) (\d+)/(\d+)\.',
      ).firstMatch(question.prompt);
      expect(expression, isNotNull, reason: question.prompt);

      final first = int.parse(expression!.group(1)!) +
          int.parse(expression.group(2)!) / int.parse(expression.group(3)!);
      final second = int.parse(expression.group(5)!) +
          int.parse(expression.group(6)!) / int.parse(expression.group(7)!);
      final actual =
          expression.group(4) == '−' ? first - second : first + second;

      expect(actual, closeTo(expected, 0.0000001));
      _expectUniqueFractionChoices(question, expected);
    }
  });

  test('generated fraction addition and subtraction answers are accurate', () {
    for (final level in [2, 5, 7]) {
      for (var seed = 0; seed < 20; seed++) {
        final question = NpcQuestion.forLevel(
          1,
          level,
          questionSeed: seed,
        );
        final expression = RegExp(
          r'Calculate (\d+)/(\d+) ([+−]) (\d+)/(\d+)(?: \+ (\d+)/(\d+))?\.',
        ).firstMatch(question.prompt);
        expect(expression, isNotNull, reason: question.prompt);

        final firstNumerator = int.parse(expression!.group(1)!);
        final firstDenominator = int.parse(expression.group(2)!);
        final secondNumerator = int.parse(expression.group(4)!);
        final secondDenominator = int.parse(expression.group(5)!);
        final operation = expression.group(3);
        var expected = firstNumerator / firstDenominator +
            (operation == '+' ? 1 : -1) * secondNumerator / secondDenominator;
        if (expression.group(6) != null) {
          expected +=
              int.parse(expression.group(6)!) / int.parse(expression.group(7)!);
        }

        _expectUniqueFractionChoices(question, expected);
      }
    }
  });

  test('generated fraction multiplication and division answers are accurate',
      () {
    for (final level in [9, 12]) {
      for (var seed = 0; seed < 20; seed++) {
        final question = NpcQuestion.forLevel(
          1,
          level,
          questionSeed: seed,
        );
        final expression = RegExp(
          r'Calculate (\d+)/(\d+) ([×÷]) (\d+)/(\d+)(?: ([×÷]) (\d+)/(\d+))?\.',
        ).firstMatch(question.prompt);
        expect(expression, isNotNull, reason: question.prompt);

        var expected =
            int.parse(expression!.group(1)!) / int.parse(expression.group(2)!);
        for (var operandIndex = 0; operandIndex < 2; operandIndex++) {
          final operation = expression.group(3 + operandIndex * 3);
          if (operation == null) break;
          final numerator = int.parse(expression.group(4 + operandIndex * 3)!);
          final denominator =
              int.parse(expression.group(5 + operandIndex * 3)!);
          expected = operation == '×'
              ? expected * numerator / denominator
              : expected * denominator / numerator;
        }

        _expectUniqueFractionChoices(question, expected);
      }
    }
  });

  test('correct-answer position varies across fraction questions', () {
    final correctPositions = <int>{};
    for (var seed = 0; seed < 30; seed++) {
      final question = NpcQuestion.forLevel(
        1,
        2,
        questionSeed: seed,
      );
      correctPositions.add(question.correctAnswerIndex);
    }
    expect(correctPositions, hasLength(3));
  });

  test('generated numeric questions use unique nearby choices', () {
    for (final level in [15, 22, 27, 32, 37, 42]) {
      for (var seed = 0; seed < 20; seed++) {
        final question = NpcQuestion.forLevel(
          1,
          level,
          questionSeed: seed,
        );
        _expectUniqueNumericChoices(question);
      }
    }
  });
}
