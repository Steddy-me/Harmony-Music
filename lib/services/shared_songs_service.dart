import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:harmonymusic/models/nextcloud_config.dart';
import 'package:harmonymusic/services/nextcloud_webdav_service.dart';
import 'package:path/path.dart' as p;

class SharedSong {
  final String id;
  final String filename;
  final String originalFilename;
  final String checksum;
  final int size;
  final String extension;
  final DateTime updatedAt;

  final String? title;
  final String? artist;
  final String? album;
  final String? thumbnailUrl;
  final String? videoId;

  SharedSong({
    required this.id,
    required this.filename,
    required this.originalFilename,
    required this.checksum,
    required this.size,
    required this.extension,
    required this.updatedAt,
    this.title,
    this.artist,
    this.album,
    this.thumbnailUrl,
    this.videoId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'filename': filename,
        'originalFilename': originalFilename,
        'checksum': checksum,
        'size': size,
        'extension': extension,
        'updatedAt': updatedAt.toIso8601String(),
        'title': title,
        'artist': artist,
        'album': album,
        'thumbnailUrl': thumbnailUrl,
        'videoId': videoId,
      };

  factory SharedSong.fromJson(Map<String, dynamic> json) => SharedSong(
        id: json['id'],
        filename: json['filename'],
        originalFilename: json['originalFilename'],
        checksum: json['checksum'],
        size: json['size'],
        extension: json['extension'],
        updatedAt: DateTime.parse(json['updatedAt']),
        title: json['title'],
        artist: json['artist'],
        album: json['album'],
        thumbnailUrl: json['thumbnailUrl'],
        videoId: json['videoId'],
      );
}

class SharedSongsService {
  final Directory sharedDir;
  final NextcloudConfig? nextcloudConfig;
  final NextcloudWebDavService _webDavService;

  SharedSongsService(
    this.sharedDir, {
    this.nextcloudConfig,
    NextcloudWebDavService? webDavService,
  }) : _webDavService = webDavService ?? NextcloudWebDavService();

  Directory get songsDir => Directory(p.join(sharedDir.path, 'songs'));
  File get songsIndexFile => File(p.join(sharedDir.path, 'songs_index.json'));

  bool get _useWebDavOnAndroid =>
      Platform.isAndroid && nextcloudConfig != null && nextcloudConfig!.isValid;

  Future<void> init() async {
    if (!_useWebDavOnAndroid) {
      if (!await songsDir.exists()) {
        await songsDir.create(recursive: true);
      }

      if (!await songsIndexFile.exists()) {
        await songsIndexFile.writeAsString(
          jsonEncode({
            'updatedAt': DateTime.now().toIso8601String(),
            'songs': [],
          }),
        );
      }
    }
  }

