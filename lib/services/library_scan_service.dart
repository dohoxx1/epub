import 'dart:io';

import 'android_saf_service.dart';
import 'database/app_database.dart';
import 'epub_repository.dart';

class ScanResult {
  final int scanned;
  final int added;
  final List<String> failedPaths;

  const ScanResult({
    required this.scanned,
    required this.added,
    required this.failedPaths,
  });
}

/// 폴더의 EPUB을 찾아 라이브러리에 등록한다.
/// Android에서는 SAF tree URI를 사용해 scoped storage를 우회하지 않고 읽는다.
class LibraryScanService {
  final EpubRepository _repo;
  final AppDatabase _db;

  LibraryScanService(this._repo, this._db);

  Future<ScanResult> scanFolder(String folderPath) async {
    if (folderPath.startsWith('content://')) {
      final uris = await AndroidSafService.listEpubUris(folderPath);
      return scanUris(uris);
    }

    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      throw Exception('폴더에 접근할 수 없습니다. Android에서는 폴더를 다시 선택해 주세요.');
    }
    final paths = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.epub')) {
        paths.add(entity.path);
      }
    }
    return scanUris(paths);
  }

  Future<ScanResult> scanUris(List<String> uris) async {
    var added = 0;
    final failed = <String>[];
    for (final uri in uris) {
      try {
        final book = await _repo.openBook(uri);
        await _db.getOrCreateBook(
          originalUri: uri,
          title: book.title,
          author: book.author,
          coverImagePath: book.coverImagePath,
        );
        added++;
      } catch (_) {
        failed.add(uri);
      }
    }
    return ScanResult(
      scanned: uris.length,
      added: added,
      failedPaths: failed,
    );
  }
}
