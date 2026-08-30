import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/reader_settings.dart';

part 'app_database.g.dart';

/// 제목+작가를 정규화해서 책의 "논리적 식별자"로 만든다.
/// 대소문자/앞뒤 공백 차이는 무시하고 같은 책으로 취급한다.
///
/// 이 값으로 책을 식별하기 때문에, EPUB 파일이 새로 다운받아져서
/// 실제 파일 경로나 내용이 바뀌어도(오탈자 수정 등) 제목/작가가 그대로면
/// 같은 책으로 인식되고, 그 책에 연결된 읽던 위치/형광펜/메모/책갈피가 계속 이어진다.
String _identityKey(String title, String? author) {
  String norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return '${norm(title)}|${norm(author ?? '')}';
}

/// 라이브러리에 등록된 책 한 권.
/// originalUri는 "지금 이 순간 이 책을 읽을 수 있는 경로"일 뿐, 식별자가 아니다.
/// 식별은 identityKey(제목+작가)로 하고, originalUri는 다시 열 때마다 최신 값으로 갱신된다.
@DataClassName('LibraryBookRow')
class LibraryBooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get identityKey => text()();
  TextColumn get originalUri => text()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 책 한 권당 읽던 위치 하나.
/// spineIndex: 몇 번째 챕터를 읽고 있었는지
/// scrollFraction: 그 챕터 안에서 어디까지 스크롤했는지 (0.0 ~ 1.0)
@DataClassName('ReadingProgressRow')
class ReadingProgress extends Table {
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get spineIndex => integer().withDefault(const Constant(0))();
  RealColumn get scrollFraction => real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 리더 화면 표시 설정 (폰트/글자크기/여백/너비/테마).
/// 항상 id=0인 행 하나만 존재한다 (앱 전체 공통 설정).
/// 각 컬럼이 null이면 "원본 CSS 사용"을 의미한다.
@DataClassName('ReaderSettingsRow')
class ReaderSettingsRows extends Table {
  IntColumn get id => integer()();
  TextColumn get fontFamily => text().nullable()();
  IntColumn get fontSizePercent => integer().nullable()();
  RealColumn get horizontalMarginPx => real().nullable()();
  RealColumn get verticalMarginPx => real().nullable()();
  IntColumn get lineHeightPercent => integer().nullable()();
  RealColumn get paragraphSpacingPx => real().nullable()();
  TextColumn get themeMode => text().withDefault(const Constant('original'))();
  IntColumn get customBackgroundColor => integer().nullable()();
  IntColumn get customTextColor => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 형광펜 하나.
/// bookId + spineIndex(챕터)로 어느 챕터인지 식별하고(읽던 위치와 동일한 방식),
/// 그 챕터 안에서의 위치는 startOffset/endOffset로 표현한다.
/// 이 값은 챕터 wrapper(#__reader_content_wrap__)의 전체 텍스트를 처음부터 이어붙였을 때의
/// "글자 몇 번째부터 몇 번째까지"를 뜻한다 (JS Range.toString().length 기반).
/// 폰트 크기/여백 등 렌더링 설정이 바뀌어도 원본 HTML의 글자 자체는 그대로이므로
/// 이 오프셋은 항상 유효하다.
@DataClassName('HighlightRow')
class Highlights extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get spineIndex => integer()();
  IntColumn get startOffset => integer()();
  IntColumn get endOffset => integer()();
  TextColumn get snippet => text()();
  IntColumn get colorValue => integer()(); // ARGB
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 메모 하나. 형광펜과 동일한 문자 오프셋 방식으로 원문 위치를 기억한다.
/// content가 실제 사용자가 적은 메모 내용, snippet은 메모가 달린 원문(참고용 미리보기).
@DataClassName('MemoRow')
class Memos extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get spineIndex => integer()();
  IntColumn get startOffset => integer()();
  IntColumn get endOffset => integer()();
  TextColumn get snippet => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 책갈피 하나. 형광펜/메모와 달리 문단 단위가 아니라 "챕터 안의 스크롤 위치"
/// (0.0~1.0, 읽던 위치 저장과 동일한 방식)를 기억한다.
/// label이 비어 있으면 목록에서 "n장 · 12%"처럼 자동으로 표시한다.
@DataClassName('BookmarkRow')
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get spineIndex => integer()();
  RealColumn get scrollFraction => real()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 사용자가 지정한 "여기가 내 서재 폴더야" 위치 하나.
/// 원본 EPUB 파일들은 이 폴더 밑에 그대로 있고, 앱은 경로만 기억했다가
/// 스캔할 때마다 그 안의 .epub을 찾아 LibraryBooks에 등록/갱신한다.
@DataClassName('LibraryFolderRow')
class LibraryFolders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastScannedAt => dateTime().nullable()();
}

/// 책장 하나 (예: 소설, 완독, 읽는 중). 책 한 권은 여러 책장에 동시에 속할 수 있다.
@DataClassName('ShelfRow')
class Shelves extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 책 ↔ 책장 다대다 연결.
@DataClassName('BookShelfRow')
class BookShelves extends Table {
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get shelfId => integer().references(Shelves, #id)();

  @override
  Set<Column> get primaryKey => {bookId, shelfId};
}

/// 태그 하나 (자유 생성, 이름으로 검색/필터링).
@DataClassName('TagRow')
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 책 ↔ 태그 다대다 연결.
@DataClassName('BookTagRow')
class BookTags extends Table {
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  IntColumn get tagId => integer().references(Tags, #id)();

  @override
  Set<Column> get primaryKey => {bookId, tagId};
}

/// 실제 독서 시간 기록 한 건. 화면이 열려 있는 시간 전체가 아니라, 리더가 최근
/// 사용자 조작을 확인한 구간만 activeSeconds에 누적한다.
@DataClassName('ReadingSessionRow')
class ReadingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get activeSeconds => integer().withDefault(const Constant(0))();
  RealColumn get progressStart => real().withDefault(const Constant(0))();
  RealColumn get progressEnd => real().withDefault(const Constant(0))();
}

/// 책별로 빠르게 표시할 수 있는 독서 상태 캐시. 세션 원본은 ReadingSessions에
/// 남기므로 향후 통계 규칙이 바뀌어도 다시 계산할 수 있다.
@DataClassName('BookReadingStateRow')
class BookReadingStates extends Table {
  IntColumn get bookId => integer().references(LibraryBooks, #id)();
  DateTimeColumn get lastReadAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get completedCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bookId};
}

@DriftDatabase(
  tables: [
    LibraryBooks,
    ReadingProgress,
    ReaderSettingsRows,
    Highlights,
    Memos,
    Bookmarks,
    LibraryFolders,
    Shelves,
    BookShelves,
    Tags,
    BookTags,
    ReadingSessions,
    BookReadingStates,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Phase 2 초기 버전에는 identityKey 컬럼이 없었으므로 추가하고,
            // 기존 행들은 title/author로부터 채워 넣는다 (기존 원본 경로 unique 제약도 제거됨).
            await m.addColumn(libraryBooks, libraryBooks.identityKey);
            final rows = await select(libraryBooks).get();
            for (final row in rows) {
              await (update(libraryBooks)..where((b) => b.id.equals(row.id)))
                  .write(
                LibraryBooksCompanion(
                  identityKey: Value(_identityKey(row.title, row.author)),
                ),
              );
            }
          }
          if (from < 3) {
            // Phase 3: 리더 화면 설정(폰트/글자크기/여백/테마) 테이블 신규 추가.
            await m.createTable(readerSettingsRows);
          }
          if (from < 4) {
            // Phase 3 후반: "본문 너비 제한" 컬럼을 "줄간격/문단간격"으로 교체.
            await m.addColumn(
                readerSettingsRows, readerSettingsRows.lineHeightPercent);
            await m.addColumn(
                readerSettingsRows, readerSettingsRows.paragraphSpacingPx);
          }
          if (from < 5) {
            // 상하 여백 컬럼 추가.
            await m.addColumn(
                readerSettingsRows, readerSettingsRows.verticalMarginPx);
          }
          if (from < 6) {
            // Phase 5: 형광펜 테이블 신규 추가.
            await m.createTable(highlights);
          }
          if (from < 7) {
            // Phase 6: 메모, 책갈피 테이블 신규 추가.
            await m.createTable(memos);
            await m.createTable(bookmarks);
          }
          if (from < 8) {
            // Phase 8: 로컬 라이브러리 폴더 테이블 신규 추가.
            await m.createTable(libraryFolders);
          }
          if (from < 9) {
            // Phase 9: 책장/태그 테이블 신규 추가.
            await m.createTable(shelves);
            await m.createTable(bookShelves);
            await m.createTable(tags);
            await m.createTable(bookTags);
          }
          if (from < 10) {
            await m.createTable(readingSessions);
            await m.createTable(bookReadingStates);
          }
        },
      );

