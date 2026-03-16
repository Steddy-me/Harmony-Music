import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/models/thumbnail.dart';
import 'package:harmonymusic/services/permission_service.dart';
import 'package:harmonymusic/ui/screens/Settings/settings_screen_controller.dart';
import 'package:harmonymusic/ui/widgets/snackbar.dart';
import 'package:harmonymusic/utils/helper.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

import '../../../base_class/playlist_album_screen_con_base.dart';
import '../../../mixins/additional_opeartion_mixin.dart';
import '../../../models/album.dart' show Album;
import '../../../models/media_Item_builder.dart';
import '../../../models/playlist.dart';
import '../../../services/music_service.dart';
import '../../../services/piped_service.dart';
import '../../../services/shared_library_service.dart';
import '../Home/home_screen_controller.dart';
import '../Library/library_controller.dart';

class PlaylistScreenController extends PlaylistAlbumScreenControllerBase
    with AdditionalOpeartionMixin, GetSingleTickerProviderStateMixin {
  final MusicServices _musicServices = Get.find<MusicServices>();

  final playlist = Playlist(
    title: "",
    playlistId: "",
    thumbnailUrl: Playlist.thumbPlaceholderUrl,
  ).obs;

  final isDefaultPlaylist = false.obs;

  final isExporting = false.obs;
  final exportProgress = 0.0.obs;

  String generatedYtmPlaylistUrl = '';

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _heightAnimation;

  AnimationController get animationController => _animationController;
  Animation<double> get scaleAnimation => _scaleAnimation;
  Animation<double> get heightAnimation => _heightAnimation;

  @override
  void onInit() {
    super.onInit();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _scaleAnimation =
        Tween<double>(begin: 0, end: 1.0).animate(animationController);

    _heightAnimation = Tween<double>(begin: 10.0, end: 75.0).animate(
      CurvedAnimation(
        parent: animationController,
        curve: Curves.easeOutBack,
      ),
    );

    final args = Get.arguments as List;
    final Playlist? playlistArg = args[0];
    final playlistId = args[1];
    fetchPlaylistDetails(playlistArg, playlistId);

    Future.delayed(
      const Duration(milliseconds: 200),
      () => Get.find<HomeScreenController>().whenHomeScreenOnTop(),
    );
  }

  Future<Box> _libraryPlaylistsBox() async {
    if (Hive.isBoxOpen("LibraryPlaylists")) {
      return Hive.box("LibraryPlaylists");
    }
    return Hive.openBox("LibraryPlaylists");
  }

  Future<Box> _playlistSongsBox(String id) async {
    if (Hive.isBoxOpen(id)) {
      return Hive.box(id);
    }
    return Hive.openBox(id);
  }

  @override
  void fetchPlaylistDetails(Playlist? playlist_, String playlistId) async {
    final isIdOnly = playlist_ == null;
    final isPipedPlaylist = playlist_?.isPipedPlaylist ?? false;

    isDefaultPlaylist.value = (playlistId == "SongDownloads" ||
        playlistId == "SongsCache" ||
        playlistId == "LIBRP" ||
        playlistId == "LIBFAV");

    if (!isIdOnly && !playlist_.isCloudPlaylist) {
      playlist.value = playlist_;
      _animationController.forward();
      fetchSongsfromDatabase(playlistId);
      isContentFetched.value = true;

      Future.delayed(
        const Duration(seconds: 1),
        () => _updatePlaylistThumbSongBased(),
      );
      return;
    }

    if (!isIdOnly) {
      playlist.value = playlist_;
      _animationController.forward();
    }

    try {
      if (await checkIfAddedToLibrary(playlistId)) {
        final songsBox = await _playlistSongsBox(playlist.value.playlistId);
        if (songsBox.values.isEmpty) {
          await _fetchSongOnline(playlistId, isIdOnly, isPipedPlaylist);
          await updateSongsIntoDb();
        } else {
          fetchSongsfromDatabase(playlist.value.playlistId);
        }
      } else {
        await _fetchSongOnline(playlistId, isIdOnly, isPipedPlaylist);
      }

      isContentFetched.value = true;
    } catch (e) {
      printERROR("Error fetching playlist details: $e");
    }
  }

  Future<void> _fetchSongOnline(
    String id,
    bool isIdOnly,
    bool isPipedPlaylist,
  ) async {
    isContentFetched.value = false;

    if (isPipedPlaylist) {
      songList.value = await Get.find<PipedServices>().getPlaylistSongs(id);
      isContentFetched.value = true;
      checkDownloadStatus();
      return;
    }

    final content =
        await _musicServices.getPlaylistOrAlbumSongs(playlistId: id);

    if (isIdOnly) {
      content['playlistId'] = id;
      playlist.value = Playlist.fromJson(content);
      _animationController.forward();
    }

    songList.value = List<MediaItem>.from(content['tracks']);
    isContentFetched.value = true;
    checkDownloadStatus();
  }

  @override
  void syncPlaylistSongs() {
    _fetchSongOnline(playlist.value.playlistId, false, false).then((_) async {
      await updateSongsIntoDb();
      isContentFetched.value = true;
    });
  }

  @override
  Future<bool> checkIfAddedToLibrary(String id) async {
    final box = await _libraryPlaylistsBox();

    isAddedToLibrary.value = box.containsKey(id);

    if (isAddedToLibrary.value) {
      final raw = box.get(id);
      if (raw != null) {
        playlist.value = Playlist.fromJson(raw);
      }
      return true;
    }

    return false;
  }

  @override
  Future<bool> addNremoveFromLibrary(dynamic content, {bool add = true}) async {
    try {
      print(
        'UI PLAYLIST addNremoveFromLibrary START => ${content.playlistId} | ${content.title} | add=$add | cloud=${content.isCloudPlaylist} | piped=${content.isPipedPlaylist}',
      );

      if (content.isPipedPlaylist && !add) {
        final res =
            await Get.find<PipedServices>().deletePlaylist(content.playlistId);
        await Get.find<LibraryPlaylistsController>().syncPipedPlaylist();
        return (res.code == 1);
      }

      final box = await _libraryPlaylistsBox();

      if (add) {
        if (content.isCloudPlaylist) {
          final localPlaylistId = "LIB${DateTime.now().millisecondsSinceEpoch}";

          final localPlaylist = Playlist(
            title: content.title,
            playlistId: localPlaylistId,
            thumbnailUrl: content.thumbnailUrl,
            description: content.description ?? "Library Playlist",
            isCloudPlaylist: false,
            isPipedPlaylist: false,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            deleted: false,
          );

          await box.put(localPlaylistId, localPlaylist.toJson());

          final songsBox = await _playlistSongsBox(localPlaylistId);
          await songsBox.clear();

          final songListCopy = songList.toList();
          for (int i = 0; i < songListCopy.length; i++) {
            await songsBox.put(i, MediaItemBuilder.toJson(songListCopy[i]));
          }

          playlist.value = localPlaylist;
          isAddedToLibrary.value = true;

          print(
            'UI PLAYLIST local copy created => ${localPlaylist.playlistId}',
          );
        } else {
          final id = content.playlistId;
          content.touch();
          await box.put(id, content.toJson());
          playlist.value = content;
          isAddedToLibrary.value = true;
          await updateSongsIntoDb();
          print('UI PLAYLIST saved existing local => $id');
        }
      } else {
        final id = playlist.value.playlistId;

        if (!playlist.value.isPipedPlaylist) {
          playlist.value.markDeleted();
          await box.put(id, playlist.value.toJson());
        }

        isAddedToLibrary.value = false;

        print('UI PLAYLIST soft removed => $id');
      }

      await Get.find<SharedLibraryService>().exportPlaylists();
      print('UI PLAYLIST export done');

      Get.find<LibraryPlaylistsController>().refreshLib();
      print('UI PLAYLIST refreshLib done');

      return true;
    } catch (e, st) {
      print('UI PLAYLIST addNremoveFromLibrary ERROR => $e');
      debugPrintStack(stackTrace: st);
      return false;
    }
  }

  @override
  Future<void> updateSongsIntoDb() async {
    final id = playlist.value.playlistId;
    final songsBox = await _playlistSongsBox(id);

    await songsBox.clear();

    final songListCopy = songList.toList();
    for (int i = 0; i < songListCopy.length; i++) {
      await songsBox.put(i, MediaItemBuilder.toJson(songListCopy[i]));
    }

    if (!playlist.value.isCloudPlaylist && !playlist.value.isPipedPlaylist) {
      playlist.value.touch();
      final box = await _libraryPlaylistsBox();
      await box.put(playlist.value.playlistId, playlist.value.toJson());
      await Get.find<SharedLibraryService>().exportPlaylists();
    }

    _updatePlaylistThumbSongBased();
  }

  @override
  Future<void> deleteMultipleSongs(List<MediaItem> songs) async {
    final id = playlist.value.playlistId;
    final isoffline = id == "SongsCache" || id == "SongDownloads";

    final box_ = await _playlistSongsBox(id);

    for (MediaItem element in songs) {
      final index = box_.values
          .toList()
          .indexWhere((ele) => ele['videoId'] == element.id);

      if (index >= 0) {
        await box_.deleteAt(index);
      }

      if (isoffline) {
        await Get.find<LibrarySongsController>()
            .removeSong(element, id == "SongDownloads");
      }

      songList.removeWhere((song) => song.id == element.id);
    }

    if (!playlist.value.isCloudPlaylist && !playlist.value.isPipedPlaylist) {
      playlist.value.touch();
      final box = await _libraryPlaylistsBox();
      await box.put(playlist.value.playlistId, playlist.value.toJson());
      await Get.find<SharedLibraryService>().exportPlaylists();
    }

    _updatePlaylistThumbSongBased();
  }

  void addNRemoveItemsinList(
    MediaItem? item, {
    required String action,
    int? index,
  }) {
    if (action == 'add') {
      if (tempListContainer.isNotEmpty) {
        index != null
            ? tempListContainer.insert(index, item!)
            : tempListContainer.add(item!);
        return;
      }
      index != null ? songList.insert(index, item!) : songList.add(item!);
    } else {
      if (tempListContainer.isNotEmpty) {
        index != null
            ? tempListContainer.removeAt(index)
            : tempListContainer.remove(item);
      }
      index != null ? songList.removeAt(index) : songList.remove(item);
    }

    if (!playlist.value.isCloudPlaylist && !playlist.value.isPipedPlaylist) {
      playlist.value.touch();
    }

    _updatePlaylistThumbSongBased();
  }

  @override
  void fetchAlbumDetails(Album? album_, String albumId) {}

  void _updatePlaylistThumbSongBased() {
    final currentPlaylist = playlist.value;

    if (isDefaultPlaylist.isTrue || currentPlaylist.isCloudPlaylist) {
      return;
    }

    Playlist updatedplaylist;
    if (songList.isNotEmpty) {
      updatedplaylist = currentPlaylist.copyWith(
        thumbnailUrl: songList[0].artUri.toString(),
      );
    } else {
      updatedplaylist = currentPlaylist.copyWith(
        thumbnailUrl: Playlist.thumbPlaceholderUrl,
      );
    }

    if (Thumbnail(currentPlaylist.thumbnailUrl).extraHigh ==
        Thumbnail(updatedplaylist.thumbnailUrl).extraHigh) {
      return;
    }

    playlist.value = updatedplaylist;
    Get.find<LibraryPlaylistsController>().updatePlaylistIntoDb(updatedplaylist);
  }

  @override
  void onClose() {
    tempListContainer.clear();
    _animationController.dispose();
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    super.onClose();
  }

  Future<void> exportPlaylistToJson(BuildContext context) async {
    if (!await PermissionService.getExtStoragePermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(context, "permissionDenied".tr, size: SanckBarSize.MEDIUM),
        );
      }
      return;
    }

    try {
      isExporting.value = true;
      exportProgress.value = 0.1;

      if (context.mounted) {
        _showProgressDialog(context, "exportingPlaylist".tr);
      }

      final Directory exportDir = await _getExportDirectory();
      exportProgress.value = 0.2;

      final playlistData = {
        "playlistInfo": playlist.value.toJson(),
        "songs": songList.map((song) => MediaItemBuilder.toJson(song)).toList(),
        "exportDate": DateTime.now().toIso8601String(),
        "appVersion": Get.find<SettingsScreenController>().currentVersion,
      };
      exportProgress.value = 0.5;

      final sanitizedName =
          playlist.value.title.replaceAll(RegExp(r'[^\w\s]+'), '_');

      String filename = "$sanitizedName.json";
      String filePath = "${exportDir.path}/$filename";
      File file = File(filePath);

      int counter = 1;
      while (await file.exists()) {
        filename = "${sanitizedName}_$counter.json";
        filePath = "${exportDir.path}/$filename";
        file = File(filePath);
        counter++;
      }

      exportProgress.value = 0.7;

      await file.writeAsString(jsonEncode(playlistData));
      exportProgress.value = 1.0;

      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      String locationMsg = _getLocationMessage(exportDir.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(
            context,
            "${"playlistExportedMsg".tr}: $locationMsg",
            size: SanckBarSize.MEDIUM,
          ),
        );
      }
    } catch (e) {
      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      printERROR("Error exporting playlist: $e");

      String errorMsg = "exportError".tr;
      if (e is FileSystemException) {
        if (e.osError?.errorCode == 13) {
          errorMsg = "exportErrorPermission".tr;
        } else if (e.osError?.errorCode == 28) {
          errorMsg = "exportErrorStorage".tr;
        }
      } else if (e is FormatException) {
        errorMsg = "exportErrorFormat".tr;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(context, errorMsg, size: SanckBarSize.MEDIUM),
        );
      }
    } finally {
      isExporting.value = false;
      exportProgress.value = 0.0;
    }
  }

  Future<void> exportPlaylistToCsv(BuildContext context) async {
    if (!await PermissionService.getExtStoragePermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(context, "permissionDenied".tr, size: SanckBarSize.MEDIUM),
        );
      }
      return;
    }

    try {
      isExporting.value = true;
      exportProgress.value = 0.1;

      if (context.mounted) {
        _showProgressDialog(context, "exportingPlaylist".tr);
      }

      final Directory exportDir = await _getExportDirectory();
      exportProgress.value = 0.2;

      final csvContent = _generateCsvContent();
      exportProgress.value = 0.5;

      final sanitizedName =
          playlist.value.title.replaceAll(RegExp(r'[^\w\s]+'), '_');

      String filename = "$sanitizedName.csv";
      String filePath = "${exportDir.path}/$filename";
      File file = File(filePath);

      int counter = 1;
      while (await file.exists()) {
        filename = "${sanitizedName}_$counter.csv";
        filePath = "${exportDir.path}/$filename";
        file = File(filePath);
        counter++;
      }

      exportProgress.value = 0.7;

      await file.writeAsString(csvContent);
      exportProgress.value = 1.0;

      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      String locationMsg = _getLocationMessage(exportDir.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(
            context,
            "${"playlistExportedMsg".tr}: $locationMsg",
            size: SanckBarSize.MEDIUM,
          ),
        );
      }
    } catch (e) {
      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      printERROR("Error exporting playlist to CSV: $e");

      String errorMsg = "exportError".tr;
      if (e is FileSystemException) {
        if (e.osError?.errorCode == 13) {
          errorMsg = "exportErrorPermission".tr;
        } else if (e.osError?.errorCode == 28) {
          errorMsg = "exportErrorStorage".tr;
        }
      } else if (e is FormatException) {
        errorMsg = "exportErrorFormat".tr;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(context, errorMsg, size: SanckBarSize.MEDIUM),
        );
      }
    } finally {
      isExporting.value = false;
      exportProgress.value = 0.0;
    }
  }

  String _generateCsvContent() {
    final buffer = StringBuffer();

    buffer.writeln(
      'PlaylistBrowseId,PlaylistName,MediaId,Title,Artists,Duration,ThumbnailUrl,AlbumId,AlbumTitle,ArtistIds',
    );

    for (final song in songList) {
      final playlistBrowseId =
          (!playlist.value.isCloudPlaylist || playlist.value.isPipedPlaylist)
              ? ''
              : _escapeCsvField(playlist.value.playlistId);
      final playlistName = _escapeCsvField(playlist.value.title);
      final mediaId = _escapeCsvField(song.id);
      final title = _escapeCsvField(song.title);

      final artistsList = song.extras?['artists'] as List?;
      final artists = artistsList != null
          ? _escapeCsvField(artistsList.map((a) => a['name']).join(', '))
          : '';

      final duration =
          song.duration != null ? _formatDuration(song.duration!) : '';

      final thumbnailUrl = _escapeCsvField(song.artUri.toString());

      final albumData = song.extras?['album'] as Map?;
      final albumId =
          albumData != null ? _escapeCsvField(albumData['id'] ?? '') : '';
      final albumTitle =
          albumData != null ? _escapeCsvField(albumData['name'] ?? '') : '';

      final artistIds = artistsList != null && artistsList.isNotEmpty
          ? _escapeCsvField(artistsList.map((a) => a['id'] ?? '').join(','))
          : '';

      buffer.writeln(
        '$playlistBrowseId,$playlistName,$mediaId,$title,$artists,$duration,$thumbnailUrl,$albumId,$albumTitle,$artistIds',
      );
    }

    return buffer.toString();
  }

  String _escapeCsvField(String field) {
    String escaped = field.replaceAll('"', '""');

    if (escaped.contains(',') ||
        escaped.contains('\n') ||
        escaped.contains('"')) {
      escaped = '"$escaped"';
    }

    return escaped;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  Future<Directory> _getExportDirectory() async {
    Directory directory;
    const appFolderName = "HarmonyMusic";

    try {
      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/Download/$appFolderName');
      } else if (Platform.isIOS) {
        final docDir = await path_provider.getApplicationDocumentsDirectory();
        directory = Directory('${docDir.path}/$appFolderName');
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final homeDir =
            Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
        directory = Directory('$homeDir/Downloads/$appFolderName');
      } else {
        final tempDir = await path_provider.getTemporaryDirectory();
        directory = Directory('${tempDir.path}/$appFolderName');
      }

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      return directory;
    } catch (e) {
      final appDocDir = await path_provider.getApplicationDocumentsDirectory();
      directory = Directory('${appDocDir.path}/$appFolderName');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory;
    }
  }

  String _getLocationMessage(String path) {
    if (Platform.isAndroid) {
      return "Downloads/HarmonyMusic";
    } else if (Platform.isIOS) {
      return "Files App > HarmonyMusic";
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return "Downloads/HarmonyMusic";
    } else {
      return path.split('/').last;
    }
  }

  void _showProgressDialog(BuildContext context, String title) {
    Get.dialog(
      AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Obx(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: exportProgress.value,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                "${(exportProgress.value * 100).toInt()}%",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
      barrierDismissible: false,
    );
  }
}