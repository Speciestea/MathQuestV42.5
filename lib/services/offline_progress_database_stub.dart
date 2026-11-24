import 'package:sembast/sembast.dart';

Future<Database> openOfflineProgressDatabase(String databaseName) {
  throw UnsupportedError(
    'Durable offline progress storage is not supported on this platform.',
  );
}
