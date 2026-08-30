import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// EPUB(zip) 파일을 앱 전용 캐시 디렉토리에 한 번만 풀어두고,
/// 이후에는 캐시가 유효하면 재사용한다.
///
/// 캐시 키 = 원본 파일의 (경로 + 크기 + 수정시각)을 해시한 값.
/// 원본이 바뀌면(파일 크기/수정시각이 달라지면) 자동으로 캐시를 무효화하고 다시 푼다.
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

  /// 원본 EPUB(원본 위치 그대로, 이동/복사 없음)을 받아서
  /// 캐시 디렉토리 경로를 돌려준다. 이미 풀려 있으면 즉시 리턴(빠른 열기).
  Future<Directory> ensureExtracted(File originalEpub) async {
    final stat = await originalEpub.stat();
    final key = _cacheKeyFor(originalEpub, stat.size, stat.modified);
    final root = await _cacheRoot();
    final targetDir = Directory(p.join(root.path, key));

    final marker = File(p.join(targetDir.path, '.complete'));
    if (await targetDir.exists() && await marker.exists()) {
      // 이미 캐시됨: 압축 해제 스킵 -> 즉시 열기
      return targetDir;
    }

    // 캐시가 없거나 불완전(이전에 중간에 실패)하면 새로 생성
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    final bytes = await originalEpub.readAsBytes();
    await _extractZip(bytes, targetDir);

    await marker.create();
    return targetDir;
  }

  Future<void> _extractZip(Uint8List bytes, Directory targetDir) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final outPath = p.join(targetDir.path, file.name);
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }

  /// 캐시 전체 용량 조회 (설정 화면의 "캐시 비우기" 등에 사용)
  Future<int> cacheSizeBytes() async {
    final root = await _cacheRoot();
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> clearAll() async {
    final root = await _cacheRoot();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}
