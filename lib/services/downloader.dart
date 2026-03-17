import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:audiotags/audiotags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/playlist.dart';
import '../ui/screens/Album/album_screen_controller.dart';
import '../ui/screens/Playlist/playlist_screen_controller.dart';
import '../ui/screens/Settings/settings_screen_controller.dart';
import '../ui/screens/Library/library_controller.dart';
import '../ui/widgets/snackbar.dart';
import '/models/media_Item_builder.dart';
import '/services/permission_service.dart';
import '/services/stream_service.dart';
import '/utils/helper.dart';
import 'music_service.dart';
import 'shared_library_service.dart';

class Downloader extends GetxService {
  final _dio = Dio();
  MediaItem? currentSong;
  RxMap<String, List<MediaItem>> playlistQueue =
      <String, List<MediaItem>>{}.obs;
  final currentPlaylistId = "".obs;
  final songDownloadingProgress = 0.obs;
  final playlistDownloadingProgress = 0.obs;
  final isJobRunning = false.obs;

  RxList<MediaItem> songQueue = <MediaItem>[].obs;

  Future<bool> checkPermissionNDir() async {
    final settingsScreenController = Get.find<SettingsScreenController>();

    if (!settingsScreenController.isCurrentPathsupportDownDir &&
        !await PermissionService.getExtStoragePermission()) {
      return false;
    }

    final dirPath =
        Get.find<SettingsScreenController>().downloadLocationPath.string;
    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return true;
  }

  Future<void> downloadPlaylist(
      String playlistId, List<MediaItem> songList) async {
    if (!(await checkPermissionNDir())) return;

    if (playlistQueue.containsKey(playlistId)) {
      songQueue.removeWhere((element) => songList.contains(element));
      playlistQueue.remove(playlistId);
      return;
    }

    playlistQueue[playlistId] = songList;
    songQueue.addAll(songList);

    if (isJobRunning.isFalse) {
      await triggerDownloadingJob();
    }
  }

  Future<void> download(MediaItem? song, {List<MediaItem>? songList}) async {
    if (!(await checkPermissionNDir())) return;
    if (songList != null) {
      songQueue.addAll(songList);
    } else {
      songQueue.add(song!);
    }
    if (isJobRunning.isFalse) {
      await triggerDownloadingJob();
    }
  }

  Future<void> triggerDownloadingJob() async {
    if (playlistQueue.isNotEmpty) {
      isJobRunning.value = true;
      for (String playlistId in playlistQueue.keys.toList()) {
        if (playlistQueue.containsKey(playlistId)) {
          currentPlaylistId.value = playlistId;
          await downloadSongList((playlistQueue[playlistId]!).toList(),
              isPlaylist: true);
          if (Get.isRegistered<PlaylistScreenController>(
                  tag: Key(playlistId).hashCode.toString()) &&
              playlistQueue.containsKey(playlistId)) {
            Get.find<PlaylistScreenController>(
                    tag: Key(playlistId).hashCode.toString())
                .isDownloaded
                .value = true;
          } else if (Get.isRegistered<AlbumScreenController>(
                  tag: Key(playlistId).hashCode.toString()) &&
              playlistQueue.containsKey(playlistId)) {
            Get.find<AlbumScreenController>(
                    tag: Key(playlistId).hashCode.toString())
                .isDownloaded
                .value = true;
          }
          playlistQueue.remove(playlistId);
        }
        currentPlaylistId.value = "";
        playlistDownloadingProgress.value = 0;
      }
    } else {
      isJobRunning.value = true;
      await downloadSongList(songQueue.toList());
    }

    if (songQueue.isNotEmpty) {
      triggerDownloadingJob();
    } else {
      isJobRunning.value = false;
      currentSong = null;
    }
  }

  Future<void> downloadSongList(List<MediaItem> jobSongList,
      {bool isPlaylist = false}) async {
    for (MediaItem song in jobSongList) {
      if (isPlaylist && !playlistQueue.containsKey(currentPlaylistId.value)) {
        currentPlaylistId.value = "";
        playlistDownloadingProgress.value = 0;
        return;
      }

      if (!Hive.box("SongDownloads").containsKey(song.id)) {
        currentSong = song;
        songDownloadingProgress.value = 0;
        await writeFileStream(song);
      }
      songQueue.remove(song);
      if (isPlaylist) {
        playlistDownloadingProgress.value = jobSongList.indexOf(song) + 1;
      }
    }
  }

