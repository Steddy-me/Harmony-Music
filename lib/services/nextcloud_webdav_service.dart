import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/nextcloud_config.dart';

class NextcloudWebDavService {
  final Dio _dio;

  NextcloudWebDavService({Dio? dio}) : _dio = dio ?? Dio();

  String _basicAuth(String username, String password) {
    final raw = '$username:$password';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  Map<String, String> _headers(NextcloudConfig config) {
    return {
      'Authorization': _basicAuth(config.username, config.appPassword),
    };
  }

  String _encodePath(String value) {
    return value.split('/').map(Uri.encodeComponent).join('/');
  }

  Uri _buildFileUri(
    NextcloudConfig config,
    String relativeRemotePath,
  ) {
    final safeBase = config.normalizedBaseUrl;
    final safeRemoteBase = _encodePath(config.normalizedRemoteBasePath);
    final safeRelative = _encodePath(relativeRemotePath);

    return Uri.parse(
      '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/'
      '$safeRemoteBase/$safeRelative',
    );
  }

  Uri _buildFolderUri(
    NextcloudConfig config,
    String relativeFolderPath,
  ) {
    final safeBase = config.normalizedBaseUrl;
    final safeRemoteBase = _encodePath(config.normalizedRemoteBasePath);

    if (relativeFolderPath.trim().isEmpty) {
      return Uri.parse(
        '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/$safeRemoteBase',
      );
    }

    final safeFolder = _encodePath(relativeFolderPath);

    return Uri.parse(
      '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/'
      '$safeRemoteBase/$safeFolder',
    );
  }

  Future<void> ensureFolderExists(
    NextcloudConfig config,
    String relativeFolderPath,
  ) async {
    final clean = relativeFolderPath.trim();
    if (clean.isEmpty || clean == '.') return;

    final parts = clean.split('/');
    var current = '';

    for (final part in parts) {
      current = current.isEmpty ? part : '$current/$part';

      final response = await _dio.requestUri(
        _buildFolderUri(config, current),
        data: '',
        options: Options(
          method: 'MKCOL',
          headers: _headers(config),
          validateStatus: (status) =>
              status != null &&
              (status == 201 || status == 405 || status == 301 || status == 302),
        ),
      );

      if (response.statusCode == null ||
          ![201, 405, 301, 302].contains(response.statusCode)) {
        throw Exception(
          'Nextcloud folder creation failed for $current (${response.statusCode})',
        );
      }
    }
  }

  Future<bool> remoteFileExists(
    NextcloudConfig config, {
    required String relativeRemotePath,
  }) async {
    final response = await _dio.requestUri(
      _buildFileUri(config, relativeRemotePath),
      options: Options(
        method: 'HEAD',
        headers: _headers(config),
        validateStatus: (status) =>
            status != null && (status == 200 || status == 404),
      ),
    );

    return response.statusCode == 200;
  }

  Future<String?> readTextFile(
    NextcloudConfig config, {
    required String relativeRemotePath,
  }) async {
    final response = await _dio.getUri(
      _buildFileUri(config, relativeRemotePath),
      options: Options(
        headers: _headers(config),
        responseType: ResponseType.plain,
        validateStatus: (status) =>
            status != null && (status == 200 || status == 404),
      ),
    );

    if (response.statusCode == 404) return null;

    final data = response.data?.toString() ?? '';
    if (data.trim().isEmpty) return null;
    return data;
  }

  Future<void> writeTextFile(
    NextcloudConfig config, {
    required String relativeRemotePath,
    required String content,
    String contentType = 'text/plain; charset=utf-8',
  }) async {
    final parentDir = p.dirname(relativeRemotePath).replaceAll('\\', '/');
    if (parentDir.isNotEmpty && parentDir != '.') {
      await ensureFolderExists(config, parentDir);
    }

    final response = await _dio.putUri(
      _buildFileUri(config, relativeRemotePath),
      data: utf8.encode(content),
      options: Options(
        headers: {
          ..._headers(config),
          'Content-Type': contentType,
        },
        validateStatus: (status) =>
            status != null && (status == 201 || status == 204),
      ),
    );

    if (response.statusCode == null ||
        ![201, 204].contains(response.statusCode)) {
      throw Exception(
        'Nextcloud text write failed (${response.statusCode}) for $relativeRemotePath',
      );
    }
  }

  Future<void> uploadFile(
    NextcloudConfig config, {
    required File sourceFile,
    required String relativeRemotePath,
    String contentType = 'application/octet-stream',
  }) async {
    if (!await sourceFile.exists()) {
      throw Exception('Source file missing: ${sourceFile.path}');
    }

    final parentDir = p.dirname(relativeRemotePath).replaceAll('\\', '/');
    if (parentDir.isNotEmpty && parentDir != '.') {
      await ensureFolderExists(config, parentDir);
    }

    final uri = _buildFileUri(config, relativeRemotePath);
    final stream = sourceFile.openRead();
    final length = await sourceFile.length();

    final response = await _dio.putUri(
      uri,
      data: stream,
      options: Options(
        headers: {
          ..._headers(config),
          'Content-Length': length.toString(),
          'Content-Type': contentType,
        },
        validateStatus: (status) =>
            status != null && (status == 201 || status == 204),
      ),
    );

    if (response.statusCode == null ||
        ![201, 204].contains(response.statusCode)) {
      throw Exception(
        'Nextcloud upload failed (${response.statusCode}) for $relativeRemotePath',
      );
    }
  }
}