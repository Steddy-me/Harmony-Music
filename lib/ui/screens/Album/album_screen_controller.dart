import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/base_class/playlist_album_screen_con_base.dart';
import 'package:harmonymusic/models/album.dart';
import 'package:harmonymusic/models/playlist.dart';
import 'package:harmonymusic/utils/helper.dart';
import 'package:hive/hive.dart';

import '../../../mixins/additional_opeartion_mixin.dart';
import '../../../models/media_Item_builder.dart';
import '../../../services/shared_library_service.dart';
import '../Home/home_screen_controller.dart';
import '../Library/library_controller.dart';

class AlbumScreenController extends PlaylistAlbumScreenControllerBase
    with AdditionalOpeartionMixin, GetSingleTickerProviderStateMixin {
  final album =
      Album(title: "", browseId: "", thumbnailUrl: "", artists: []).obs;
  final isOfflineAlbum = false.obs;

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

    _heightAnimation = Tween<double>(begin: 10.0, end: 90.0).animate(
      CurvedAnimation(
        parent: animationController,
        curve: Curves.easeOutBack,
      ),
    );

    final args = Get.arguments as (Album?, String);

    print('ALBUM onInit START');
    print('ALBUM args => title=${args.$1?.title} | browseId=${args.$1?.browseId} | argId=${args.$2}');

    fetchAlbumDetails(args.$1, args.$2);

    Future.delayed(
      const Duration(milliseconds: 200),
      () => Get.find<HomeScreenController>().whenHomeScreenOnTop(),
    );
  }

  Future<Box> _albumsBox() async {
    if (Hive.isBoxOpen("LibraryAlbums")) {
      return Hive.box("LibraryAlbums");
    }
    return Hive.openBox("LibraryAlbums");
  }

  Future<Box> _albumSongsBox(String id) async {
    if (Hive.isBoxOpen(id)) {
      return Hive.box(id);
    }
    return Hive.openBox(id);
  }

  @override
  void fetchAlbumDetails(Album? album_, String albumId) async {
    try {
      print('ALBUM fetchAlbumDetails START => albumId=$albumId');

      if (album_ != null) {
        print('ALBUM initial arg => ${album_.title} | ${album_.browseId}');
        album.value = album_;
        animationController.forward();
      }

      final alreadyAdded = await checkIfAddedToLibrary(albumId);
      print('ALBUM checkIfAddedToLibrary => $albumId | added=$alreadyAdded');

      if (!alreadyAdded) {
        final content =
            await musicServices.getPlaylistOrAlbumSongs(albumId: albumId);

        content['browseId'] = albumId;
        album.value = Album.fromJson(content);
        animationController.forward();

        final tracks = List<MediaItem>.from(content['tracks'] ?? []);
        songList.value = tracks;

        print(
            'ALBUM network loaded => ${album.value.title} | ${album.value.browseId}');
        print('ALBUM tracks loaded => ${songList.length}');
      } else {
        final box = await _albumSongsBox(albumId);
        songList.value = box.values
            .map<MediaItem?>((item) => MediaItemBuilder.fromJson(item))
            .whereType<MediaItem>()
            .toList();

        print(
            'ALBUM local loaded => ${album.value.title} | ${album.value.browseId}');
        print('ALBUM local tracks => ${songList.length}');
      }

      checkDownloadStatus();
      isContentFetched.value = true;
      print('ALBUM fetchAlbumDetails END => ${album.value.browseId}');
    } catch (e, st) {
      printERROR("Error fetching album details: $e");
      debugPrintStack(stackTrace: st);
    }
  }

  @override
  Future<bool> checkIfAddedToLibrary(String id) async {
    try {
      print('ALBUM checkIfAddedToLibrary START => $id');

      final box = await _albumsBox();
      isAddedToLibrary.value = box.containsKey(id);

      if (isAddedToLibrary.value) {
        final raw = box.get(id);
        if (raw != null) {
          album.value = Album.fromJson(raw);
        }
      }

      print(
          'ALBUM checkIfAddedToLibrary END => $id | ${isAddedToLibrary.value}');
      return isAddedToLibrary.value;
    } catch (e, st) {
      printERROR("Error checking album in library: $e");
      debugPrintStack(stackTrace: st);
      isAddedToLibrary.value = false;
      return false;
    }
  }

  @override
  Future<bool> addNremoveFromLibrary(content, {bool add = true}) async {
    try {
      print(
        'UI ALBUM addNremoveFromLibrary START => ${content.browseId} | add=$add | title=${content.title}',
      );

      final id = (content.browseId ?? '').toString().trim();
      if (id.isEmpty) {
        print('UI ALBUM ERROR => empty browseId');
        return false;
      }

      final box = await _albumsBox();

      if (add) {
        await box.put(id, content.toJson());
        print('UI ALBUM metadata saved => $id');

        await updateSongsIntoDb();

        isAddedToLibrary.value = true;
        print('UI ALBUM saved => $id');
      } else {
        await box.delete(id);
        print('UI ALBUM metadata deleted => $id');

        final songsBox = await _albumSongsBox(id);
        await songsBox.clear();

        isAddedToLibrary.value = false;
        print('UI ALBUM songs cleared => $id');
        print('UI ALBUM deleted => $id');
      }

      print('UI ALBUM export start => $id');
      await Get.find<SharedLibraryService>().exportAlbums();
      print('UI ALBUM export done => $id');

      Get.find<LibraryAlbumsController>().refreshLib();
      print('UI ALBUM refreshLib done => $id');

      return true;
    } catch (e, st) {
      print('UI ALBUM ERROR => $e');
      debugPrintStack(stackTrace: st);
      return false;
    }
  }

  @override
  Future<void> updateSongsIntoDb() async {
    try {
      final id = album.value.browseId;
      print('UI ALBUM updateSongsIntoDb START => $id');
      print('UI ALBUM updateSongsIntoDb SONG COUNT => ${songList.length}');

      if (id.trim().isEmpty) {
        print('UI ALBUM updateSongsIntoDb ERROR => empty album browseId');
        return;
      }

      final songsBox = await _albumSongsBox(id);
      await songsBox.clear();

      final songListCopy = songList.toList();
      for (int i = 0; i < songListCopy.length; i++) {
        await songsBox.put(i, MediaItemBuilder.toJson(songListCopy[i]));
      }

      print('UI ALBUM updateSongsIntoDb DONE => $id');
    } catch (e, st) {
      print('UI ALBUM updateSongsIntoDb ERROR => $e');
      debugPrintStack(stackTrace: st);
    }
  }

  @override
  void onClose() {
    tempListContainer.clear();
    _animationController.dispose();
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    super.onClose();
  }

  @override
  Future<void> deleteMultipleSongs(List<MediaItem> songs) async {}

  @override
  void fetchPlaylistDetails(Playlist? playlist_, String playlistId) {}

  @override
  void syncPlaylistSongs() {}
}