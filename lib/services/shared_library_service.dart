import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/media_Item_builder.dart';
import '../models/playlist.dart';
import '../ui/screens/Library/library_controller.dart';
import 'shared_songs_service.dart';

class SharedLibraryService extends GetxService {
  static const String settingsKey = 'sharedLocationPath';
  static const String lockFileName = 'library.lock';

  late Directory sharedDir;
  late SharedSongsService sharedSongsService;

  Timer? _syncTimer;
  final Map<String, int> _lastKnownFileTimes = {};

  Future<SharedLibraryService> init() async {
    sharedDir = await _resolveSharedDirectory();
    print('SHARED DIR INIT => ${sharedDir.path}');

    if (!await sharedDir.exists()) {
      await sharedDir.create(recursive: true);
      print('SHARED DIR CREATED => ${sharedDir.path}');
    } else {
      print('SHARED DIR EXISTS => ${sharedDir.path}');
    }

    sharedSongsService = SharedSongsService(sharedDir);
    await sharedSongsService.init();

    await _initKnownFileTimes();

    return this;
  }

  Future<Directory> _resolveSharedDirectory() async {
    final appPrefs = Hive.box('AppPrefs');
    final customPath = appPrefs.get(settingsKey);

    if (customPath != null && customPath.toString().trim().isNotEmpty) {
      final dir = Directory(customPath.toString());
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        print('SHARED DIR CUSTOM => ${dir.path}');
        return dir;
      } catch (e) {
        print('SHARED DIR CUSTOM ERROR => $e');
      }
    }

    if (GetPlatform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      final dir = Directory(p.join(extDir!.path, 'HarmonyShared'));
      print('SHARED DIR ANDROID APP => ${dir.path}');
      return dir;
    }

