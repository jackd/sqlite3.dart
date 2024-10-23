import 'dart:convert';
import 'dart:html';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sqlite3_web/sqlite3_web.dart';

final sqlite3WasmUri = Uri.parse('sqlite3.wasm');
final workerUri = Uri.parse('worker.dart.js');
const databaseName = 'database';

WebSqlite? webSqlite;

Database? database;
int updates = 0;
bool listeningForUpdates = false;

void main() {
  _addCallbackForWebDriver('detectImplementations', _detectImplementations);
  _addCallbackForWebDriver('close', (arg) async {
    await database?.dispose();
    return null;
  });
  _addCallbackForWebDriver('get_updates', (arg) async {
    listenForUpdates();
    return updates.toJS;
  });
  _addCallbackForWebDriver('open', (arg) => _open(arg, false));
  _addCallbackForWebDriver('open_only_vfs', (arg) => _open(arg, true));
  _addCallbackForWebDriver('exec', _exec);
  _addCallbackForWebDriver('test_second', (arg) async {
    final endpoint = await database!.additionalConnection();
    final second = await WebSqlite.connectToPort(endpoint);

    await second.execute('SELECT 1');
    await second.dispose();
    return true.toJS;
  });
  _addCallbackForWebDriver('assert_file', (arg) async {
    final vfs = database!.fileSystem;

    final exists = await vfs.exists(FileType.database);
    print('exists: $exists');
    if (exists != bool.parse(arg!)) {
      return false.toJS;
    }

    if (exists) {
      // Try reading file contents
      final buffer = await vfs.readFile(FileType.database);
      return buffer.length.toJS;
    }

    return true.toJS;
  });
  _addCallbackForWebDriver('flush', (arg) async {
    final vfs = database!.fileSystem;
    await vfs.flush();
    return true.toJS;
  });

  document.getElementById('selfcheck')?.onClick.listen((event) async {
    print('starting');
    final sqlite = initializeSqlite();
    final database = await sqlite.connectToRecommended(databaseName);

    print('selected storage: ${database.storage} through ${database.access}');
    print('missing features: ${database.features.missingFeatures}');
  });

  document.body!.children.add(DivElement()..id = 'ready');
}

void _addCallbackForWebDriver(
    String name, Future<JSAny?> Function(String?) impl) {
  globalContext.setProperty(
    name.toJS,
    (JSString? arg, JSFunction callback) {
      Future(() async {
        JSAny? result;

        try {
          result = await impl(arg?.toDart);
        } catch (e, s) {
          final console = globalContext['console']! as JSObject;
          console.callMethod(
              'error'.toJS, e.toString().toJS, s.toString().toJS);
        }

        callback.callAsFunction(null, result);
      });
    }.toJS,
  );
}

WebSqlite initializeSqlite() {
  return webSqlite ??= WebSqlite.open(
    worker: workerUri,
    wasmModule: sqlite3WasmUri,
  );
}

Future<JSString> _detectImplementations(String? _) async {
  final instance = initializeSqlite();
  final result = await instance.runFeatureDetection(databaseName: 'database');

  return json.encode({
    'impls': result.availableImplementations
        .map((r) => [r.$1.name, r.$2.name])
        .toList(),
    'missing': result.missingFeatures.map((r) => r.name).toList(),
    'existing': result.existingDatabases.map((r) => [r.$1.name, r.$2]).toList(),
  }).toJS;
}

Future<JSAny?> _open(String? implementationName, bool onlyOpenVfs) async {
  final sqlite = initializeSqlite();
  Database db;
  var returnValue = implementationName;

  if (implementationName != null) {
    final split = implementationName.split(':');

    db = await sqlite.connect(databaseName, StorageMode.values.byName(split[0]),
        AccessMode.values.byName(split[1]),
        onlyOpenVfs: onlyOpenVfs);
  } else {
    final result = await sqlite.connectToRecommended(databaseName,
        onlyOpenVfs: onlyOpenVfs);
    db = result.database;
    returnValue = '${result.storage.name}:${result.access.name}';
  }

  database = db;

  // Make sure it works!
  if (!onlyOpenVfs) {
    await db.select('SELECT database_host()');
    listenForUpdates();
  }

  return returnValue?.toJS;
}

void listenForUpdates() {
  if (!listeningForUpdates) {
    listeningForUpdates = true;
    database!.updates.listen((_) => updates++);
  }
}

Future<JSAny?> _exec(String? sql) async {
  await database!.execute(sql!);
  return null;
}