  /// 제목+작가로 책을 찾는다. 있으면 최신 경로로 갱신하고 그 book id를 돌려주고,
  /// 없으면 라이브러리에 새로 등록한다.
  Future<int> getOrCreateBook({
    required String originalUri,
    required String title,
    String? author,
  }) async {
    final key = _identityKey(title, author);
    final existing = await (select(libraryBooks)
          ..where((b) => b.identityKey.equals(key)))
        .getSingleOrNull();

    if (existing != null) {
      // 파일을 다시 골랐거나(경로가 바뀜) 새 버전으로 갱신된 경우, 최신 경로만 갱신.
      // 읽던 위치/형광펜/메모/책갈피는 bookId 그대로라 자동으로 이어진다.
      if (existing.originalUri != originalUri) {
        await (update(libraryBooks)..where((b) => b.id.equals(existing.id)))
            .write(LibraryBooksCompanion(originalUri: Value(originalUri)));
      }
      return existing.id;
    }

    return into(libraryBooks).insert(
      LibraryBooksCompanion.insert(
        identityKey: key,
        originalUri: originalUri,
        title: title,
        author: Value(author),
      ),
    );
  }

  Future<ReadingProgressRow?> getProgress(int bookId) {
    return (select(readingProgress)..where((row) => row.bookId.equals(bookId)))
        .getSingleOrNull();
  }