    if (GetPlatform.isWindows || GetPlatform.isLinux || GetPlatform.isMacOS) {
      final docsDir = await getApplicationDocumentsDirectory();
      final userDir = docsDir.parent.path;
      final dir = Directory(p.join(userDir, 'Music', 'HarmonyShared'));
      print('SHARED DIR DESKTOP => ${dir.path}');
      return dir;
    }

    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'HarmonyShared'));
    print('SHARED DIR FALLBACK => ${dir.path}');
    return dir;
  }

  File _jsonFile(String name) => File(p.join(sharedDir.path, name));

  File get lockFile => File(p.join(sharedDir.path, lockFileName));

  Future<void> _acquireLock() async {
    int retries = 0;

    while (await lockFile.exists()) {
      await Future.delayed(const Duration(milliseconds: 200));
      retries++;
      if (retries > 25) {
        throw Exception('Shared library is locked');
      }
    }

    await lockFile.writeAsString(DateTime.now().toIso8601String());
  }

  Future<void> _releaseLock() async {
    if (await lockFile.exists()) {
      await lockFile.delete();
    }
  }

  Future<void> _initKnownFileTimes() async {
    for (final name in [
      'favorites.json',
      'albums.json',
      'artists.json',
      'playlists.json',
      'songs_index.json',
    ]) {
      final file = _jsonFile(name);
      if (await file.exists()) {
        _lastKnownFileTimes[name] =
            (await file.lastModified()).millisecondsSinceEpoch;
      } else {
        _lastKnownFileTimes[name] = 0;
      }
    }
  }

  void startAutoSync() {
    _syncTimer?.cancel();

    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkForUpdates(),
    );

    print('AUTO SYNC STARTED');
  }

  void stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    print('AUTO SYNC STOPPED');
  }

  Future<void> _checkForUpdates() async {
    try {
      bool changed = false;

      for (final name in [
        'favorites.json',
        'albums.json',
        'artists.json',
        'playlists.json',
        'songs_index.json',
      ]) {
        final file = _jsonFile(name);
        if (!await file.exists()) continue;

        final ts = (await file.lastModified()).millisecondsSinceEpoch;
        final oldTs = _lastKnownFileTimes[name] ?? 0;

        if (ts > oldTs) {
          _lastKnownFileTimes[name] = ts;
          changed = true;
          print('SYNC CHANGE DETECTED => $name');
        }
      }

      if (!changed) return;

      print('SYNC IMPORT ALL START');
      await importAll();

      if (Get.isPrepared<LibrarySongsController>() ||
          Get.isRegistered<LibrarySongsController>()) {
        final c = Get.find<LibrarySongsController>();
        await c.init();
        c.librarySongsList.refresh();
        c.update();
        print('SYNC UI REFRESH SONGS DONE');
      }

      if (Get.isPrepared<LibraryPlaylistsController>() ||
          Get.isRegistered<LibraryPlaylistsController>()) {
        final c = Get.find<LibraryPlaylistsController>();
        c.refreshLib();
        c.libraryPlaylists.refresh();
        c.update();
        print('SYNC UI REFRESH PLAYLISTS DONE');
      }

      if (Get.isPrepared<LibraryAlbumsController>() ||
          Get.isRegistered<LibraryAlbumsController>()) {
        final c = Get.find<LibraryAlbumsController>();
        c.refreshLib();
        c.libraryAlbums.refresh();
        c.update();
        print('SYNC UI REFRESH ALBUMS DONE');
      }

      if (Get.isPrepared<LibraryArtistsController>() ||
          Get.isRegistered<LibraryArtistsController>()) {
        final c = Get.find<LibraryArtistsController>();
        c.refreshLib();
        c.libraryArtists.refresh();
        c.update();
        print('SYNC UI REFRESH ARTISTS DONE');
      }

      print('SYNC IMPORT ALL END');
    } catch (e) {
      print('SYNC ERROR => $e');
    }
  }

  Future<void> writeJson(String fileName, Map<String, dynamic> data) async {
    print('WRITE JSON START => $fileName');
    print('WRITE JSON PATH => ${_jsonFile(fileName).path}');

    await _acquireLock();
    try {
      final file = _jsonFile(fileName);
      final tempFile = File('${file.path}.tmp');

      await tempFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );

      if (await file.exists()) {
        await file.delete();
      }

      await tempFile.rename(file.path);

      _lastKnownFileTimes[fileName] =
          (await file.lastModified()).millisecondsSinceEpoch;

      print('WRITE JSON DONE => ${file.path}');
    } finally {
      await _releaseLock();
    }
  }

  Future<Map<String, dynamic>?> readJson(String fileName) async {
    final file = _jsonFile(fileName);
    print('READ JSON PATH => ${file.path}');

    if (!await file.exists()) {
      print('READ JSON MISS => $fileName');
      return null;
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      print('READ JSON EMPTY => $fileName');
      return null;
    }

    print('READ JSON OK => $fileName');
    return jsonDecode(content) as Map<String, dynamic>;
  }

  Future<void> exportFavorites() async {
    print('EXPORT FAVORITES START');
    final box = await Hive.openBox('LIBFAV');

    await writeJson('favorites.json', {
      'version': 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': box.values.toList(),
    });

    await box.close();
    print('EXPORT FAVORITES END');
  }

  Future<void> importFavorites() async {
    print('IMPORT FAVORITES START');
    final data = await readJson('favorites.json');
    if (data == null) {
      print('IMPORT FAVORITES SKIP');
      return;
    }

    final box = await Hive.openBox('LIBFAV');
    await box.clear();

    final items = (data['items'] as List?) ?? [];
    for (final item in items) {
      if (item is Map) {
        final itemMap = Map<String, dynamic>.from(item);
        final id = itemMap['id']?.toString() ??
            itemMap['videoId']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString();
        await box.put(id, itemMap);
      }
    }

    await box.close();
    print('IMPORT FAVORITES END');
  }

  Future<void> exportAlbums() async {
    print('EXPORT ALBUMS START');
    final box = await Hive.openBox('LibraryAlbums');
    print('EXPORT ALBUMS COUNT => ${box.length}');

    await writeJson('albums.json', {
      'version': 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': box.values.toList(),
    });

    await box.close();
    print('EXPORT ALBUMS END');
  }

  Future<void> importAlbums() async {
    print('IMPORT ALBUMS START');
    final data = await readJson('albums.json');
    if (data == null) {
      print('IMPORT ALBUMS SKIP');
      return;
    }

    final box = await Hive.openBox('LibraryAlbums');
    await box.clear();

    final items = (data['items'] as List?) ?? [];
    for (final item in items) {
      if (item is Map) {
        final itemMap = Map<String, dynamic>.from(item);
        final album = Album.fromJson(itemMap);
        if (album.browseId.isNotEmpty) {
          await box.put(album.browseId, itemMap);
        }
      }
    }

    await box.close();
    print('IMPORT ALBUMS END');
  }

  Future<void> exportArtists() async {
    print('EXPORT ARTISTS START');
    final box = await Hive.openBox('LibraryArtists');
    print('EXPORT ARTISTS COUNT => ${box.length}');

    await writeJson('artists.json', {
      'version': 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': box.values.toList(),
    });

    await box.close();
    print('EXPORT ARTISTS END');
  }

  Future<void> importArtists() async {
    print('IMPORT ARTISTS START');
    final data = await readJson('artists.json');
    if (data == null) {
      print('IMPORT ARTISTS SKIP');
      return;
    }

    final box = await Hive.openBox('LibraryArtists');
    await box.clear();

    final items = (data['items'] as List?) ?? [];
    for (final item in items) {
      if (item is Map) {
        final itemMap = Map<String, dynamic>.from(item);
        final artist = Artist.fromJson(itemMap);
        if (artist.browseId.isNotEmpty) {
          await box.put(artist.browseId, itemMap);
        }
      }
    }

    await box.close();
    print('IMPORT ARTISTS END');
  }

  Future<void> exportPlaylists() async {
    print('EXPORT PLAYLISTS START');
    final box = await Hive.openBox('LibraryPlaylists');
    print('EXPORT PLAYLISTS BOX COUNT => ${box.length}');

    final playlists = box.values
        .map<Playlist?>(
          (item) => Playlist.fromJson(Map<dynamic, dynamic>.from(item)),
        )
        .whereType<Playlist>()
        .where((p) =>
            !p.isPipedPlaylist &&
            !p.isCloudPlaylist &&
            !p.deleted &&
            p.playlistId.startsWith('LIB'))
        .toList();

    print('EXPORT PLAYLISTS FILTERED COUNT => ${playlists.length}');

    final payload = <Map<String, dynamic>>[];

    for (final playlist in playlists) {
      if (_isReservedPlaylist(playlist.playlistId)) {
        print('EXPORT PLAYLISTS SKIP RESERVED => ${playlist.playlistId}');
        continue;
      }

      print(
          'EXPORT PLAYLISTS PROCESS => ${playlist.playlistId} | ${playlist.title} | deleted=${playlist.deleted} | updatedAt=${playlist.updatedAt}');

      final alreadyOpen = Hive.isBoxOpen(playlist.playlistId);
      final songsBox = alreadyOpen
          ? Hive.box(playlist.playlistId)
          : await Hive.openBox(playlist.playlistId);

      print('EXPORT PLAYLIST SONG COUNT => ${songsBox.length}');

      payload.add({
        'playlist': playlist.toJson(),
        'songs': songsBox.values.toList(),
      });

      if (!alreadyOpen) {
        await songsBox.close();
      }
    }

    await writeJson('playlists.json', {
      'version': 2,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': payload,
    });

    await box.close();
    print('EXPORT PLAYLISTS END');
  }

  Future<void> importPlaylists() async {
    print('IMPORT PLAYLISTS START');
    final data = await readJson('playlists.json');
    if (data == null) {
      print('IMPORT PLAYLISTS SKIP');
      return;
    }

    final box = await Hive.openBox('LibraryPlaylists');
    final items = (data['items'] as List?) ?? [];
    print('IMPORT PLAYLISTS COUNT => ${items.length}');

    for (final raw in items) {
      if (raw is! Map) continue;

      final row = Map<String, dynamic>.from(raw);

      if (row['playlist'] is! Map) continue;
      final playlistJson = Map<String, dynamic>.from(row['playlist']);

      final incomingPlaylist = Playlist.fromJson(playlistJson);

      if (_isReservedPlaylist(incomingPlaylist.playlistId) ||
          incomingPlaylist.isPipedPlaylist) {
        print('IMPORT PLAYLISTS SKIP => ${incomingPlaylist.playlistId}');
        continue;
      }

      if (!incomingPlaylist.playlistId.startsWith('LIB')) {
        print(
            'IMPORT PLAYLISTS SKIP NON-LOCAL => ${incomingPlaylist.playlistId}');
        continue;
      }

      Playlist? localPlaylist;
      final localRaw = box.get(incomingPlaylist.playlistId);
      if (localRaw != null && localRaw is Map) {
        localPlaylist = Playlist.fromJson(Map<String, dynamic>.from(localRaw));
      }

      final incomingUpdatedAt = incomingPlaylist.updatedAt;
      final localUpdatedAt = localPlaylist?.updatedAt ?? 0;

      if (localPlaylist != null) {
        print(
          'IMPORT PLAYLIST COMPARE => ${incomingPlaylist.playlistId} | local=$localUpdatedAt | incoming=$incomingUpdatedAt',
        );
      }

      final shouldImport =
          localPlaylist == null || incomingUpdatedAt > localUpdatedAt;

      if (!shouldImport) {
        print('IMPORT PLAYLISTS KEEP LOCAL => ${incomingPlaylist.playlistId}');
        continue;
      }

      await box.put(incomingPlaylist.playlistId, incomingPlaylist.toJson());

      final alreadyOpen = Hive.isBoxOpen(incomingPlaylist.playlistId);
      final songsBox = alreadyOpen
          ? Hive.box(incomingPlaylist.playlistId)
          : await Hive.openBox(incomingPlaylist.playlistId);

      await songsBox.clear();

      final songs = (row['songs'] as List?) ?? [];
      for (int i = 0; i < songs.length; i++) {
        final song = songs[i];
        if (song is Map) {
          await songsBox.put(i, Map<String, dynamic>.from(song));
        }
      }

      if (!alreadyOpen) {
        await songsBox.close();
      }

      print(
        'IMPORT PLAYLIST APPLIED => ${incomingPlaylist.playlistId} | deleted=${incomingPlaylist.deleted} | updatedAt=${incomingPlaylist.updatedAt}',
      );
    }

    await box.close();
    print('IMPORT PLAYLISTS END');
  }

  Future<void> importSharedSongs() async {
    print('IMPORT SHARED SONGS START');

    final songs = await sharedSongsService.loadAvailableSharedSongs();
    final box = await Hive.openBox('SharedSongs');
    await box.clear();

    for (final song in songs) {
      final relativePath = 'songs/${song.filename}';
      final title = p.basenameWithoutExtension(song.originalFilename);

      final mediaItem = MediaItem(
        id: 'shared_${song.id}',
        title: title,
        artist: 'Shared Library',
        extras: {
          'relativePath': relativePath,
          'sharedSongId': song.id,
          'isSharedSong': true,
          'date': song.updatedAt.millisecondsSinceEpoch,
        },
        playable: true,
      );

      await box.put(mediaItem.id, MediaItemBuilder.toJson(mediaItem));
    }

    await box.close();
    print('IMPORT SHARED SONGS END => ${songs.length}');
  }

  Future<void> purgeDeletedPlaylists() async {
    print('PURGE DELETED PLAYLISTS START');

    final box = await Hive.openBox('LibraryPlaylists');
    final keysToDelete = <dynamic>[];

    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! Map) continue;

      final playlist = Playlist.fromJson(Map<dynamic, dynamic>.from(raw));

      if (!playlist.deleted) continue;

      print(
          'PURGE PLAYLIST MARKED DELETED => ${playlist.playlistId} | ${playlist.title}');

      if (await Hive.boxExists(playlist.playlistId)) {
        try {
          if (Hive.isBoxOpen(playlist.playlistId)) {
            final songsBox = Hive.box(playlist.playlistId);
            await songsBox.clear();
            await songsBox.close();
          } else {
            final songsBox = await Hive.openBox(playlist.playlistId);
            await songsBox.clear();
            await songsBox.close();
          }

          await Hive.deleteBoxFromDisk(playlist.playlistId);
          print('PURGE PLAYLIST BOX => ${playlist.playlistId}');
        } catch (e) {
          print('PURGE PLAYLIST BOX ERROR => ${playlist.playlistId} => $e');
        }
      }

      keysToDelete.add(key);
    }

    for (final key in keysToDelete) {
      final raw = box.get(key);
      if (raw is Map) {
        final playlist = Playlist.fromJson(Map<dynamic, dynamic>.from(raw));
        print('PURGE PLAYLIST ENTRY => ${playlist.playlistId}');
      }
      await box.delete(key);
    }

    await box.close();
    print('PURGE DELETED PLAYLISTS END => removed ${keysToDelete.length}');
  }

  bool _isReservedPlaylist(String playlistId) {
    return playlistId == 'LIBRP' ||
        playlistId == 'LIBFAV' ||
        playlistId == 'SongsCache' ||
        playlistId == 'SongDownloads';
  }

  Future<void> importAll() async {
    print('IMPORT ALL START');
    await importFavorites();
    await importAlbums();
    await importArtists();
    await importPlaylists();
    await importSharedSongs();
    print('IMPORT ALL END');
  }

  Future<void> exportAll() async {
    print('EXPORT ALL START');
    await exportFavorites();
    await exportAlbums();
    await exportArtists();
    await exportPlaylists();
    print('EXPORT ALL END');
  }

  @override
  void onClose() {
    stopAutoSync();
    super.onClose();
  }
}