import 'dart:io';

import 'android_saf_service.dart';
import 'epub_cache_service.dart';
import 'epub_parser_service.dart';
import '../models/epub_book.dart';

/// "EPUB 파일 하나를 연다"는 유스케이스를 캡슐화.
class EpubRepository {
  final _cache = EpubCacheService();
  final _parser = EpubParserService();

  /// 일반 파일 경로와 Android SAF content:// URI를 모두 지원한다.
  /// 원본 EPUB은 이동/수정하지 않고, SAF URI의 읽기 스트림을 앱 캐시에
  /// 임시 materialize한 뒤 기존 ZIP 파이프라인으로 읽는다.
  Future<EpubBook> openBook(String originalUri) async {
    final actualPath = originalUri.startsWith('content://')
        ? await AndroidSafService.materializeUri(originalUri)
        : originalUri;
    final originalFile = File(actualPath);
    if (!await originalFile.exists()) {
      throw Exception('원본 EPUB 파일을 찾을 수 없습니다: $originalUri');
    }
    final extractedDir = await _cache.ensureExtracted(originalFile);
    return _parser.parse(
      originalUri: originalUri,
      cacheDir: extractedDir,
    );
  }

  Future<int> cacheSizeBytes() => _cache.cacheSizeBytes();
  Future<void> clearCache() => _cache.clearAll();
}
