// ignore_for_file: file_names

import 'package:audio_service/audio_service.dart';
import '../models/thumbnail.dart';

class MediaItemBuilder {
  static MediaItem fromJson(dynamic json, {String? url}) {
    final nestedExtras = json['extras'] is Map
        ? Map<String, dynamic>.from(json['extras'])
        : <String, dynamic>{};

    String? artistName;
    final artistsRaw = json['artists'] ?? nestedExtras['artists'];
    if (artistsRaw != null) {
      artistName =
          artistsRaw.map((e) => e['name']).toList().join(', ').toString();
    }

    Map? album;
    final albumRaw = json['album'] ?? nestedExtras['album'];
    if (albumRaw != null) {
      if (albumRaw['id'] != null) {
        album = albumRaw;
      }
    }

    final thumbnailsRaw = json["thumbnails"] ?? [
      {'url': ''}
    ];

    return MediaItem(
      id: json["videoId"],
      title: json["title"],
      duration: json['duration'] != null
          ? Duration(seconds: json['duration'])
          : toDuration(json['length'] ?? nestedExtras['length']),
      album: album != null ? album['name'] : null,
      artist: artistName,
      artUri: Uri.parse(Thumbnail(thumbnailsRaw[0]['url']).high),
      extras: {
        'url': json['url'] ?? nestedExtras['url'] ?? url,
        'sharedPath': json['sharedPath'] ?? nestedExtras['sharedPath'],
        'sharedSongId': json['sharedSongId'] ?? nestedExtras['sharedSongId'],
        'isSharedSong':
            (json['isSharedSong'] ?? nestedExtras['isSharedSong']) == true,
        'length': json['length'] ?? nestedExtras['length'],
        'album': album,
        'artists': artistsRaw,
        'date': json['date'] ?? nestedExtras['date'],
        'trackDetails': json['trackDetails'] ?? nestedExtras['trackDetails'],
        'year': json['year'] ?? nestedExtras['year'],
      },
    );
  }

  static Duration? toDuration(String? time) {
    if (time == null) {
      return null;
    }

    int sec = 0;
    final splitted = time.split(":");
    if (splitted.length == 3) {
      sec += int.parse(splitted[0]) * 3600 +
          int.parse(splitted[1]) * 60 +
          int.parse(splitted[2]);
    } else if (splitted.length == 2) {
      sec += int.parse(splitted[0]) * 60 + int.parse(splitted[1]);
    } else if (splitted.length == 1) {
      sec += int.parse(splitted[0]);
    }
    return Duration(seconds: sec);
  }

  static Map<String, dynamic> toJson(MediaItem mediaItem) {
    final extras = Map<String, dynamic>.from(mediaItem.extras ?? {});

    return {
      "videoId": mediaItem.id,
      "title": mediaItem.title,
      'album': extras['album'],
      'artists': extras['artists'],
      'length': extras['length'],
      'duration': mediaItem.duration?.inSeconds,
      'date': extras['date'],
      'thumbnails': [
        {'url': mediaItem.artUri.toString()}
      ],
      'url': extras['url'],
      'sharedPath': extras['sharedPath'],
      'sharedSongId': extras['sharedSongId'],
      'isSharedSong': extras['isSharedSong'] == true,
      'trackDetails': extras['trackDetails'],
      'year': extras['year'],
      'extras': {
        'url': extras['url'],
        'sharedPath': extras['sharedPath'],
        'sharedSongId': extras['sharedSongId'],
        'isSharedSong': extras['isSharedSong'] == true,
        'length': extras['length'],
        'album': extras['album'],
        'artists': extras['artists'],
        'date': extras['date'],
        'trackDetails': extras['trackDetails'],
        'year': extras['year'],
      }
    };
  }
}