import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/io.dart';

class Waifu2xService {
  static const MethodChannel _channel = MethodChannel('venera/waifu2x');
  static bool? _isAvailable;

  static Future<Uint8List> maybeEnhance(
    Uint8List imageBytes, {
    required String imageKey,
    required String cid,
    required String eid,
    required int page,
  }) async {
    if ((!App.isAndroid && !App.isMacOS) ||
        appdata.settings['enableWaifu2xEnhancement'] != true) {
      return imageBytes;
    }
    if (imageBytes.isEmpty || imageBytes.length > 32 * 1024 * 1024) {
      return imageBytes;
    }

    final isAvailable = await _checkAvailability();
    if (!isAvailable) {
      return imageBytes;
    }

    final noiseLevel = (appdata.settings['waifu2xNoiseLevel'] as num).toInt();
    final scale = (appdata.settings['waifu2xScale'] as num).toInt();
    final tileSize = (appdata.settings['waifu2xTileSize'] as num).toInt();
    final cacheFile = File(
      FilePath.join(
        App.cachePath,
        'waifu2x',
        _buildCacheKey(
          imageBytes,
          imageKey: imageKey,
          cid: cid,
          eid: eid,
          page: page,
          noiseLevel: noiseLevel,
          scale: scale,
          tileSize: tileSize,
        ),
      ),
    );
    if (await cacheFile.exists()) {
      return cacheFile.readAsBytes();
    }

    try {
      final enhanced = await _channel.invokeMethod<Uint8List>('enhance', {
        'bytes': imageBytes,
        'noiseLevel': noiseLevel,
        'scale': scale,
        'tileSize': tileSize,
      });
      if (enhanced == null || enhanced.isEmpty) {
        return imageBytes;
      }
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(enhanced, flush: true);
      return enhanced;
    } catch (_) {
      return imageBytes;
    }
  }

  static String _buildCacheKey(
    Uint8List imageBytes, {
    required String imageKey,
    required String cid,
    required String eid,
    required int page,
    required int noiseLevel,
    required int scale,
    required int tileSize,
  }) {
    final imageHash = md5.convert(imageBytes).toString();
    final config = '$imageKey@$cid@$eid@$page@$noiseLevel@$scale@$tileSize';
    final configHash = md5.convert(config.codeUnits).toString();
    return '$configHash-$imageHash.png';
  }

  static Future<bool> _checkAvailability() async {
    if (_isAvailable != null) {
      return _isAvailable!;
    }
    _isAvailable = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    return _isAvailable!;
  }
}