  /// 라이브러리에 등록된 모든 책을 최근 추가 순으로 스트림으로 돌려준다.
  /// 새 책이 추가되면(getOrCreateBook 호출 시) 자동으로 갱신되어 UI에 반영된다.
  Stream<List<LibraryBookRow>> watchAllBooks() {
    return (select(libraryBooks)
          ..orderBy([
            (b) => OrderingTerm(expression: b.addedAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  Future<void> saveProgress({
    required int bookId,
    required int spineIndex,
    required double scrollFraction,
  }) {
    return into(readingProgress).insertOnConflictUpdate(
      ReadingProgressCompanion.insert(
        bookId: Value(bookId),
        spineIndex: Value(spineIndex),
        scrollFraction: Value(scrollFraction),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> saveSettings(ReaderSettings s) {
    return into(readerSettingsRows).insertOnConflictUpdate(
      ReaderSettingsRowsCompanion.insert(
        id: const Value(0),
        fontFamily: Value(s.fontFamily),
        fontSizePercent: Value(s.fontSizePercent),
        horizontalMarginPx: Value(s.horizontalMarginPx),
        verticalMarginPx: Value(s.verticalMarginPx),
        lineHeightPercent: Value(s.lineHeightPercent),
        paragraphSpacingPx: Value(s.paragraphSpacingPx),
        themeMode: Value(s.themeMode.name),
        customBackgroundColor: Value(s.customBackgroundColorValue),
        customTextColor: Value(s.customTextColorValue),
      ),
    );
  }

  Future<ReaderSettings> loadSettings() async {
    final row = await (select(readerSettingsRows)..where((r) => r.id.equals(0)))
        .getSingleOrNull();
    return _settingsFromRow(row);
  }

  Stream<ReaderSettings> watchSettings() {
    return (select(readerSettingsRows)..where((r) => r.id.equals(0)))
        .watchSingleOrNull()
        .map(_settingsFromRow);
  }

  /// 특정 챕터(bookId+spineIndex)에 저장된 형광펜을 전부 가져온다.
  /// 재렌더링(챕터 재로딩) 시 이 목록을 그대로 다시 그린다.
  Future<List<HighlightRow>> getHighlights(int bookId, int spineIndex) {
    return (select(highlights)
          ..where(
              (h) => h.bookId.equals(bookId) & h.spineIndex.equals(spineIndex))
          ..orderBy([(h) => OrderingTerm(expression: h.startOffset)]))
        .get();
  }

  /// 책 전체의 형광펜을 최신순으로 (형광펜/메모/책갈피 통합 목록 화면용).
  Stream<List<HighlightRow>> watchAllHighlights(int bookId) {
    return (select(highlights)
          ..where((h) => h.bookId.equals(bookId))
          ..orderBy([
            (h) =>
                OrderingTerm(expression: h.createdAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  Future<int> addHighlight({
    required int bookId,
    required int spineIndex,
    required int startOffset,
    required int endOffset,
    required String snippet,
    required int colorValue,
  }) {
    return into(highlights).insert(
      HighlightsCompanion.insert(
        bookId: bookId,
        spineIndex: spineIndex,
        startOffset: startOffset,
        endOffset: endOffset,
        snippet: snippet,
        colorValue: colorValue,
      ),
    );
  }

  Future<void> deleteHighlight(int id) {
    return (delete(highlights)..where((h) => h.id.equals(id))).go();
  }

  // ---- 메모 (Phase 6) ----

  Future<List<MemoRow>> getMemos(int bookId, int spineIndex) {
    return (select(memos)
          ..where(
              (m) => m.bookId.equals(bookId) & m.spineIndex.equals(spineIndex))
          ..orderBy([(m) => OrderingTerm(expression: m.startOffset)]))
        .get();
  }

  /// 책 전체의 메모를 최신순으로 (메모 관리 화면용).
  Stream<List<MemoRow>> watchAllMemos(int bookId) {
    return (select(memos)
          ..where((m) => m.bookId.equals(bookId))
          ..orderBy([
            (m) =>
                OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  Future<int> addMemo({
    required int bookId,
    required int spineIndex,
    required int startOffset,
    required int endOffset,
    required String snippet,
    required String content,
  }) {
    return into(memos).insert(
      MemosCompanion.insert(
        bookId: bookId,
        spineIndex: spineIndex,
        startOffset: startOffset,
        endOffset: endOffset,
        snippet: snippet,
        content: content,
      ),
    );
  }

  Future<void> updateMemoContent(int id, String content) {
    return (update(memos)..where((m) => m.id.equals(id))).write(
      MemosCompanion(content: Value(content), updatedAt: Value(DateTime.now())),
    );
  }

  Future<void> deleteMemo(int id) {
    return (delete(memos)..where((m) => m.id.equals(id))).go();
  }

  // ---- 책갈피 (Phase 6) ----

  /// 책 전체의 책갈피를 챕터 순서대로 (책갈피 목록 화면용).
  Stream<List<BookmarkRow>> watchBookmarks(int bookId) {
    return (select(bookmarks)
          ..where((b) => b.bookId.equals(bookId))
          ..orderBy([
            (b) => OrderingTerm(expression: b.spineIndex),
            (b) => OrderingTerm(expression: b.scrollFraction),
          ]))
        .watch();
  }

  Future<int> addBookmark({
    required int bookId,
    required int spineIndex,
    required double scrollFraction,
    String? label,
  }) {
    return into(bookmarks).insert(
      BookmarksCompanion.insert(
        bookId: bookId,
        spineIndex: spineIndex,
        scrollFraction: scrollFraction,
        label: Value(label),
      ),
    );
  }

  Future<void> deleteBookmark(int id) {
    return (delete(bookmarks)..where((b) => b.id.equals(id))).go();
  }

  // ---- 독서 기록 (Phase 10) ----

  Future<int> startReadingSession({
    required int bookId,
    required double progressStart,
  }) {
    return into(readingSessions).insert(
      ReadingSessionsCompanion.insert(
        bookId: bookId,
        startedAt: DateTime.now(),
        progressStart: Value(progressStart.clamp(0.0, 1.0)),
      ),
    );
  }

  Future<void> addActiveSeconds({
    required int sessionId,
    required int seconds,
    required double progressEnd,
  }) async {
    if (seconds <= 0) return;
    await customUpdate(
      'UPDATE reading_sessions '
      'SET active_seconds = active_seconds + ?, progress_end = ? WHERE id = ?',
      variables: [
        Variable<int>(seconds),
        Variable<double>(progressEnd.clamp(0.0, 1.0)),
        Variable<int>(sessionId)
      ],
      updates: {readingSessions},
    );
  }

  Future<void> finishReadingSession({
    required int sessionId,
    required double progressEnd,
  }) {
    return (update(readingSessions)..where((s) => s.id.equals(sessionId)))
        .write(
      ReadingSessionsCompanion(
        endedAt: Value(DateTime.now()),
        progressEnd: Value(progressEnd.clamp(0.0, 1.0)),
      ),
    );
  }

  /// 진행 상황을 기록하고 마지막 챕터의 끝에 도달했을 때만 완독으로 처리한다.
  Future<void> updateReadingState({
    required int bookId,
    required double overallProgress,
    required bool isAtBookEnd,
  }) async {
    final existing = await (select(bookReadingStates)
          ..where((s) => s.bookId.equals(bookId)))
        .getSingleOrNull();
    final justCompleted = isAtBookEnd &&
        overallProgress >= 0.995 &&
        existing?.completedAt == null;
    await into(bookReadingStates).insertOnConflictUpdate(
      BookReadingStatesCompanion.insert(
        bookId: Value(bookId),
        lastReadAt: Value(DateTime.now()),
        completedAt: justCompleted
            ? Value(DateTime.now())
            : Value(existing?.completedAt),
        completedCount:
            Value((existing?.completedCount ?? 0) + (justCompleted ? 1 : 0)),
      ),
    );
  }

  Stream<List<ReadingSessionRow>> watchSessionsBetween(
      DateTime start, DateTime end) {
    return (select(readingSessions)
          ..where((s) =>
              s.startedAt.isBiggerOrEqualValue(start) &
              s.startedAt.isSmallerThanValue(end))
          ..orderBy([(s) => OrderingTerm(expression: s.startedAt)]))
        .watch();
  }

  Stream<List<LibraryBookRow>> watchRecentBooks({int limit = 10}) {
    final query = select(libraryBooks).join([
      innerJoin(bookReadingStates,
          bookReadingStates.bookId.equalsExp(libraryBooks.id)),
    ])
      ..orderBy([
        OrderingTerm(
            expression: bookReadingStates.lastReadAt, mode: OrderingMode.desc)
      ])
      ..limit(limit);
    return query
        .watch()
        .map((rows) => rows.map((r) => r.readTable(libraryBooks)).toList());
  }

  Stream<List<BookReadingStateRow>> watchReadingStates() =>
      select(bookReadingStates).watch();

  // ---- 로컬 라이브러리 폴더 (Phase 8) ----

  Stream<List<LibraryFolderRow>> watchFolders() {
    return (select(libraryFolders)
          ..orderBy([(f) => OrderingTerm(expression: f.addedAt)]))
        .watch();
  }

  /// 이미 등록된 폴더면 그 id를 그대로 돌려주고, 아니면 새로 등록한다.
  Future<int> addFolderIfNew(String path) async {
    final existing = await (select(libraryFolders)
          ..where((f) => f.path.equals(path)))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return into(libraryFolders)
        .insert(LibraryFoldersCompanion.insert(path: path));
  }

  Future<void> removeFolder(int id) {
    return (delete(libraryFolders)..where((f) => f.id.equals(id))).go();
  }

  Future<void> markFolderScanned(int id) {
    return (update(libraryFolders)..where((f) => f.id.equals(id))).write(
      LibraryFoldersCompanion(lastScannedAt: Value(DateTime.now())),
    );
  }

  /// 이 책이 더 이상(원본 파일이 사라져서 등) 필요 없을 때 라이브러리 기록만 지운다.
  /// 형광펜/메모/책갈피/읽던 위치 등 이 책에 딸린 데이터도 함께 정리한다.
  Future<void> removeBook(int bookId) async {
    await (delete(highlights)..where((h) => h.bookId.equals(bookId))).go();
    await (delete(memos)..where((m) => m.bookId.equals(bookId))).go();
    await (delete(bookmarks)..where((b) => b.bookId.equals(bookId))).go();
    await (delete(readingProgress)..where((p) => p.bookId.equals(bookId))).go();
    await (delete(bookShelves)..where((bs) => bs.bookId.equals(bookId))).go();
    await (delete(bookTags)..where((bt) => bt.bookId.equals(bookId))).go();
    await (delete(libraryBooks)..where((b) => b.id.equals(bookId))).go();
  }

  // ---- 책장 (Phase 9) ----

  Stream<List<ShelfRow>> watchShelves() {
    return (select(shelves)
          ..orderBy([(s) => OrderingTerm(expression: s.createdAt)]))
        .watch();
  }

  Future<int> addShelf(String name) {
    return into(shelves).insert(ShelvesCompanion.insert(name: name));
  }

  Future<void> deleteShelf(int id) async {
    await (delete(bookShelves)..where((bs) => bs.shelfId.equals(id))).go();
    await (delete(shelves)..where((s) => s.id.equals(id))).go();
  }

  /// add가 true면 그 책장에 책을 넣고, false면 뺀다.
  Future<void> setBookInShelf(int bookId, int shelfId, bool add) async {
    if (add) {
      await into(bookShelves).insertOnConflictUpdate(
        BookShelvesCompanion.insert(bookId: bookId, shelfId: shelfId),
      );
    } else {
      await (delete(bookShelves)
            ..where(
                (bs) => bs.bookId.equals(bookId) & bs.shelfId.equals(shelfId)))
          .go();
    }
  }

  Stream<Set<int>> watchShelfIdsForBook(int bookId) {
    return (select(bookShelves)..where((bs) => bs.bookId.equals(bookId)))
        .watch()
        .map((rows) => rows.map((r) => r.shelfId).toSet());
  }

  /// 특정 책장에 속한 책들만 (라이브러리 화면의 "책장별 보기"용).
  Stream<List<LibraryBookRow>> watchBooksInShelf(int shelfId) {
    final query = select(libraryBooks).join([
      innerJoin(bookShelves, bookShelves.bookId.equalsExp(libraryBooks.id)),
    ])
      ..where(bookShelves.shelfId.equals(shelfId))
      ..orderBy([
        OrderingTerm(expression: libraryBooks.addedAt, mode: OrderingMode.desc)
      ]);
    return query
        .watch()
        .map((rows) => rows.map((row) => row.readTable(libraryBooks)).toList());
  }

  // ---- 태그 (Phase 9) ----

  Stream<List<TagRow>> watchTags() {
    return (select(tags)..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  /// 이미 같은 이름의 태그가 있으면 그 id를 그대로 쓰고, 없으면 새로 만든다.
  Future<int> addTagIfNew(String name) async {
    final trimmed = name.trim();
    final existing = await (select(tags)..where((t) => t.name.equals(trimmed)))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return into(tags).insert(TagsCompanion.insert(name: trimmed));
  }

  Future<void> deleteTag(int id) async {
    await (delete(bookTags)..where((bt) => bt.tagId.equals(id))).go();
    await (delete(tags)..where((t) => t.id.equals(id))).go();
  }

  Future<void> setBookTag(int bookId, int tagId, bool add) async {
    if (add) {
      await into(bookTags).insertOnConflictUpdate(
        BookTagsCompanion.insert(bookId: bookId, tagId: tagId),
      );
    } else {
      await (delete(bookTags)
            ..where((bt) => bt.bookId.equals(bookId) & bt.tagId.equals(tagId)))
          .go();
    }
  }

  Stream<List<TagRow>> watchTagsForBook(int bookId) {
    final query = select(tags).join([
      innerJoin(bookTags, bookTags.tagId.equalsExp(tags.id)),
    ])
      ..where(bookTags.bookId.equals(bookId))
      ..orderBy([OrderingTerm(expression: tags.name)]);
    return query
        .watch()
        .map((rows) => rows.map((row) => row.readTable(tags)).toList());
  }

  /// 특정 태그가 붙은 책들만 (태그 필터링용).
  Stream<List<LibraryBookRow>> watchBooksWithTag(int tagId) {
    final query = select(libraryBooks).join([
      innerJoin(bookTags, bookTags.bookId.equalsExp(libraryBooks.id)),
    ])
      ..where(bookTags.tagId.equals(tagId))
      ..orderBy([
        OrderingTerm(expression: libraryBooks.addedAt, mode: OrderingMode.desc)
      ]);
    return query
        .watch()
        .map((rows) => rows.map((row) => row.readTable(libraryBooks)).toList());
  }

  ReaderSettings _settingsFromRow(ReaderSettingsRow? row) {
    if (row == null) return ReaderSettings.defaults();
    return ReaderSettings(
      fontFamily: row.fontFamily,
      fontSizePercent: row.fontSizePercent,
      horizontalMarginPx: row.horizontalMarginPx,
      verticalMarginPx: row.verticalMarginPx,
      lineHeightPercent: row.lineHeightPercent,
      paragraphSpacingPx: row.paragraphSpacingPx,
      themeMode: ReaderThemeMode.values.firstWhere(
        (m) => m.name == row.themeMode,
        orElse: () => ReaderThemeMode.original,
      ),
      customBackgroundColorValue: row.customBackgroundColor,
      customTextColorValue: row.customTextColor,
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'epub_reader.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// 앱 전체에서 하나만 쓰는 DB 인스턴스 (Riverpod Provider).
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
