import 'package:sembast/sembast.dart';
import 'package:sembast_web/sembast_web.dart';

Future<Database> openOfflineProgressDatabase(String databaseName) =>
    databaseFactoryWeb.openDatabase(databaseName);
