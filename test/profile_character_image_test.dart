import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_mathquest/models/user_account.dart';
import 'package:flutter_mathquest/services/profile_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads each selected profile character from its bundled image asset',
      () async {
    const characters = {
      'character3': 'assets/images/player/T-rex.png',
      'character4': 'assets/images/player/Pride Femme.png',
      'character5': 'assets/images/player/Pride Masc.png',
    };

    for (final entry in characters.entries) {
      final photo = await ProfileService().getProfilePhoto(
        profilePhotoUrl: entry.value,
        character: entry.key,
      );
      final asset = await rootBundle.load(entry.value);

      expect(photo, isNotNull);
      expect(photo!.isNotEmpty, isTrue);
      expect(
        photo,
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      expect(
        UserAccount.isCharacterProfileImageAsset(entry.value),
        isTrue,
      );
      final codec = await ui.instantiateImageCodec(photo);
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0));
        expect(frame.image.height, greaterThan(0));
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    }
  });

  test('uses the saved character image when an older profile has no photo URL',
      () async {
    const character = 'character4';
    const imagePath = 'assets/images/player/Pride Femme.png';

    final photo = await ProfileService().getProfilePhoto(
      profilePhotoUrl: '',
      character: character,
    );
    final asset = await rootBundle.load(imagePath);

    expect(
      photo,
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
    );
  });
}
