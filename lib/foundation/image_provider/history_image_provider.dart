import 'dart:async' show Future;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/webdav_archive_service.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/foundation/webdav_mobi_service.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  static final Uint8List _transparentImage = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+M6kAAAAASUVORK5CYII=',
  );

  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        if (localComic.comicType == ComicType.webdav) {
          var mobiDir = WebDavMobiService.decodeDirectory(localComic.directory);
          if (mobiDir != null) {
            return File(FilePath.join(mobiDir, localComic.cover)).readAsBytes();
          }
          var archiveStreamDir = WebDavArchiveService.decodeStreamDirectory(
            localComic.directory,
          );
          if (archiveStreamDir != null) {
            return File(
              FilePath.join(archiveStreamDir, localComic.cover),
            ).readAsBytes();
          }
          var archiveDir = WebDavArchiveService.decodeDirectory(
            localComic.directory,
          );
          if (archiveDir != null) {
            return File(
              FilePath.join(archiveDir, localComic.cover),
            ).readAsBytes();
          }
          var coverRemotePath = localComic.hasChapters
              ? "${localComic.directory}/${localComic.chapters!.ids.first}/${localComic.cover}"
              : "${localComic.directory}/${localComic.cover}";
          try {
            return await WebDavComicManager().readFile(coverRemotePath);
          } on DioException catch (e) {
            final statusCode =
                e.response?.statusCode ?? _extractStatusCode(e.toString());
            if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
              return _transparentImage;
            }
            rethrow;
          } catch (e) {
            if (RegExp(
              r'Invalid Status Code:?\s*(401|403|404)\b',
            ).hasMatch(e.toString())) {
              return _transparentImage;
            }
            rethrow;
          }
        }
        return localComic.coverFile.readAsBytes();
      }
      var comicSource =
          history.type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      HistoryManager().addHistory(history);
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";

  static int? _extractStatusCode(String text) {
    final match = RegExp(r'Invalid Status Code:?\s*(\d{3})').firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}
