class SongIndexEntry {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? fileName;
  final String? relativePath;
  final String? sourceUrl;
  final String? localHash;
  final String? downloadedAt;

  const SongIndexEntry({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.fileName,
    this.relativePath,
    this.sourceUrl,
    this.localHash,
    this.downloadedAt,
  });

  factory SongIndexEntry.fromJson(Map<String, dynamic> json) {
    return SongIndexEntry(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      artist: (json['artist'] ?? '').toString(),
      album: json['album']?.toString(),
      durationMs: json['durationMs'] is int
          ? json['durationMs'] as int
          : int.tryParse('${json['durationMs'] ?? ''}'),
      fileName: json['fileName']?.toString(),
      relativePath: json['relativePath']?.toString(),
      sourceUrl: json['sourceUrl']?.toString(),
      localHash: json['localHash']?.toString(),
      downloadedAt: json['downloadedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': durationMs,
      'fileName': fileName,
      'relativePath': relativePath,
      'sourceUrl': sourceUrl,
      'localHash': localHash,
      'downloadedAt': downloadedAt,
    };
  }

  SongIndexEntry copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? fileName,
    String? relativePath,
    String? sourceUrl,
    String? localHash,
    String? downloadedAt,
  }) {
    return SongIndexEntry(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      fileName: fileName ?? this.fileName,
      relativePath: relativePath ?? this.relativePath,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      localHash: localHash ?? this.localHash,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }

  bool get hasMinimumData {
    return id.trim().isNotEmpty &&
        title.trim().isNotEmpty &&
        artist.trim().isNotEmpty &&
        ((relativePath?.trim().isNotEmpty ?? false) ||
            (fileName?.trim().isNotEmpty ?? false));
  }
}