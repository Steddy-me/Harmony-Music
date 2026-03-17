import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/ui/widgets/snackbar.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../../../utils/house_keeping.dart';
import '../../../utils/helper.dart';
import '../../widgets/add_to_playlist.dart';
import '../Settings/settings_screen_controller.dart';
import '/models/album.dart';
import '/models/artist.dart';
import '/models/media_Item_builder.dart';
import '/models/playlist.dart';
import '/services/piped_service.dart';
import '/services/shared_library_service.dart';
import '/ui/widgets/sort_widget.dart';

class LibrarySongsController extends GetxController {
  late RxList<MediaItem> librarySongsList = RxList();
  final isSongFetched = false.obs;
  List<MediaItem> tempListContainer = [];
  SortWidgetController? sortWidgetController;
  final additionalOperationMode = OperationMode.none.obs;

  @override
  void onInit() {
    init();
    super.onInit();
  }

  Future<void> init() async {
    List<String> songsList = [];
    final cacheDir = (await getTemporaryDirectory()).path;
    if (Directory("$cacheDir/cachedSongs/").existsSync()) {
      final downloadedFiles = Directory("$cacheDir/cachedSongs")
          .listSync()
          .where((f) => !['mime', 'part']
              .contains(f.path.replaceAll(RegExp(r'^.*\.'), '')));
      songsList.addAll(downloadedFiles
          .map((e) {
            RegExpMatch? match =
                RegExp(".cachedSongs/([^#]*)?.mp3").firstMatch(e.path);
            if (match != null) {
              return match[1]!;
            }
            return null;
          })
          .whereType<String>()
          .toList());
    }

    final box = Hive.box("SongsCache");
    for (var element in box.keys) {
      if (!songsList.contains(element)) {
        box.delete(element);
      }
    }

    librarySongsList.value = box.values
        .map<MediaItem?>((item) => MediaItemBuilder.fromJson(item))
        .whereType<MediaItem>()
        .toList();
    
    final sharedSongsBox = await Hive.openBox("SharedSongs");
    librarySongsList.addAll(sharedSongsBox.values
        .map<MediaItem?>((item) => MediaItemBuilder.fromJson(item))
        .whereType<MediaItem>()
        .toList());
    await sharedSongsBox.close();

    librarySongsList.addAll(Hive.box("SongDownloads")
        .values
        .map<MediaItem?>((item) => MediaItemBuilder.fromJson(item))
        .whereType<MediaItem>()
        .toList());
    isSongFetched.value = true;

    startHouseKeeping();
  }

  void onSort(SortType sortType, bool isAscending) {
    final songlist = librarySongsList.toList();
    sortSongsNVideos(songlist, sortType, isAscending);
    librarySongsList.value = songlist;
  }

  void onSearchStart(String? tag) {
    tempListContainer = librarySongsList.toList();
  }

  void onSearch(String value, String? tag) {
    final songlist = tempListContainer
        .where((element) =>
            element.title.toLowerCase().contains(value.toLowerCase()))
        .toList();
    librarySongsList.value = songlist;
  }

  void onSearchClose(String? tag) {
    librarySongsList.value = tempListContainer.toList();
    tempListContainer.clear();
  }

  Future<void> removeSong(MediaItem item, bool isDownloaded, {String? url}) async {
    if (tempListContainer.isNotEmpty) {
      tempListContainer.remove(item);
    }
    librarySongsList.remove(item);
    String filePath = "";
    if (isDownloaded) {
      filePath = item.extras!['url'] ?? url;
    } else {
      final cacheDir = (await getTemporaryDirectory()).path;
      filePath = "$cacheDir/cachedSongs/${item.id}.mp3";
    }

    if (await File(filePath).exists()) {
      await File(filePath).delete();
    }

    final thumbFile = File(
      "${Get.find<SettingsScreenController>().supportDirPath}/thumbnails/${item.id}.png",
    );
    if (await thumbFile.exists()) {
      await thumbFile.delete();
    }
  }

  final additionalOperationTempList = [].obs;
  final additionalOperationTempMap = <int, bool>{}.obs;

