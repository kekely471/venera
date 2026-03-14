// WebDAV 漫画图片提供器
// @author: kirk

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

/// WebDAV 漫画图片提供器
///
/// 用于加载 WebDAV 服务器上的漫画图片，支持本地缓存
class WebDavComicImageProvider
    extends BaseImageProvider<WebDavComicImageProvider> {
  final String remotePath; // 相对于 basePath 的路径

  static final Uint8List _transparentImage = base64Decode(
    // 1x1 透明 PNG，用于兜底不存在的封面图，避免重复报错与重试。
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+M6kAAAAASUVORK5CYII=',
  );

  const WebDavComicImageProvider(this.remotePath);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    // 1. 检查缓存
    var cacheFile = _getCacheFile(remotePath);
    if (await cacheFile.exists()) {
      Log.info('WebDavComicImageProvider', 'Loading from cache: $remotePath');
      return await cacheFile.readAsBytes();
    }

    checkStop();

    // 2. 从 WebDAV 下载
    Log.info(
      'WebDavComicImageProvider',
      'Downloading from WebDAV: $remotePath',
    );
    var manager = WebDavComicManager();
    Uint8List bytes;
    try {
      bytes = await manager.readFile(remotePath);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode ?? _extractStatusCode(e);
      if (_shouldUsePlaceholder(statusCode)) {
        Log.warning(
          'WebDavComicImageProvider',
          'Remote cover unavailable, fallback to placeholder: $remotePath',
        );
        bytes = _transparentImage;
      } else {
        rethrow;
      }
    } catch (e) {
      if (_isCoverImagePath() &&
          RegExp(
            r'Invalid Status Code:?\s*(401|403|404)\b',
          ).hasMatch(e.toString())) {
        Log.warning(
          'WebDavComicImageProvider',
          'Remote cover unavailable, fallback to placeholder: $remotePath',
        );
        bytes = _transparentImage;
      } else {
        rethrow;
      }
    }

    checkStop();

    // 3. 写入缓存
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes);
      Log.info('WebDavComicImageProvider', 'Cached: $remotePath');
    } catch (e, s) {
      Log.error('WebDavComicImageProvider', 'Failed to cache image: $e', s);
      // 继续返回数据，即使缓存失败
    }

    return bytes;
  }

  @override
  String get key => "webdav://$remotePath";

  @override
  bool get enableResize => true;

  @override
  Future<WebDavComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  /// 获取缓存文件路径
  File _getCacheFile(String path) {
    var cachePath = App.cachePath;
    // 规范化路径
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    return File('$cachePath/webdav_comics/$path');
  }

  bool _isCoverImagePath() {
    var name = remotePath.split('/').last.toLowerCase();
    return name.startsWith('cover');
  }

  bool _shouldUsePlaceholder(int? statusCode) {
    if (!_isCoverImagePath()) return false;
    return statusCode == 401 || statusCode == 403 || statusCode == 404;
  }

  int? _extractStatusCode(Object error) {
    var match = RegExp(
      r'Invalid Status Code:?\s*(\d{3})',
    ).firstMatch(error.toString());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// 预下载图片到缓存（不解码），供阅读器预加载使用
  static Future<void> preDownload(String remotePath) async {
    var cacheFile = File(
      '${App.cachePath}/webdav_comics/${remotePath.startsWith('/') ? remotePath.substring(1) : remotePath}',
    );
    if (await cacheFile.exists()) return;

    try {
      var manager = WebDavComicManager();
      var bytes = await manager.readFile(remotePath);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes);
      Log.info('WebDavComicImageProvider', 'Pre-downloaded: $remotePath');
    } catch (e) {
      Log.warning('WebDavComicImageProvider', 'Pre-download failed: $remotePath $e');
    }
  }
}
