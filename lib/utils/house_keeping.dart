import 'dart:io';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '/models/media_Item_builder.dart';
import '/ui/screens/Library/library_controller.dart';
import '../services/utils.dart';
import 'helper.dart';

void startHouseKeeping() {
  removeExpiredSongsUrlFromDb();
}

Future<void> removeExpiredSongsUrlFromDb() async {
  try {
    final songsUrlCacheBox = Hive.box("SongsUrlCache");
    final songsUrlCacheKeysList =
        songsUrlCacheBox.keys.whereType<String>().toList();

    for (var i = 0; i < songsUrlCacheKeysList.length; i++) {
      final songUrlKey = songsUrlCacheKeysList[i];
      final cacheValue = songsUrlCacheBox.get(songUrlKey);

      if (cacheValue is! List || cacheValue.length < 2) {
        await songsUrlCacheBox.delete(songUrlKey);
        continue;
      }

      final streamData = cacheValue[1];

      if (streamData == null || streamData is String) {
        await songsUrlCacheBox.delete(songUrlKey);
        continue;
      }

      if (streamData is Map) {
        final url = streamData['url']?.toString() ?? '';
        if (url.isEmpty || isExpired(url: url)) {
          await songsUrlCacheBox.delete(songUrlKey);
        }
      } else {
        await songsUrlCacheBox.delete(songUrlKey);
      }
    }
  } catch (e) {
    printERROR("Error in removeExpiredSongsUrlFromDb: $e");
  } finally {
    await removeDeletedOfflineSongsFromDb();
  }
}

Future<void> removeDeletedOfflineSongsFromDb() async {
  final supportDir = (await getApplicationSupportDirectory()).path;

  try {
    final songDownloadsBox = Hive.box("SongDownloads");
    final downloadedSongs = songDownloadsBox.values.toList();

    final LibrarySongsController librarySongsController =
        Get.find<LibrarySongsController>();

    for (var i = 0; i < downloadedSongs.length; i++) {
      final rawItem = downloadedSongs[i];

      if (rawItem is! Map) {
        continue;
      }

      final songMap = Map<String, dynamic>.from(rawItem);

      final songKey =
          songMap['id']?.toString() ?? songMap['videoId']?.toString() ?? '';

      final rootUrl = songMap['url']?.toString();
      final extras = songMap['extras'] is Map
          ? Map<String, dynamic>.from(songMap['extras'])
          : <String, dynamic>{};
      final extrasUrl = extras['url']?.toString();

      final songUrl = (rootUrl != null && rootUrl.isNotEmpty)
          ? rootUrl
          : (extrasUrl != null && extrasUrl.isNotEmpty ? extrasUrl : '');

      if (songKey.isEmpty) {
        printERROR("removeDeletedOfflineSongsFromDb: missing song id");
        continue;
      }

      if (songUrl.isEmpty) {
        printERROR(
            "removeDeletedOfflineSongsFromDb: missing song url for $songKey");
        continue;
      }

      final songFile = File(songUrl);

      if (!await songFile.exists()) {
        await songDownloadsBox.delete(songKey);

        try {
          await librarySongsController.removeSong(
            MediaItemBuilder.fromJson(songMap),
            true,
          );
        } catch (e) {
          printERROR(
              "removeDeletedOfflineSongsFromDb removeSong error ($songKey): $e");
        }

        final thumbNailPath = "$supportDir/thumbnails/$songKey.png";
        final thumbFile = File(thumbNailPath);

        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }
    }
  } catch (e) {
    printERROR("Error in removeDeletedOfflineSongsFromDb: $e");
  }
}