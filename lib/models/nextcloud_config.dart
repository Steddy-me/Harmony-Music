class NextcloudConfig {
  final String baseUrl;
  final String username;
  final String appPassword;
  final String remoteBasePath;

  const NextcloudConfig({
    required this.baseUrl,
    required this.username,
    required this.appPassword,
    required this.remoteBasePath,
  });

  bool get isValid =>
      baseUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      appPassword.trim().isNotEmpty &&
      remoteBasePath.trim().isNotEmpty;

  String get normalizedBaseUrl {
    final value = baseUrl.trim();
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  String get normalizedRemoteBasePath {
    var value = remoteBasePath.trim();
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static NextcloudConfig? fromPrefs(dynamic box) {
    final enabled = box.get('nextcloudEnabled') ?? false;
    if (enabled != true) return null;

    final config = NextcloudConfig(
      baseUrl: (box.get('nextcloudBaseUrl') ?? '').toString(),
      username: (box.get('nextcloudUsername') ?? '').toString(),
      appPassword: (box.get('nextcloudAppPassword') ?? '').toString(),
      remoteBasePath: (box.get('nextcloudRemoteBasePath') ?? '').toString(),
    );

    return config.isValid ? config : null;
  }
}