  void startAdditionalOperation(
    SortWidgetController sortWidgetController_,
    OperationMode mode,
  ) {
    sortWidgetController = sortWidgetController_;
    additionalOperationTempList.value = librarySongsList.toList();
    if (mode == OperationMode.addToPlaylist || mode == OperationMode.delete) {
      for (int i = 0; i < additionalOperationTempList.length; i++) {
        additionalOperationTempMap[i] = false;
      }
    }
    additionalOperationMode.value = mode;
  }

  void checkIfAllSelected() {
    sortWidgetController!.isAllSelected.value =
        !additionalOperationTempMap.containsValue(false);
  }

  void selectAll(bool selected) {
    for (int i = 0; i < additionalOperationTempList.length; i++) {
      additionalOperationTempMap[i] = selected;
    }
  }

  void performAdditionalOperation() {
    final currMode = additionalOperationMode.value;
    if (currMode == OperationMode.delete) {
      deleteMultipleSongs(selectedSongs()).then((value) {
        sortWidgetController?.setActiveMode(OperationMode.none);
        cancelAdditionalOperation();
      });
    } else if (currMode == OperationMode.addToPlaylist) {
      showDialog(
        context: Get.context!,
        builder: (context) => AddToPlaylist(selectedSongs()),
      ).whenComplete(() {
        Get.delete<AddToPlaylistController>();
        sortWidgetController?.setActiveMode(OperationMode.none);
        cancelAdditionalOperation();
      });
    }
  }

  Future<void> deleteMultipleSongs(List<MediaItem> songs) async {
    final downloadsBox = await Hive.openBox("SongDownloads");
    final cacheBox = await Hive.openBox("SongsCache");
    for (MediaItem element in songs) {
      if (downloadsBox.containsKey(element.id)) {
        await downloadsBox.delete(element.id);
        removeSong(element, true);
      } else {
        await cacheBox.delete(element.id);
        removeSong(element, false);
      }
    }
  }

  List<MediaItem> selectedSongs() {
    return additionalOperationTempMap.entries
        .map((item) {
          if (item.value) {
            return additionalOperationTempList[item.key];
          }
          return null;
        })
        .whereType<MediaItem>()
        .toList();
  }

  void cancelAdditionalOperation() {
    sortWidgetController!.isAllSelected.value = false;
    sortWidgetController = null;
    additionalOperationMode.value = OperationMode.none;
    additionalOperationTempList.clear();
    additionalOperationTempMap.clear();
  }
}

