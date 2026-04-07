import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/webdav_config.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      uploadData();
    }
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    final config = WebDavSettings.readSyncConfig();
    final autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && (config?.isConfigured ?? false);
  }

  Future<Res<bool>> uploadData() async {
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      final config = WebDavSettings.readSyncConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (!config.isConfigured) {
        return const Res(true);
      }
      final client = WebDavClientFactory.create(config);
      final directoryPath = WebDavPathUtils.scope(config, '/');

      try {
        appdata.settings['dataVersion']++;
        await appdata.saveData(false);
        var data = await exportAppData(
          appdata.settings['disableSyncFields'].toString().isNotEmpty,
        );
        var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
            .toString();
        var filename = time;
        filename += '-';
        filename += appdata.settings['dataVersion'].toString();
        filename += '.venera';
        await client.mkdirAll(directoryPath);
        var files = await client.readDir(directoryPath);
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
        if (old != null) {
          await client.remove(WebDavPathUtils.joinToBase(config, old.name!));
        }
        if (files.length >= 10) {
          files.sort((a, b) => a.name!.compareTo(b.name!));
          await client.remove(
            WebDavPathUtils.joinToBase(config, files.first.name!),
          );
        }
        await client.write(
          WebDavPathUtils.joinToBase(config, filename),
          await data.readAsBytes(),
        );
        data.deleteIgnoreError();
        Log.info("Upload Data", "Data uploaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      final config = WebDavSettings.readSyncConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (!config.isConfigured) {
        return const Res(true);
      }
      final client = WebDavClientFactory.create(config);
      final directoryPath = WebDavPathUtils.scope(config, '/');

      try {
        var files = await client.readDir(directoryPath);
        files.sort((a, b) => b.name!.compareTo(a.name!));
        var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
        if (file == null) {
          throw 'No data file found';
        }
        var version = file.name!
            .split('-')
            .elementAtOrNull(1)
            ?.split('.')
            .first;
        if (version != null && int.tryParse(version) != null) {
          var currentVersion = appdata.settings['dataVersion'];
          if (currentVersion != null && int.parse(version) <= currentVersion) {
            Log.info("Data Sync", 'No new data to download');
            return const Res(true);
          }
        }
        Log.info("Data Sync", "Downloading data from WebDAV server");
        var localFile = File(FilePath.join(App.cachePath, file.name!));
        await client.read2File(
          WebDavPathUtils.joinToBase(config, file.name!),
          localFile.path,
        );
        await importAppData(localFile, true);
        await localFile.delete();
        Log.info("Data Sync", "Data downloaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}
