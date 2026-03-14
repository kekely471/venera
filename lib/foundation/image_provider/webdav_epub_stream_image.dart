// WebDAV EPUB 流式图片提供器
// @author: luoyang

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/webdav_epub_service.dart';

class WebDavEpubStreamImageProvider
    extends BaseImageProvider<WebDavEpubStreamImageProvider> {
  final String metaKey;
  final int imageIndex;

  const WebDavEpubStreamImageProvider(this.metaKey, this.imageIndex);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    checkStop();
    final bytes = await WebDavEpubService().readStreamingImage(
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
  String get key => 'epub-stream://$metaKey/$imageIndex';

  @override
  bool get enableResize => true;

  @override
  Future<WebDavEpubStreamImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }
}