class LibraryPlaylistsController extends GetxController
    with GetTickerProviderStateMixin {
  late AnimationController controller;

  final playlistCreationMode = "local".obs;

  static final initPlst = [
    Playlist(
      title: "recentlyPlayed".tr,
      playlistId: "LIBRP",
      thumbnailUrl: Playlist.thumbPlaceholderUrl,
      isCloudPlaylist: false,
    ),
    Playlist(
      title: "favorites".tr,
      playlistId: "LIBFAV",
      thumbnailUrl: Playlist.thumbPlaceholderUrl,
      isCloudPlaylist: false,
    ),
    Playlist(
      title: "cachedOrOffline".tr,
      playlistId: "SongsCache",
      thumbnailUrl: Playlist.thumbPlaceholderUrl,
      isCloudPlaylist: false,
    ),
    Playlist(
      title: "downloads".tr,
      playlistId: "SongDownloads",
      thumbnailUrl: Playlist.thumbPlaceholderUrl,
      isCloudPlaylist: false,
    ),
  ];

  late RxList<Playlist> libraryPlaylists = RxList(initPlst);
  final isContentFetched = false.obs;
  final creationInProgress = false.obs;
  final textInputController = TextEditingController();
  List<Playlist> tempListContainer = [];

  final isImporting = false.obs;
  final importProgress = 0.0.obs;

  @override
  void onInit() {
    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    refreshLib();
    super.onInit();
  }

  Future<Box> _playlistsBox() async {
    if (Hive.isBoxOpen("LibraryPlaylists")) {
      return Hive.box("LibraryPlaylists");
    }
    return Hive.openBox("LibraryPlaylists");
  }

  Future<Box> _blacklistBox() async {
    if (Hive.isBoxOpen("blacklistedPlaylist")) {
      return Hive.box("blacklistedPlaylist");
    }
    return Hive.openBox("blacklistedPlaylist");
  }

  Future<void> refreshLib() async {
    try {
      final box = await _playlistsBox();

      libraryPlaylists.value = [
        ...initPlst,
        ...(box.values
            .map<Playlist?>((item) => Playlist.fromJson(item))
            .whereType<Playlist>()
            .where((p) => !p.deleted)
            .toList()),
      ];

      final appPrefsBox = Hive.box("AppPrefs");
      if (appPrefsBox.containsKey("piped")) {
        final pipedData = appPrefsBox.get("piped");
        if (pipedData != null && pipedData['isLoggedIn'] == true) {
          await syncPipedPlaylist();
        }
      }

      isContentFetched.value = true;
    } catch (e, st) {
      debugPrint('LIBRARY PLAYLIST refreshLib ERROR => $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> updatePlaylistIntoDb(Playlist playlist) async {
    print(
      'UI PLAYLIST updatePlaylistIntoDb START => ${playlist.playlistId} | ${playlist.title}',
    );
    playlist.touch();
    final box = await _playlistsBox();
    await box.put(playlist.playlistId, playlist.toJson());
    await Get.find<SharedLibraryService>().exportPlaylists();
    print('UI PLAYLIST updatePlaylistIntoDb END => ${playlist.playlistId}');
    refreshLib();
  }

  void removePipedPlaylists() {
    for (Playlist plst in libraryPlaylists.toList()) {
      if (plst.isPipedPlaylist) {
        libraryPlaylists.remove(plst);
      }
    }
  }

  Future<void> syncPipedPlaylist() async {
    final res = await Get.find<PipedServices>().getAllPlaylists();
    final box = await _blacklistBox();
    final blacklistedPlaylist = box.values.whereType<String>().toList();

    final libPipedPlaylistsId = libraryPlaylists
            .toList()
            .map((e) {
              if (e.isPipedPlaylist) {
                return e.playlistId;
              }
              return null;
            })
            .whereType<String>()
            .toList() +
        blacklistedPlaylist;

    if (res.code == 1) {
      final cloudpipedPlaylistsId = res.response
          .map((e) => e['id'])
          .whereType<String>()
          .toList();

      for (dynamic playlist in res.response) {
        if (!libPipedPlaylistsId.contains(playlist['id'])) {
          final plst = Playlist(
            title: playlist['name'],
            playlistId: playlist['id'],
            description: "Piped Playlist",
            thumbnailUrl: playlist['thumbnail'],
            isPipedPlaylist: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            deleted: false,
          );
          libraryPlaylists.add(plst);
        }
      }

      for (Playlist playlist in libraryPlaylists.toList()) {
        if (!cloudpipedPlaylistsId.contains(playlist.playlistId) &&
            playlist.isPipedPlaylist) {
          libraryPlaylists.removeWhere(
            (element) => element.playlistId == playlist.playlistId,
          );
        }
      }
    }
  }

  Future<bool> renamePlaylist(Playlist playlist) async {
    String title = textInputController.text;
    if (title.trim().isNotEmpty) {
      if (playlist.isPipedPlaylist) {
        final res = await Get.find<PipedServices>()
            .renamePlaylist(playlist.playlistId, title);
        if (res.code == 0) return false;
        playlist.newTitle = title;
      } else {
        final box = await _playlistsBox();
        title = "${title[0].toUpperCase()}${title.substring(1).toLowerCase()}";
        playlist.newTitle = title;
        await box.put(playlist.playlistId, playlist.toJson());
        await Get.find<SharedLibraryService>().exportPlaylists();
      }
      refreshLib();
      return true;
    }
    return false;
  }

  void changeCreationMode(String? val) {
    playlistCreationMode.value = val!;
  }

  Future<Map<String, dynamic>> _buildPlaylistItemJson(MediaItem item) async {
    final downloadsBox = Hive.box("SongDownloads");
    Map<String, dynamic> itemJson;

    final downloadedRaw = downloadsBox.get(item.id);

    if (downloadedRaw is Map) {
      itemJson = Map<String, dynamic>.from(downloadedRaw);
      print('CREATE PLAYLIST USING DOWNLOADED ENTRY => ${item.id}');
    } else {
      itemJson = Map<String, dynamic>.from(MediaItemBuilder.toJson(item));
      print('CREATE PLAYLIST USING MEDIA ITEM ENTRY => ${item.id}');
    }

    final rawExtras = itemJson['extras'];
    final extras = rawExtras is Map
        ? Map<String, dynamic>.from(rawExtras)
        : <String, dynamic>{};

    final sharedPath = extras['sharedPath']?.toString();
    final sharedSongId = extras['sharedSongId']?.toString();
    final isSharedSong = extras['isSharedSong'] == true;

    if (isSharedSong && sharedPath != null && sharedPath.isNotEmpty) {
      extras['sharedSongId'] = sharedSongId;
      extras['sharedPath'] = sharedPath;
      extras['isSharedSong'] = true;

      print('CREATE PLAYLIST USING EXISTING SHARED => $sharedPath');
      itemJson['extras'] = extras;
      return itemJson;
    }

    final rawUrl = extras['url']?.toString() ?? '';
    final isLocalFile = rawUrl.isNotEmpty &&
        !rawUrl.startsWith('http://') &&
        !rawUrl.startsWith('https://');

    if (isLocalFile) {
      final sharedLibrary = Get.find<SharedLibraryService>();
      final sourceFile = File(rawUrl);

      if (await sourceFile.exists()) {
        final sharedSong =
            await sharedLibrary.sharedSongsService.importSong(sourceFile);

        final newRelativePath = 'songs/${sharedSong.filename}';

        extras['relativePath'] = newRelativePath;
        extras['sharedSongId'] = sharedSong.id;
        extras['isSharedSong'] = true;

        itemJson['relativePath'] = newRelativePath;
        itemJson['sharedSongId'] = sharedSong.id;
        itemJson['isSharedSong'] = true;

        print('CREATE PLAYLIST SHARED SONG => $newRelativePath');
      } else {
        print('CREATE PLAYLIST LOCAL FILE MISSING => $rawUrl');
      }
    } else {
      final streamUrl = (extras['streamUrl'] ?? rawUrl).toString();
      extras['streamUrl'] = streamUrl.isEmpty ? null : streamUrl;
      itemJson['streamUrl'] = extras['streamUrl'];

      print('CREATE PLAYLIST NON-LOCAL URL => $streamUrl');
    }

    itemJson['extras'] = extras;
    return itemJson;
  }

  Future<bool> createNewPlaylist({
    bool createPlaylistNaddSong = false,
    List<MediaItem>? songItems,
  }) async {
    String title = textInputController.text;
    print('UI PLAYLIST createNewPlaylist START => "$title"');

    if (title.trim().isNotEmpty) {
      dynamic newplst;

      if (playlistCreationMode.value == "piped") {
        creationInProgress.value = true;
        final res = await Get.find<PipedServices>().createPlaylist(title);
        if (res.code == 1) {
          newplst = Playlist(
            title: title,
            playlistId: "${res.response['playlistId']}",
            thumbnailUrl: songItems != null
                ? songItems[0].artUri.toString()
                : Playlist.thumbPlaceholderUrl,
            description: "Piped Playlist",
            isCloudPlaylist: true,
            isPipedPlaylist: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            deleted: false,
          );
        } else {
          creationInProgress.value = false;
          print('UI PLAYLIST createNewPlaylist FAIL piped');
          return false;
        }
      } else {
        newplst = Playlist(
          title: title,
          playlistId: "LIB${DateTime.now().millisecondsSinceEpoch}",
          thumbnailUrl: songItems != null
              ? songItems[0].artUri.toString()
              : Playlist.thumbPlaceholderUrl,
          description: "Library Playlist",
          isCloudPlaylist: false,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          deleted: false,
        );
        final box = await _playlistsBox();
        await box.put(newplst.playlistId, newplst.toJson());
        print('UI PLAYLIST local created => ${newplst.playlistId}');
      }

      libraryPlaylists.add(newplst);

      if (createPlaylistNaddSong && playlistCreationMode.value == "local") {
        final plastbox = await Hive.openBox(newplst.playlistId);

        for (MediaItem item in songItems!) {
          try {
            print('LOCAL SONG DEBUG id => ${item.id}');
            print('LOCAL SONG DEBUG title => ${item.title}');
            print('LOCAL SONG DEBUG extras => ${item.extras}');

            final itemJson = await _buildPlaylistItemJson(item);
            await plastbox.add(itemJson);
          } catch (e) {
            print('CREATE PLAYLIST ITEM ERROR => $e');
          }
        }

        await plastbox.close();

        newplst.touch();
        final box = await _playlistsBox();
        await box.put(newplst.playlistId, newplst.toJson());

        print('UI PLAYLIST songs added => ${newplst.playlistId}');
      }

      await Get.find<SharedLibraryService>().exportPlaylists();
      print('UI PLAYLIST createNewPlaylist END => ${newplst.playlistId}');

      creationInProgress.value = false;
      return true;
    }

    print('UI PLAYLIST createNewPlaylist SKIP empty title');
    return false;
  }

  Future<void> blacklistPipedPlaylist(Playlist playlist) async {
    final box = await _blacklistBox();
    await box.add(playlist.playlistId);
    libraryPlaylists.remove(playlist);
  }

  Future<void> resetBlacklistedPlaylist() async {
    final box = await _blacklistBox();
    await box.clear();
    await syncPipedPlaylist();
  }

  void onSort(SortType sortType, bool isAscending) {
    final playlists = libraryPlaylists.toList();
    playlists.removeRange(0, 4);
    sortPlayLists(playlists, sortType, isAscending);
    playlists.insertAll(0, initPlst);
    libraryPlaylists.value = playlists;
  }

  void onSearchStart(String? tag) {
    tempListContainer = libraryPlaylists.toList();
  }

  void onSearch(String value, String? tag) {
    final songlist = tempListContainer
        .where((element) =>
            element.title.toLowerCase().contains(value.toLowerCase()))
        .toList();
    libraryPlaylists.value = songlist;
  }

  void onSearchClose(String? tag) {
    libraryPlaylists.value = tempListContainer.toList();
    tempListContainer.clear();
  }

  @override
  void dispose() {
    textInputController.dispose();
    controller.dispose();
    super.dispose();
  }

  Future<void> importPlaylistFromJson(BuildContext context) async {
    try {
      isImporting.value = true;
      importProgress.value = 0.1;

      if (context.mounted) {
        _showImportProgressDialog(context);
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: 'importPlaylist'.tr,
      );

      if (result == null || result.files.isEmpty) {
        if (Get.isDialogOpen ?? false) {
          Get.back();
        }
        isImporting.value = false;
        importProgress.value = 0.0;
        return;
      }

      importProgress.value = 0.2;

      final file = File(result.files.single.path!);
      if (!await file.exists()) {
        throw FileSystemException("fileNotFound".tr);
      }

      final jsonString = await file.readAsString();
      importProgress.value = 0.3;

      final jsonData = jsonDecode(jsonString);
      importProgress.value = 0.4;

      if (!jsonData.containsKey('playlistInfo') ||
          !jsonData.containsKey('songs')) {
        throw FormatException("invalidPlaylistFile".tr);
      }

      final playlistInfo = jsonData['playlistInfo'];
      final newPlaylistId = "LIB${DateTime.now().millisecondsSinceEpoch}";
      importProgress.value = 0.5;

      final newPlaylist = Playlist(
        title: "${playlistInfo['title']} (${"imported".tr})",
        playlistId: newPlaylistId,
        thumbnailUrl: playlistInfo['thumbnailUrl'] ??
            (playlistInfo['thumbnails'] != null &&
                    playlistInfo['thumbnails'].isNotEmpty
                ? playlistInfo['thumbnails'][0]['url']
                : Playlist.thumbPlaceholderUrl),
        description: playlistInfo['description'] ?? "importedPlaylist".tr,
        isCloudPlaylist: false,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        deleted: false,
      );
      importProgress.value = 0.6;

      final box = await _playlistsBox();
      await box.put(newPlaylistId, newPlaylist.toJson());
      importProgress.value = 0.7;

      final songsBox = await Hive.openBox(newPlaylistId);
      final songsList = jsonData['songs'] as List;

      final totalSongs = songsList.length;
      for (int i = 0; i < totalSongs; i++) {
        await songsBox.put(i, songsList[i]);
        importProgress.value = 0.7 + (0.25 * (i + 1) / totalSongs);
      }

      await songsBox.close();
      await Get.find<SharedLibraryService>().exportPlaylists();
      importProgress.value = 1.0;

      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      refreshLib();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(
            context,
            "${"playlistImportedMsg".tr}: ${newPlaylist.title}",
            size: SanckBarSize.MEDIUM,
          ),
        );
      }
    } catch (e) {
      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      printERROR("Error importing playlist: $e");

      String errorMsg = "importError".tr;
      if (e is FileSystemException) {
        errorMsg = "importErrorFileAccess".tr;
      } else if (e is FormatException) {
        errorMsg = "importErrorFormat".tr;
      } else if (e.toString().contains("invalidPlaylistFile")) {
        errorMsg = "invalidPlaylistFile".tr;
      } else if (e is HiveError) {
        errorMsg = "importErrorDatabase".tr;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          snackbar(context, errorMsg, size: SanckBarSize.MEDIUM),
        );
      }
    } finally {
      isImporting.value = false;
      importProgress.value = 0.0;
    }
  }

  void _showImportProgressDialog(BuildContext context) {
    Get.dialog(
      AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          "importingPlaylist".tr,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Obx(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: Get.isRegistered<LibraryPlaylistsController>()
                    ? importProgress.value
                    : 0,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                "${(Get.isRegistered<LibraryPlaylistsController>() ? importProgress.value * 100 : 0).toInt()}%",
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

class LibraryAlbumsController extends GetxController {
  late RxList<Album> libraryAlbums = RxList();
  final isContentFetched = false.obs;
  List<Album> tempListContainer = [];

  @override
  void onInit() {
    refreshLib();
    super.onInit();
  }

  Future<Box> _albumsBox() async {
    if (Hive.isBoxOpen("LibraryAlbums")) {
      return Hive.box("LibraryAlbums");
    }
    return Hive.openBox("LibraryAlbums");
  }

  Future<void> refreshLib() async {
    try {
      final box = await _albumsBox();
      libraryAlbums.value = box.values
          .map<Album?>((item) => Album.fromJson(item))
          .whereType<Album>()
          .toList();

      isContentFetched.value = true;
    } catch (e, st) {
      debugPrint('LIBRARY ALBUM refreshLib ERROR => $e');
      debugPrintStack(stackTrace: st);
    }
  }

  void onSort(SortType sortType, bool isAscending) {
    final albumList = libraryAlbums.toList();
    sortAlbumNSingles(albumList, sortType, isAscending);
    libraryAlbums.value = albumList;
  }

  void onSearchStart(String? tag) {
    tempListContainer = libraryAlbums.toList();
  }

  void onSearch(String value, String? tag) {
    final songlist = tempListContainer
        .where((element) =>
            element.title.toLowerCase().contains(value.toLowerCase()))
        .toList();
    libraryAlbums.value = songlist;
  }

  void onSearchClose(String? tag) {
    libraryAlbums.value = tempListContainer.toList();
    tempListContainer.clear();
  }
}

class LibraryArtistsController extends GetxController {
  RxList<Artist> libraryArtists = RxList();
  final isContentFetched = false.obs;
  List<Artist> tempListContainer = [];

  @override
  void onInit() {
    refreshLib();
    super.onInit();
  }

  Future<Box> _artistsBox() async {
    if (Hive.isBoxOpen("LibraryArtists")) {
      return Hive.box("LibraryArtists");
    }
    return Hive.openBox("LibraryArtists");
  }

  Future<void> refreshLib() async {
    try {
      final box = await _artistsBox();
      libraryArtists.value = box.values
          .map<Artist?>((item) => Artist.fromJson(item))
          .whereType<Artist>()
          .toList();
      isContentFetched.value = true;
    } catch (e, st) {
      debugPrint('LIBRARY ARTIST refreshLib ERROR => $e');
      debugPrintStack(stackTrace: st);
    }
  }

  void onSort(SortType sortType, bool isAscending) {
    final artistList = libraryArtists.toList();
    sortArtist(artistList, sortType, isAscending);
    libraryArtists.value = artistList;
  }

  void onSearchStart(String? tag) {
    tempListContainer = libraryArtists.toList();
  }

  void onSearch(String value, String? tag) {
    final songlist = tempListContainer
        .where((element) =>
            element.name.toLowerCase().contains(value.toLowerCase()))
        .toList();
    libraryArtists.value = songlist;
  }

  void onSearchClose(String? tag) {
    libraryArtists.value = tempListContainer.toList();
    tempListContainer.clear();
  }
}