import 'dart:io';
import 'epub_cache_service.dart';
import 'epub_parser_service.dart';
import '../models/epub_book.dart';

/// "EPUB 파일 하나를 연다"는 유스케이스를 캡슐화.
/// 화면(UI) 코드는 이 클래스만 알면 된다.
class EpubRepository {
  final _cache = EpubCacheService();
  final _parser = EpubParserService();

  /// originalPath: 사용자가 고른 원본 EPUB의 실제 경로.
  /// 원본은 절대 이동/복사하지 않고, 읽기만 해서 캐시 디렉토리에 압축 해제한다.
  Future<EpubBook> openBook(String originalPath) async {
    final originalFile = File(originalPath);
    if (!await originalFile.exists()) {
      throw Exception('원본 EPUB 파일을 찾을 수 없습니다: $originalPath');
    }
    final extractedDir = await _cache.ensureExtracted(originalFile);
    return _parser.parse(
      originalUri: originalPath,
      cacheDir: extractedDir,
    );
  }

  Future<int> cacheSizeBytes() => _cache.cacheSizeBytes();
  Future<void> clearCache() => _cache.clearAll();
}