  Future<void> _updateDownloadedSongInLocalPlaylists({
    required MediaItem song,
    required String relativePath,
    required String sharedSongId,
    required String? streamUrl,
  }) async {
    try {
      final playlistsBox = await Hive.openBox("LibraryPlaylists");
      final playlistEntries = playlistsBox.values.toList();

      for (final rawPlaylist in playlistEntries) {
        try {
          if (rawPlaylist is! Map) continue;

          final playlist =
              Playlist.fromJson(Map<String, dynamic>.from(rawPlaylist));

          if (playlist.deleted ||
              playlist.isCloudPlaylist ||
              playlist.isPipedPlaylist ||
              !playlist.playlistId.startsWith('LIB')) {
            continue;
          }

          final alreadyOpen = Hive.isBoxOpen(playlist.playlistId);
          final songsBox = alreadyOpen
              ? Hive.box(playlist.playlistId)
              : await Hive.openBox(playlist.playlistId);

          bool updated = false;

          for (final key in songsBox.keys.toList()) {
            final rawSong = songsBox.get(key);

            if (rawSong is! Map) continue;

            final itemJson = Map<String, dynamic>.from(rawSong);
            final rawExtras = itemJson['extras'];
            final extras = rawExtras is Map
                ? Map<String, dynamic>.from(rawExtras)
                : <String, dynamic>{};

            final itemId =
                itemJson['videoId']?.toString() ?? itemJson['id']?.toString();

            if (itemId != song.id) continue;

            extras['relativePath'] = relativePath;
            extras['sharedSongId'] = sharedSongId;
            extras['isSharedSong'] = true;

            if (streamUrl != null && streamUrl.isNotEmpty) {
              extras['streamUrl'] = streamUrl;
            }

            itemJson['relativePath'] = relativePath;
            itemJson['sharedSongId'] = sharedSongId;
            itemJson['isSharedSong'] = true;

            if (streamUrl != null && streamUrl.isNotEmpty) {
              itemJson['streamUrl'] = streamUrl;
            }

            itemJson['extras'] = extras;

            await songsBox.put(key, itemJson);
            updated = true;

            printINFO(
              "PLAYLIST SONG UPDATED => ${playlist.playlistId} | ${song.id} | $relativePath",
            );
          }

          if (updated) {
            playlist.touch();
            await playlistsBox.put(playlist.playlistId, playlist.toJson());
          }

          if (!alreadyOpen) {
            await songsBox.close();
          }
        } catch (e) {
          printERROR("Playlist update error => $e");
        }
      }

      await playlistsBox.close();

      try {
        await Get.find<SharedLibraryService>().exportPlaylists();
      } catch (e) {
        printERROR("Playlist export after download update error => $e");
      }
    } catch (e) {
      printERROR("Update downloaded song in playlists error => $e");
    }
  }

