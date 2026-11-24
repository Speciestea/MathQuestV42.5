import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/game/hud.dart';

void main() {
  testWidgets('Game HUD displays NPC progress below the help icon',
      (tester) async {
    Widget buildHud(int completed) => MaterialApp(
          home: Scaffold(
            body: GameHUD(
              score: 0,
              health: 3,
              onMusicPressed: () {},
              onMenuPressed: () {},
              onHelpPressed: () {},
              npcProgressCount: completed,
              npcProgressTotal: 6,
            ),
          ),
        );

    await tester.pumpWidget(buildHud(0));
    expect(find.text('0/6'), findsOneWidget);
    expect(tester.getRect(find.text('0/6')).top,
        greaterThan(tester.getRect(find.byType(Image)).bottom));

    await tester.pumpWidget(buildHud(3));
    expect(find.text('3/6'), findsOneWidget);
  });
}
