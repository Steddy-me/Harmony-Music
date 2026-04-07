import 'dart:io';
import 'package:path/path.dart' as p;

import 'shared_storage_provider.dart';

class FileStorageProvider extends SharedStorageProvider {
  final Directory baseDir;

  FileStorageProvider(this.baseDir);

  File _file(String name) => File(p.join(baseDir.path, name));

  @override
  Future<String?> readFile(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;

    final content = await file.readAsString();
    if (content.trim().isEmpty) return null;

    return content;
  }

  @override
  Future<void> writeFile(String name, String content) async {
    final file = _file(name);
    final tempFile = File('${file.path}.tmp');

    await tempFile.writeAsString(content);

    if (await file.exists()) {
      await file.delete();
    }

    await tempFile.rename(file.path);
  }

  @override
  Future<bool> exists(String name) async {
    return _file(name).exists();
  }

  @override
  Future<DateTime?> lastModified(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;
    return file.lastModified();
  }
}