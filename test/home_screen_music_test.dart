import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/screens/home_screen.dart';
import 'package:flutter_mathquest/services/background_music_service.dart';

void main() {
  testWidgets('Home music toggle is above Home and switches music state',
      (tester) async {
    final music = BackgroundMusicService.instance;
    await music.setMusicEnabled(true);
    addTearDown(() => music.setMusicEnabled(true));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('home-music-toggle'));
    final home = find.byKey(const ValueKey('home-navigation'));
    expect(toggle, findsOneWidget);
    expect(tester.getRect(toggle).bottom, lessThan(tester.getRect(home).top));
    expect(tester.getSize(toggle), const Size(44, 44));
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(music.musicEnabled.value, isFalse);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(music.musicEnabled.value, isTrue);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
