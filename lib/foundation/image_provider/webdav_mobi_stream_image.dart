// WebDAV MOBI 流式图片提供器
// @author: kirk

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

/// 通过 Range 请求按需加载 MOBI 文件中单张图片的 ImageProvider
class WebDavMobiStreamImageProvider
    extends BaseImageProvider<WebDavMobiStreamImageProvider> {
  final String metaKey;
  final int imageIndex;

  const WebDavMobiStreamImageProvider(this.metaKey, this.imageIndex);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    final cacheDir = Directory(
      FilePath.join(App.cachePath, 'webdav_mobi_stream', metaKey),
    );

    // 1. 检查本地缓存
    final cachedFile = await _findCachedImage(cacheDir, imageIndex);
    if (cachedFile != null) {
      return await cachedFile.readAsBytes();
    }

    checkStop();

    // 2. 读取 meta.json 获取字节区间和 remotePath
    final metaFile = cacheDir.joinFile('meta.json');
    final metaContent = await metaFile.readAsString();
    final meta = jsonDecode(metaContent) as Map<String, dynamic>;
    final remotePath = meta['remotePath'] as String;
    final imageRecords = meta['imageRecords'] as List;

    if (imageIndex < 0 || imageIndex >= imageRecords.length) {
      throw Exception('Image index out of range: $imageIndex');
    }

    final record = imageRecords[imageIndex] as Map<String, dynamic>;
    final start = record['start'] as int;
    final end = record['end'] as int;
    final expectedSize = end - start + 1;

    // 3. Range 请求下载图片数据
    final manager = WebDavComicManager();
    final result = await manager.readFileRange(
      remotePath,
      start: start,
      end: end,
    );

    checkStop();

    if (result.bytes.isEmpty) {
      throw Exception('Empty image data from range request');
    }

    // 4. 验证图片 magic
    final ext = _detectImageMagic(result.bytes);
    if (ext == null) {
      throw Exception('Invalid image data at record $imageIndex');
    }

    chunkEvents.add(ImageChunkEvent(
      cumulativeBytesLoaded: result.bytes.length,
      expectedTotalBytes: expectedSize,
    ));

    // 5. 写入本地缓存
    try {
      final outFile = cacheDir.joinFile('$imageIndex.$ext');
      await outFile.writeAsBytes(result.bytes, flush: false);
    } catch (e) {
      Log.warning('MobiStreamImageProvider', 'Cache write failed: $e');
    }

    return result.bytes;
  }

  @override
  String get key => 'mobi-stream://$metaKey/$imageIndex';

  @override
  bool get enableResize => true;

  @override
  Future<WebDavMobiStreamImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }

  Future<File?> _findCachedImage(Directory dir, int index) async {
    if (!await dir.exists()) return null;
    for (final ext in const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp']) {
      final f = dir.joinFile('$index.$ext');
      if (await f.exists() && await f.length() > 0) {
        return f;
      }
    }
    return null;
  }

  String? _detectImageMagic(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'gif';
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return null;
  }
}
