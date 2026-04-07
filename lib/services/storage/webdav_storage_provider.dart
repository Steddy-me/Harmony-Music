import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/nextcloud_config.dart';
import 'shared_storage_provider.dart';


class WebDavStorageProvider extends SharedStorageProvider {
  final NextcloudConfig config;
  final Dio _dio;

  WebDavStorageProvider(
    this.config, {
    Dio? dio,
  }) : _dio = dio ?? Dio();

  String _basicAuth() {
    final raw = '${config.username}:${config.appPassword}';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  Map<String, String> _headers() {
    return {
      'Authorization': _basicAuth(),
    };
  }

  String _encodePath(String value) {
    return value.split('/').map(Uri.encodeComponent).join('/');
  }

  Uri _buildUri(String relativePath) {
    final safeBase = config.normalizedBaseUrl;
    final safeRemoteBase = _encodePath(config.normalizedRemoteBasePath);
    final safeRelative = _encodePath(relativePath);

    return Uri.parse(
      '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/'
      '$safeRemoteBase/$safeRelative',
    );
  }

  Uri _buildFolderUri(String relativeFolderPath) {
    final safeBase = config.normalizedBaseUrl;
    final safeRemoteBase = _encodePath(config.normalizedRemoteBasePath);

    if (relativeFolderPath.trim().isEmpty) {
      return Uri.parse(
        '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/$safeRemoteBase',
      );
    }

    final safeFolder = _encodePath(relativeFolderPath);
    return Uri.parse(
      '$safeBase/remote.php/dav/files/${Uri.encodeComponent(config.username)}/$safeRemoteBase/$safeFolder',
    );
  }

  Future<void> ensureFolderExists(String relativeFolderPath) async {
    final clean = relativeFolderPath.trim();
    if (clean.isEmpty || clean == '.') return;

    final parts = clean.split('/');
    var current = '';

    for (final part in parts) {
      current = current.isEmpty ? part : '$current/$part';

      final response = await _dio.requestUri(
        _buildFolderUri(current),
        data: '',
        options: Options(
          method: 'MKCOL',
          headers: _headers(),
          validateStatus: (status) =>
              status != null &&
              (status == 201 || status == 405 || status == 301 || status == 302),
        ),
      );

      if (response.statusCode == null ||
          ![201, 405, 301, 302].contains(response.statusCode)) {
        throw Exception(
          'MKCOL failed for $current (${response.statusCode})',
        );
      }
    }
  }

  @override
  Future<String?> readFile(String name) async {
    final response = await _dio.getUri(
      _buildUri(name),
      options: Options(
        headers: _headers(),
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && (status == 200 || status == 404),
      ),
    );

    if (response.statusCode == 404) return null;

    final data = response.data?.toString() ?? '';
    if (data.trim().isEmpty) return null;
    return data;
  }

  @override
  Future<void> writeFile(String name, String content) async {
    final parentDir = p.dirname(name).replaceAll('\\', '/');
    if (parentDir.isNotEmpty && parentDir != '.') {
      await ensureFolderExists(parentDir);
    }

    final response = await _dio.putUri(
      _buildUri(name),
      data: utf8.encode(content),
      options: Options(
        headers: {
          ..._headers(),
          'Content-Type': 'application/json; charset=utf-8',
        },
        validateStatus: (status) =>
            status != null && (status == 201 || status == 204),
      ),
    );

    if (response.statusCode == null ||
        ![201, 204].contains(response.statusCode)) {
      throw Exception('WebDAV write failed for $name (${response.statusCode})');
    }
  }

  @override
  Future<bool> exists(String name) async {
    final response = await _dio.requestUri(
      _buildUri(name),
      options: Options(
        method: 'HEAD',
        headers: _headers(),
        validateStatus: (status) => status != null && (status == 200 || status == 404),
      ),
    );

    return response.statusCode == 200;
  }

  @override
  Future<DateTime?> lastModified(String name) async {
   final response = await _dio.requestUri(
     _buildUri(name),
     options: Options(
       method: 'HEAD',
       headers: _headers(),
       validateStatus: (status) => status != null && (status == 200 || status == 404),
     ),
   );

   if (response.statusCode == 404) return null;

   final header = response.headers.value('last-modified');
   if (header == null || header.trim().isEmpty) return null;

   try {
     return HttpDate.parse(header);
   } catch (_) {
     return null;
   }
 }
}