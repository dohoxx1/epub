import 'dart:io';
import 'database/app_database.dart';
import 'epub_repository.dart';

/// 폴더 하나를 스캔한 결과.
class ScanResult {
  final int scanned;
  final int added;
  final List<String> failedPaths;

  const ScanResult(
      {required this.scanned, required this.added, required this.failedPaths});
}

/// "이 폴더 밑에 있는 .epub을 전부 찾아서 라이브러리에 등록한다"를 담당한다.
/// 원본 파일은 절대 옮기거나 복사하지 않고, 경로만 읽어서 DB에 기록한다.
class LibraryScanService {
  final EpubRepository _repo;
  final AppDatabase _db;

  LibraryScanService(this._repo, this._db);

  /// 폴더 밑(하위 폴더 포함)의 모든 .epub 파일을 찾아 라이브러리에 등록/갱신한다.
  /// 이미 등록된 책(제목+작가로 식별)은 경로만 최신으로 갱신되고,
  /// 읽던 위치/형광펜/메모/책갈피는 그대로 유지된다.
  Future<ScanResult> scanFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      throw Exception('폴더에 접근할 수 없습니다. 권한이 사라졌을 수 있어요: $folderPath');
    }

    var scanned = 0;
    var added = 0;
    final failed = <String>[];

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.epub')) continue;

      scanned++;
      try {
        // 이미 캐시된 책이면 openBook이 재압축 없이 빠르게 넘어간다 (EpubCacheService 재사용).
        final book = await _repo.openBook(entity.path);
        await _db.getOrCreateBook(
          originalUri: entity.path,
          title: book.title,
          author: book.author,
          coverImagePath: book.coverImagePath,
        );
        added++;
      } catch (_) {
        failed.add(entity.path);
      }
    }

    return ScanResult(scanned: scanned, added: added, failedPaths: failed);
  }
}
