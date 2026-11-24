import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mathquest/widgets/student_profile_picture.dart';

void main() {
  testWidgets('uses the saved character picture before the fallback',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StudentProfilePicture(
          uid: 'student-a',
          profilePhotoUrl: 'assets/images/player/Pride Femme.png',
          character: 'boy',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      image.image,
      isA<AssetImage>().having(
        (asset) => asset.assetName,
        'assetName',
        'assets/images/player/Pride Femme.png',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the selected character as the default picture',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StudentProfilePicture(
          uid: 'student-b',
          profilePhotoUrl: '',
          character: 'character3',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      image.image,
      isA<AssetImage>().having(
        (asset) => asset.assetName,
        'assetName',
        'assets/images/player/T-rex.png',
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
