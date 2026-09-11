import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// EPUB(zip) 파일을 앱 전용 캐시 디렉토리에 한 번만 풀어두고,
/// 이후에는 캐시가 유효하면 재사용한다.
///
/// 압축 해제는 CPU 비용이 크므로 UI isolate에서 실행하지 않는다.
class EpubCacheService {
  static const _cacheRootName = 'epub_cache';

  Future<Directory> _cacheRoot() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, _cacheRootName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _cacheKeyFor(File original, int size, DateTime modified) {
    final raw = '${original.path}|$size|${modified.millisecondsSinceEpoch}';
    return sha1.convert(raw.codeUnits).toString();
  }

  Future<Directory> ensureExtracted(File originalEpub) async {
    final stat = await originalEpub.stat();
    final key = _cacheKeyFor(originalEpub, stat.size, stat.modified);
    final root = await _cacheRoot();
    final targetDir = Directory(p.join(root.path, key));
    final marker = File(p.join(targetDir.path, '.complete'));

    if (await marker.exists()) return targetDir;

    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    final bytes = await originalEpub.readAsBytes();
    await Isolate.run(() => _extractZipToPath(bytes, targetDir.path));
    await marker.create();
    return targetDir;
  }

  static Future<void> _extractZipToPath(
    Uint8List bytes,
    String targetPath,
  ) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final outPath = p.join(targetPath, file.name);
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>, flush: false);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }

  Future<int> cacheSizeBytes() async {
    final root = await _cacheRoot();
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> clearAll() async {
    final root = await _cacheRoot();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
