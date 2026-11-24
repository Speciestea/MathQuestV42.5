import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> decodeAsset(String path) async {
  final asset = await rootBundle.load(path);
  final codec = await ui.instantiateImageCodec(
    asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

({int left, int top, int width, int height}) alphaBounds(
  ui.Image image,
  Uint8List pixels,
  int left,
  int top,
) {
  var minX = 128;
  var minY = 192;
  var maxX = -1;
  var maxY = -1;
  for (var y = top; y < top + 192; y++) {
    for (var x = left; x < left + 128; x++) {
      if (pixels[(y * image.width + x) * 4 + 3] == 0) continue;
      if (x - left < minX) minX = x - left;
      if (x - left > maxX) maxX = x - left;
      if (y - top < minY) minY = y - top;
      if (y - top > maxY) maxY = y - top;
    }
  }
  expect(maxX, greaterThanOrEqualTo(0));
  return (
    left: minX,
    top: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Characters 3, 4, and 5 use the reference 6-by-4 frame sheet size',
      () async {
    const spriteSheets = [
      'assets/images/player/character.png',
      'assets/images/player/character3.png',
      'assets/images/player/character4.png',
      'assets/images/player/character5.png',
    ];

    for (final spriteSheet in spriteSheets) {
      final image = await decodeAsset(spriteSheet);
      expect(image.width, 768, reason: spriteSheet);
      expect(image.height, 768, reason: spriteSheet);
      image.dispose();
    }
  });

  test('Characters 3, 4, and 5 have clean, consistently aligned frames',
      () async {
    final reference = await decodeAsset('assets/images/player/character.png');
    final referenceData = (await reference.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final referencePixels = referenceData.buffer.asUint8List(
      referenceData.offsetInBytes,
      referenceData.lengthInBytes,
    );
    final referenceRows = [5, 197, 384, 576];
    final referenceMeanHeights = List<double>.filled(4, 0);
    final referenceCenters = List<double>.filled(4, 0);
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 6; column++) {
        final bounds = alphaBounds(
          reference,
          referencePixels,
          column * 128,
          referenceRows[row],
        );
        referenceMeanHeights[row] += bounds.height / 6;
        referenceCenters[row] += bounds.top + bounds.height / 2;
      }
      referenceCenters[row] = referenceCenters[row] / 6 +
          (row < 2 ? referenceRows[row] - row * 192 : 0);
    }

    try {
      for (final character in ['character3', 'character4', 'character5']) {
        final image = await decodeAsset(
          'assets/images/player/$character.png',
        );
        try {
          final imageData = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final pixels = imageData.buffer.asUint8List(
            imageData.offsetInBytes,
            imageData.lengthInBytes,
          );
          for (var row = 0; row < 4; row++) {
            final centersX = <double>[];
            final centersY = <double>[];
            var meanHeight = 0.0;
            for (var column = 0; column < 6; column++) {
              final bounds = alphaBounds(
                image,
                pixels,
                column * 128,
                row * 192,
              );
              meanHeight += bounds.height / 6;
              centersX.add(bounds.left + bounds.width / 2);
              centersY.add(bounds.top + bounds.height / 2);
            }
            expect(
              centersX.reduce((a, b) => a > b ? a : b) -
                  centersX.reduce((a, b) => a < b ? a : b),
              lessThanOrEqualTo(2),
              reason: '$character row $row horizontal alignment',
            );
            expect(
              centersY.reduce((a, b) => a > b ? a : b) -
                  centersY.reduce((a, b) => a < b ? a : b),
              lessThanOrEqualTo(2),
              reason: '$character row $row vertical alignment',
            );
            expect(
              centersY.reduce((a, b) => a + b) / 6,
              closeTo(referenceCenters[row], 12),
              reason: '$character row $row reference alignment',
            );
            expect(
              meanHeight,
              closeTo(referenceMeanHeights[row], 4),
              reason: '$character row $row visible height',
            );
          }
        } finally {
          image.dispose();
        }
      }
    } finally {
      reference.dispose();
    }
  });
}
