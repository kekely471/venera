// WebDAV ZIP/CBZ 流式图片提供器
// @author: kirk

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/webdav_archive_service.dart';

class WebDavArchiveStreamImageProvider
    extends BaseImageProvider<WebDavArchiveStreamImageProvider> {
  final String metaKey;
  final int imageIndex;

  const WebDavArchiveStreamImageProvider(this.metaKey, this.imageIndex);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    checkStop();
    final bytes = await WebDavArchiveService().readStreamingImage(
      metaKey: metaKey,
      imageIndex: imageIndex,
    );
    checkStop();

    chunkEvents.add(
      ImageChunkEvent(
        cumulativeBytesLoaded: bytes.length,
        expectedTotalBytes: bytes.length,
      ),
    );
    return bytes;
  }

  @override
  String get key => 'archive-stream://$metaKey/$imageIndex';

  @override
  bool get enableResize => true;

  @override
  Future<WebDavArchiveStreamImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }
}