  Future<List<SharedSong>> loadSharedSongs() async {
    await init();

    if (_useWebDavOnAndroid) {
      final content = await _webDavService.readTextFile(
        nextcloudConfig!,
        relativeRemotePath: 'songs_index.json',
      );

      if (content == null || content.trim().isEmpty) {
        return [];
      }

      final jsonData = jsonDecode(content) as Map<String, dynamic>;
      final songsRaw = (jsonData['songs'] as List?) ?? [];

      return songsRaw
          .map((e) => SharedSong.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    final content = await songsIndexFile.readAsString();
    if (content.trim().isEmpty) {
      return [];
    }

    final jsonData = jsonDecode(content) as Map<String, dynamic>;
    final songsRaw = (jsonData['songs'] as List?) ?? [];

    return songsRaw
        .map((e) => SharedSong.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> saveSharedSongs(List<SharedSong> songs) async {
    await init();

    final data = {
      'updatedAt': DateTime.now().toIso8601String(),
      'songs': songs.map((e) => e.toJson()).toList(),
    };

    final content = jsonEncode(data);

    if (_useWebDavOnAndroid) {
      await _webDavService.writeTextFile(
        nextcloudConfig!,
        relativeRemotePath: 'songs_index.json',
        content: content,
        contentType: 'application/json; charset=utf-8',
      );
      return;
    }

    await songsIndexFile.writeAsString(content);
  }

  Future<String> calculateFileChecksum(File file) async {
    final bytes = await file.readAsBytes();
    return sha1.convert(bytes).toString();
  }

  SharedSong? findSongByChecksum(List<SharedSong> songs, String checksum) {
    try {
      return songs.firstWhere((s) => s.checksum == checksum);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _remoteSongExists(String filename) async {
    if (!_useWebDavOnAndroid) return false;

    return _webDavService.remoteFileExists(
      nextcloudConfig!,
      relativeRemotePath: 'songs/$filename',
    );
  }

  Future<void> _uploadSongToRemote(File sourceFile, String filename) async {
    await _webDavService.uploadFile(
      nextcloudConfig!,
      sourceFile: sourceFile,
      relativeRemotePath: 'songs/$filename',
      contentType: 'audio/mp4',
    );
  }

  Future<SharedSong> importSong(
    File sourceFile, {
    String? title,
    String? artist,
    String? album,
    String? thumbnailUrl,
    String? videoId,
  }) async {
    await init();

    if (!await sourceFile.exists()) {
      throw Exception('Source file missing: ${sourceFile.path}');
    }

    final checksum = await calculateFileChecksum(sourceFile);
    final extension = p.extension(sourceFile.path).toLowerCase();
    final filename = '$checksum$extension';
    final destination = File(p.join(songsDir.path, filename));

    final songsBefore = await loadSharedSongs();
    final existingBefore = findSongByChecksum(songsBefore, checksum);

    if (existingBefore != null) {
      if (_useWebDavOnAndroid) {
        final remoteExists = await _remoteSongExists(existingBefore.filename);
        if (remoteExists) {
          return existingBefore;
        }
      } else {
        final existingFile = File(p.join(songsDir.path, existingBefore.filename));
        if (await existingFile.exists()) {
          return existingBefore;
        }
      }
    }

    if (_useWebDavOnAndroid) {
      await _uploadSongToRemote(sourceFile, filename);
    } else {
      if (!await destination.exists()) {
        await sourceFile.copy(destination.path);
      }

      if (!await destination.exists()) {
        throw Exception('Shared song file was not created: ${destination.path}');
      }

      final sourceSize = await sourceFile.length();
      final destSize = await destination.length();

      if (destSize <= 0 || destSize != sourceSize) {
        throw Exception(
          'Shared song copy invalid. source=$sourceSize dest=$destSize path=${destination.path}',
        );
      }
    }

    final songsAfter = await loadSharedSongs();
    final existingAfter = findSongByChecksum(songsAfter, checksum);

    if (existingAfter != null) {
      if (_useWebDavOnAndroid) {
        final remoteExists = await _remoteSongExists(existingAfter.filename);
        if (remoteExists) {
          return existingAfter;
        }
      } else {
        final existingFile = File(p.join(songsDir.path, existingAfter.filename));
        if (await existingFile.exists()) {
          return existingAfter;
        }
      }

      songsAfter.removeWhere((s) => s.checksum == checksum);
    }

    final int size;
    if (_useWebDavOnAndroid) {
      size = await sourceFile.length();
    } else {
      final stat = await destination.stat();
      size = stat.size;
    }

    final song = SharedSong(
      id: checksum,
      filename: filename,
      originalFilename: p.basename(sourceFile.path),
      checksum: checksum,
      size: size,
      extension: extension,
      updatedAt: DateTime.now(),
      title: title,
      artist: artist,
      album: album,
      thumbnailUrl: thumbnailUrl,
      videoId: videoId,
    );

    songsAfter.removeWhere((s) => s.checksum == checksum);
    songsAfter.add(song);
    await saveSharedSongs(songsAfter);

    return song;
  }

  Future<String?> getSharedPathByChecksum(String checksum) async {
    final songs = await loadSharedSongs();

    try {
      final song = songs.firstWhere((s) => s.checksum == checksum);
      return p.join(songsDir.path, song.filename);
    } catch (_) {
      return null;
    }
  }

  Future<String?> getSharedPathById(String id) async {
    final songs = await loadSharedSongs();

    try {
      final song = songs.firstWhere((s) => s.id == id);
      return p.join(songsDir.path, song.filename);
    } catch (_) {
      return null;
    }
  }

  Future<List<SharedSong>> loadAvailableSharedSongs() async {
    final songs = await loadSharedSongs();
    final available = <SharedSong>[];

    for (final song in songs) {
      if (_useWebDavOnAndroid) {
        final exists = await _remoteSongExists(song.filename);
        if (exists) {
          available.add(song);
        }
      } else {
        final file = File(p.join(songsDir.path, song.filename));
        if (await file.exists()) {
          available.add(song);
        }
      }
    }

    return available;
  }
}