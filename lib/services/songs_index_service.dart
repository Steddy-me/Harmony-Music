import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/song_index_entry.dart';

class SongsIndexService {
  const SongsIndexService();

  Future<List<SongIndexEntry>> loadIndex(File indexFile) async {
    if (!await indexFile.exists()) {
      debugPrint('SONGS INDEX LOAD MISS => ${indexFile.path}');
      return [];
    }

    try {
      final raw = await indexFile.readAsString();
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        debugPrint('SONGS INDEX LOAD INVALID ROOT => ${indexFile.path}');
        return [];
      }

      final list = decoded
          .whereType<Map>()
          .map((e) => SongIndexEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      debugPrint('SONGS INDEX LOAD OK => ${list.length}');
      return list;
    } catch (e, st) {
      debugPrint('SONGS INDEX LOAD ERROR => $e');
      debugPrint('$st');
      return [];
    }
  }

  Future<void> saveIndex(File indexFile, List<SongIndexEntry> entries) async {
    try {
      if (!await indexFile.parent.exists()) {
        await indexFile.parent.create(recursive: true);
      }

      const encoder = JsonEncoder.withIndent('  ');
      final jsonText =
          encoder.convert(entries.map((e) => e.toJson()).toList());

      await indexFile.writeAsString(jsonText);
      debugPrint('SONGS INDEX SAVE OK => ${indexFile.path}');
    } catch (e, st) {
      debugPrint('SONGS INDEX SAVE ERROR => $e');
      debugPrint('$st');
    }
  }

  Future<void> upsertEntry(
    File indexFile,
    SongIndexEntry newEntry,
  ) async {
    final entries = await loadIndex(indexFile);

    final index = entries.indexWhere((e) {
      if (e.id.isNotEmpty && e.id == newEntry.id) return true;

      final sameSource = (e.sourceUrl ?? '').trim().isNotEmpty &&
          (e.sourceUrl ?? '').trim() == (newEntry.sourceUrl ?? '').trim();

      if (sameSource) return true;

      final sameHash = (e.localHash ?? '').trim().isNotEmpty &&
          (e.localHash ?? '').trim() == (newEntry.localHash ?? '').trim();

      if (sameHash) return true;

      return false;
    });

    if (index >= 0) {
      entries[index] = newEntry;
      debugPrint('SONGS INDEX UPSERT UPDATE => ${newEntry.title}');
    } else {
      entries.add(newEntry);
      debugPrint('SONGS INDEX UPSERT ADD => ${newEntry.title}');
    }

    await saveIndex(indexFile, entries);
  }

  Future<int> pruneBrokenEntries({
    required File indexFile,
    required String sharedRootPath,
  }) async {
    final entries = await loadIndex(indexFile);
    final kept = <SongIndexEntry>[];
    int removed = 0;

    for (final entry in entries) {
      final filePath = resolveSharedSongPath(
        sharedRootPath: sharedRootPath,
        entry: entry,
      );

      if (await File(filePath).exists()) {
        kept.add(entry);
      } else {
        removed++;
        debugPrint('SONGS INDEX PRUNE REMOVE => $filePath');
      }
    }

    await saveIndex(indexFile, kept);
    return removed;
  }

  String resolveSharedSongPath({
    required String sharedRootPath,
    required SongIndexEntry entry,
  }) {
    final sep = Platform.pathSeparator;

    if (entry.relativePath != null && entry.relativePath!.trim().isNotEmpty) {
      final normalizedRelative = entry.relativePath!
          .replaceAll('\\', sep)
          .replaceAll('/', sep);
      return '$sharedRootPath$sep$normalizedRelative';
    }

    final fileName = entry.fileName?.trim() ?? '';
    return '$sharedRootPath${sep}songs$sep$fileName';
  }

  String buildRelativeSongsPath(String fileName) {
    final normalized = fileName.replaceAll('\\', '/');
    return 'songs/$normalized';
  }
}