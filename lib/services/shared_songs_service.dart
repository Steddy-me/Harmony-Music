import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  SharedSongsService(this.sharedDir);

  Directory get songsDir => Directory(p.join(sharedDir.path, 'songs'));
  File get songsIndexFile => File(p.join(sharedDir.path, 'songs_index.json'));

  Future<void> init() async {
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

  Future<List<SharedSong>> loadSharedSongs() async {
    await init();

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

    await songsIndexFile.writeAsString(jsonEncode(data));
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

  Future<SharedSong> importSong(
    File sourceFile, {
    String? title,
    String? artist,
    String? album,
    String? thumbnailUrl,
    String? videoId,
  }) async {
    await init();

    final checksum = await calculateFileChecksum(sourceFile);
    final extension = p.extension(sourceFile.path).toLowerCase();
    final filename = '$checksum$extension';
    final destination = File(p.join(songsDir.path, filename));

    final songsBefore = await loadSharedSongs();
    final existingBefore = findSongByChecksum(songsBefore, checksum);
    if (existingBefore != null) {
      return existingBefore;
    }

    if (!await destination.exists()) {
      await sourceFile.copy(destination.path);
    }

    final songsAfter = await loadSharedSongs();
    final existingAfter = findSongByChecksum(songsAfter, checksum);
    if (existingAfter != null) {
      return existingAfter;
    }

    final stat = await destination.stat();

        final song = SharedSong(
          id: checksum,
          filename: filename,
          originalFilename: p.basename(sourceFile.path),
          checksum: checksum,
          size: stat.size,
          extension: extension,
          updatedAt: DateTime.now(),
          title: title,
          artist: artist,
          album: album,
          thumbnailUrl: thumbnailUrl,
          videoId: videoId,
        );

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
      final file = File(p.join(songsDir.path, song.filename));
      if (await file.exists()) {
        available.add(song);
      }
    }

    return available;
  }
}