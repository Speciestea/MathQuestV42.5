import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/services/background_music_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers the existing BG_music asset', () async {
    final music = await rootBundle.load('assets/music/BG_music.mp3');

    expect(music.lengthInBytes, greaterThan(0));
  });

  test('allows music only for approved student profiles', () {
    expect(
      BackgroundMusicService.isMusicEligibleForProfile(
        role: 'student',
        status: 'approved',
      ),
      isTrue,
    );
    for (final role in ['admin', 'teacher', 'super admin', 'super_admin']) {
      expect(
        BackgroundMusicService.isMusicEligibleForProfile(
          role: role,
          status: 'approved',
        ),
        isFalse,
        reason: '$role accounts must never play background music.',
      );
    }
    expect(
      BackgroundMusicService.isMusicEligibleForProfile(
        role: 'student',
        status: 'pending',
      ),
      isFalse,
    );
    expect(
      BackgroundMusicService.isMusicEligibleForProfile(
        role: null,
        status: 'approved',
      ),
      isFalse,
    );
  });
}
