import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/game/player.dart';
import 'package:flutter_mathquest/screens/register_screen.dart';

Finder selectedCharacter(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == label &&
          widget.properties.selected == true,
    );

void main() {
  testWidgets('selects and registers T-Rex from Others', (tester) async {
    String? registeredCharacter;
    await tester.pumpWidget(
      MaterialApp(
        home: RegisterScreen(
          onRegister: ({
            required email,
            required password,
            required name,
            required address,
            required character,
          }) async {
            registeredCharacter = character;
            return '44';
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    expect(selectedCharacter('Boy character, selected'), findsOneWidget);
    await tester.tap(find.text('Girl'));
    await tester.pumpAndSettle();
    expect(selectedCharacter('Girl character, selected'), findsOneWidget);

    await tester.tap(find.text('Others'));
    await tester.pumpAndSettle();
    expect(find.text('T-Rex'), findsOneWidget);
    expect(
      find.image(AssetImage(Player.trexSpriteAssetPath)),
      findsOneWidget,
    );
    await tester.tap(find.text('T-Rex'));
    await tester.pumpAndSettle();
    expect(
      selectedCharacter('T-Rex character, selected'),
      findsOneWidget,
    );

    await tester.tap(find.text('Boy'));
    await tester.pumpAndSettle();
    expect(selectedCharacter('Boy character, selected'), findsOneWidget);
    expect(find.text('T-Rex'), findsNothing);

    await tester.tap(find.text('Others'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('T-Rex'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'Test Student');
    await tester.enterText(fields.at(2), 'Test Address');
    await tester.enterText(fields.at(3), 'student@example.com');
    await tester.enterText(fields.at(4), 'password123');
    await tester.enterText(fields.at(5), 'password123');

    final registerButton =
        find.widgetWithText(ElevatedButton, 'Create Account');
    await tester.ensureVisible(registerButton);
    await tester.tap(registerButton);
    await tester.pumpAndSettle();

    expect(registeredCharacter, 'character3');
    semantics.dispose();
  });

  testWidgets('selects and registers both Pride characters from Others',
      (tester) async {
    final semantics = tester.ensureSemantics();
    for (final (id, label, asset) in [
      (
        'character4',
        'Pride Femme',
        Player.prideFemmeSpriteAssetPath,
      ),
      (
        'character5',
        'Pride Masc',
        Player.prideMascSpriteAssetPath,
      ),
    ]) {
      String? registeredCharacter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RegisterScreen(
                        onRegister: ({
                          required email,
                          required password,
                          required name,
                          required address,
                          required character,
                        }) async {
                          registeredCharacter = character;
                          return '45';
                        },
                      ),
                    ),
                  ),
                  child: const Text('Open Registration'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Registration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Others'));
      await tester.pumpAndSettle();

      expect(find.text('Pride Femme'), findsOneWidget);
      expect(find.text('Pride Masc'), findsOneWidget);
      expect(find.image(AssetImage(asset)), findsOneWidget);
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        selectedCharacter('$label character, selected'),
        findsOneWidget,
      );

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(1), 'Test Student');
      await tester.enterText(fields.at(2), 'Test Address');
      await tester.enterText(fields.at(3), 'student@example.com');
      await tester.enterText(fields.at(4), 'password123');
      await tester.enterText(fields.at(5), 'password123');

      final registerButton =
          find.widgetWithText(ElevatedButton, 'Create Account');
      await tester.ensureVisible(registerButton);
      await tester.tap(registerButton);
      await tester.pumpAndSettle();
      expect(registeredCharacter, id);

      final player = Player(characterId: registeredCharacter!);
      expect(player.characterId, id);
      expect(player.spriteAssetPath, asset);
      await tester.tap(find.text('Continue to Login'));
      await tester.pumpAndSettle();
    }
    semantics.dispose();
  });

  test('uses the Trex sprite for character3 in the game', () {
    final player = Player(characterId: 'character3');

    expect(player.characterId, 'character3');
    expect(player.spriteAssetPath, Player.trexSpriteAssetPath);
  });

  test('loads the matching Pride sprite for each new game character', () {
    expect(
      Player(characterId: 'character4').spriteAssetPath,
      Player.prideFemmeSpriteAssetPath,
    );
    expect(
      Player(characterId: 'character5').spriteAssetPath,
      Player.prideMascSpriteAssetPath,
    );
  });
}
