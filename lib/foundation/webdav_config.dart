// WebDAV 配置与客户端工具
// @author: kirk

import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

class WebDavConnectionConfig {
  final String url;
  final String username;
  final String password;
  final String basePath;

  const WebDavConnectionConfig({
    required this.url,
    required this.username,
    required this.password,
    required this.basePath,
  });

  bool get isConfigured => url.trim().isNotEmpty;

  WebDavConnectionConfig normalized() {
    return WebDavConnectionConfig(
      url: url.trim(),
      username: username.trim(),
      password: password,
      basePath: WebDavPathUtils.normalize(basePath),
    );
  }

  Map<String, dynamic> toJson() {
    final normalizedConfig = normalized();
    return {
      'url': normalizedConfig.url,
      'username': normalizedConfig.username,
      'password': normalizedConfig.password,
      'basePath': normalizedConfig.basePath,
    };
  }

  static WebDavConnectionConfig? fromRaw(
    Object? raw, {
    String defaultBasePath = '/',
  }) {
    if (raw == null) {
      return null;
    }

    if (raw is List && raw.length == 3 && raw.whereType<String>().length == 3) {
      return WebDavConnectionConfig(
        url: raw[0].toString(),
        username: raw[1].toString(),
        password: raw[2].toString(),
        basePath: defaultBasePath,
      ).normalized();
    }

    if (raw is Map) {
      final url = raw['url']?.toString() ?? '';
      final username = raw['username']?.toString() ?? '';
      final password = raw['password']?.toString() ?? '';
      final basePath = raw['basePath']?.toString() ?? defaultBasePath;
      return WebDavConnectionConfig(
        url: url,
        username: username,
        password: password,
        basePath: basePath,
      ).normalized();
    }

    return null;
  }
}

class WebDavSettings {
  static const String syncKey = 'webdav';
  static const String comicsKey = 'webdavComics';
  static const String useSyncConfigKey = 'useSyncConfig';

  static WebDavConnectionConfig? readSyncConfig() {
    return WebDavConnectionConfig.fromRaw(appdata.settings[syncKey]);
  }

  static WebDavConnectionConfig? readComicsOwnConfig() {
    final raw = appdata.settings[comicsKey];
    if (raw is Map && raw[useSyncConfigKey] == true) {
      return null;
    }
    return WebDavConnectionConfig.fromRaw(raw);
  }

  static WebDavConnectionConfig? readComicsConfig() {
    if (comicsUsesSyncConfig()) {
      return readSyncConfig();
    }
    return readComicsOwnConfig();
  }

  static bool comicsUsesSyncConfig() {
    final raw = appdata.settings[comicsKey];
    return raw is Map && raw[useSyncConfigKey] == true;
  }

  static Future<void> saveSyncConfig(WebDavConnectionConfig? config) async {
    if (config == null || !config.isConfigured) {
      appdata.settings[syncKey] = [];
    } else {
      appdata.settings[syncKey] = config.toJson();
    }
    await appdata.saveData();
  }

  static Future<void> saveComicsConfig({
    WebDavConnectionConfig? config,
    required bool useSyncConfig,
  }) async {
    if (useSyncConfig) {
      appdata.settings[comicsKey] = {useSyncConfigKey: true};
    } else if (config == null || !config.isConfigured) {
      appdata.settings[comicsKey] = null;
    } else {
      appdata.settings[comicsKey] = config.toJson();
    }
    await appdata.saveData();
  }

  static bool migrateLegacySettings() {
    var changed = false;

    final syncConfig = readSyncConfig();
    final syncRaw = appdata.settings[syncKey];
    if (syncRaw is List && syncConfig != null && syncConfig.isConfigured) {
      appdata.settings[syncKey] = syncConfig.toJson();
      changed = true;
    } else if (syncRaw is Map && !syncRaw.containsKey('basePath')) {
      appdata.settings[syncKey] = syncConfig?.toJson() ?? {};
      changed = true;
    }

    final comicsRaw = appdata.settings[comicsKey];
    if (comicsRaw is List) {
      final comicsConfig = readComicsOwnConfig();
      if (comicsConfig != null && comicsConfig.isConfigured) {
        appdata.settings[comicsKey] = comicsConfig.toJson();
        changed = true;
      }
    } else if (comicsRaw is Map &&
        comicsRaw[useSyncConfigKey] != true &&
        !comicsRaw.containsKey('basePath')) {
      final comicsConfig = readComicsOwnConfig();
      appdata.settings[comicsKey] = comicsConfig?.toJson() ?? comicsRaw;
      changed = true;
    }

    return changed;
  }
}

class WebDavClientFactory {
  static webdav.Client create(WebDavConnectionConfig config) {
    final normalizedConfig = config.normalized();
    return webdav.newClient(
      normalizedConfig.url,
      user: normalizedConfig.username,
      password: normalizedConfig.password,
      adapter: RHttpAdapter(),
    );
  }
}

class WebDavPathUtils {
  static String normalize(String path) {
    var normalized = path.trim();
    if (normalized.isEmpty) {
      normalized = '/';
    }
    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }
    while (normalized.contains('//')) {
      normalized = normalized.replaceAll('//', '/');
    }
    return normalized;
  }

  static String scope(WebDavConnectionConfig config, String path) {
    return normalize('${config.normalized().basePath}$path');
  }

  static String joinToBase(WebDavConnectionConfig config, String name) {
    return normalize('${config.normalized().basePath}/$name');
  }
}
