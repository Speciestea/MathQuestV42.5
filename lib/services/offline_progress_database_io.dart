import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

Future<Database> openOfflineProgressDatabase(String databaseName) async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final databasePath =
      '${directory.path}${Platform.pathSeparator}$databaseName.db';
  return databaseFactoryIo.openDatabase(databasePath);
}
