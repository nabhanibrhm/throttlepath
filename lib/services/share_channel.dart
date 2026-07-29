import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The single Android method channel for handing a generated file to the
/// platform, and the cache-folder convention that has to go with it.
///
/// A file is only shareable if it sits under the folder the manifest's
/// FileProvider declares, so the path convention and the channel name belong
/// together — three separate exporters previously restated the same channel
/// string and re-derived the same folder.
class ShareChannel {
  ShareChannel._();

  static const channel = MethodChannel('id.co.opentrack.throttlepath/share');

  /// The app-cache subfolder named [name], created if it does not exist yet.
  static Future<Directory> cacheFolder(String name) async {
    final cacheDir = await getTemporaryDirectory();
    final dir = Directory('${cacheDir.path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Writes [contents] as [fileName] into the shareable cache and opens the
  /// system share sheet on it.
  ///
  /// Throws on a write or platform failure; callers surface a message.
  static Future<void> shareTextFile({
    required String fileName,
    required String contents,
    required String mimeType,
    required String title,
  }) async {
    final dir = await cacheFolder('share_files');
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(contents, flush: true);

    await channel.invokeMethod('shareFile', {
      'filePath': file.path,
      'mimeType': mimeType,
      'title': title,
    });
  }
}