  Future<void> writeFileStream(MediaItem song) async {
    Completer<void> complete = Completer();

    final settingsScreenController = Get.find<SettingsScreenController>();
    final downloadingFormat = settingsScreenController.downloadingFormat.string;

    final playerResponse = await StreamProvider.fetch(song.id);

    if (!playerResponse.playable) {
      ScaffoldMessenger.of(Get.context!).showSnackBar(snackbar(
          Get.context!,
          playerResponse.statusMSG == "networkError"
              ? playerResponse.statusMSG.tr
              : playerResponse.statusMSG,
          size: SanckBarSize.BIG,
          duration: const Duration(seconds: 2),
          top: !GetPlatform.isDesktop));
      printINFO("Requested song is not downloadable. You may try again");
      complete.complete();
      return complete.future;
    }

    Audio requiredAudioStream = downloadingFormat == "opus"
        ? playerResponse.highestBitrateOpusAudio!
        : playerResponse.highestBitrateMp4aAudio!;

    final dirPath = settingsScreenController.downloadLocationPath.string;
    final actualDownformat =
        requiredAudioStream.audioCodec.name.contains("mp") ? "m4a" : "opus";
    final RegExp invalidChar =
        RegExp(r'Container.|\/|\\|\"|\<|\>|\*|\?|\:|\!|\[|\]|\¡|\||\%');
    final songTitle = "${song.title.trim()} (${song.artist?.trim()})"
        .replaceAll(invalidChar, "");
    String filePath = "$dirPath/$songTitle.$actualDownformat";
    printINFO("Downloading filePath: $filePath");
    final totalBytes = requiredAudioStream.size;

    _dio.download(
      requiredAudioStream.url,
      filePath,
      options: Options(headers: {"Range": 'bytes=0-$totalBytes'}),
      onReceiveProgress: (count, total) {
        if (total <= 0) return;
        songDownloadingProgress.value = ((count / total) * 100).toInt();
      },
    ).then(
      (value) async {
        printINFO(value.data);

        String? year;
        try {
          if (song.extras?['year'] != null) {
            year = song.extras?['year'];
          } else {
            if (song.album != null) {
              final musicServ = Get.find<MusicServices>();
              year = await musicServ.getSongYear(song.id);
            }
          }
        } catch (_) {}

        try {
          final thumbnailPath =
              "${settingsScreenController.supportDirPath}/thumbnails/${song.id}.png";
          await _dio.downloadUri(song.artUri!, thumbnailPath);
        } catch (e) {}

        final songJson = Map<String, dynamic>.from(
          MediaItemBuilder.toJson(song),
        );

        final extras = songJson['extras'] is Map
            ? Map<String, dynamic>.from(songJson['extras'])
            : <String, dynamic>{};

        extras['streamUrl'] = requiredAudioStream.url;
        songJson['streamUrl'] = requiredAudioStream.url;

        extras['url'] = filePath;
        songJson['url'] = filePath;

        try {
          final sharedLibrary = Get.find<SharedLibraryService>();
          final sourceFile = File(filePath);

          if (await sourceFile.exists()) {
            final sharedSong =
                await sharedLibrary.sharedSongsService.importSong(sourceFile);

            final relativePath = "songs/${sharedSong.filename}";

            extras['sharedSongId'] = sharedSong.id;
            extras['relativePath'] = relativePath;
            extras['isSharedSong'] = true;

            songJson['sharedSongId'] = sharedSong.id;
            songJson['relativePath'] = relativePath;
            songJson['isSharedSong'] = true;

            printINFO("SHARED SONG IMPORTED => $relativePath");

            await _updateDownloadedSongInLocalPlaylists(
              song: song,
              relativePath: relativePath,
              sharedSongId: sharedSong.id,
              streamUrl: requiredAudioStream.url,
            );
          }
        } catch (e) {
          printERROR("Shared import error => $e");
        }

        songJson['extras'] = extras;

        final streamInfoJson = requiredAudioStream.toJson();
        streamInfoJson['url'] = filePath;
        songJson["streamInfo"] = [true, streamInfoJson];

        await Hive.box("SongDownloads").put(song.id, songJson);

        final downloadedItem = MediaItemBuilder.fromJson(songJson);
        Get.find<LibrarySongsController>().librarySongsList.add(downloadedItem);

        printINFO("Downloaded successfully");

        final trackDetails = (song.extras?['trackDetails'])?.split("/");
        final int? trackNumber = int.tryParse(trackDetails?[0] ?? "");
        final int? totalTracks = int.tryParse(trackDetails?[1] ?? "");

        try {
          final imageUrl = song.artUri!.toString();
          Tag tag = Tag(
            title: song.title,
            trackArtist: song.artist,
            album: song.album,
            year: int.tryParse(year ?? ""),
            trackNumber: trackNumber,
            trackTotal: totalTracks,
            albumArtist: song.artist,
            genre: song.genre,
            pictures: [
              Picture(
                bytes: (await NetworkAssetBundle(Uri.parse(imageUrl))
                        .load(imageUrl))
                    .buffer
                    .asUint8List(),
                mimeType: MimeType.png,
                pictureType: PictureType.coverFront,
              )
            ],
          );

          await AudioTags.write(filePath, tag);
        } catch (e) {
          printERROR("$e");
        }

        complete.complete();
      },
    ).onError(
      (error, stackTrace) {
        ScaffoldMessenger.of(Get.context!).showSnackBar(snackbar(
            Get.context!, "downloadError3".tr,
            size: SanckBarSize.BIG,
            duration: const Duration(seconds: 2),
            top: !GetPlatform.isDesktop));
        printINFO(
            "Downloading failed due to network/stream error! Please try again");
        complete.complete();
      },
    );

    return complete.future;
  }
}