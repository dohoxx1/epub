import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database/app_database.dart';

/// 날짜별 실제 독서 시간과 읽은 책을 표지 중심으로 보여 주는 독서 기록장.
class ReadingCalendarScreen extends ConsumerStatefulWidget {
  const ReadingCalendarScreen({super.key});

  @override
  ConsumerState<ReadingCalendarScreen> createState() =>
      _ReadingCalendarScreenState();
}

class _ReadingCalendarScreenState extends ConsumerState<ReadingCalendarScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _selected = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final start = _month;
    final end = DateTime(_month.year, _month.month + 1);
    final db = ref.read(appDatabaseProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '독서 캘린더',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: StreamBuilder<List<ReadingSessionRow>>(
        stream: db.watchSessionsBetween(start, end),
        builder: (context, sessionSnapshot) {
          final sessions = sessionSnapshot.data ?? const <ReadingSessionRow>[];
          final byDay = <DateTime, List<ReadingSessionRow>>{};
          for (final session in sessions) {
            final day = DateUtils.dateOnly(session.startedAt.toLocal());
            (byDay[day] ??= []).add(session);
          }

          return StreamBuilder<List<LibraryBookRow>>(
            stream: db.watchAllBooks(),
            builder: (context, bookSnapshot) {
              final books = {
                for (final book
                    in bookSnapshot.data ?? const <LibraryBookRow>[]) book.id: book,
              };

              return Column(
                children: [
                  _monthHeader(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final day in const [
                          '월',
                          '화',
                          '수',
                          '목',
                          '금',
                          '토',
                          '일',
                        ])
                          Expanded(
                            child: Center(
                              child: Text(
                                day,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  _calendarGrid(byDay, books),
                  const SizedBox(height: 12),
                  Container(
                    height: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  Expanded(
                    child: _dayDetails(byDay[_selected] ?? const [], books),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _monthHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month - 1),
              ),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${_month.year}년 ${_month.month}월',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month + 1),
              ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      );

  Widget _calendarGrid(
    Map<DateTime, List<ReadingSessionRow>> byDay,
    Map<int, LibraryBookRow> books,
  ) {
    final offset = _month.weekday - 1;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <Widget>[
      for (var i = 0; i < offset; i++) const SizedBox(),
    ];

    for (var day = 1; day <= days; day++) {
      final date = DateTime(_month.year, _month.month, day);
      final rows = byDay[date] ?? const <ReadingSessionRow>[];
      final selected = DateUtils.isSameDay(date, _selected);
      final bookIds = rows.map((row) => row.bookId).toSet().toList();
      final seconds = rows.fold<int>(
        0,
        (sum, row) => sum + row.activeSeconds,
      );

      cells.add(
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _selected = date),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.fromLTRB(4, 5, 4, 4),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: rows.isEmpty ? 0.0 : 0.34),
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.secondary,
                      width: 1,
                    )
                  : null,
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.center,
                  child: Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: bookIds.isEmpty
                      ? const SizedBox()
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (final id in bookIds.take(2))
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 1.5),
                                child: _coverThumb(books[id], 31, 43),
                              ),
                          ],
                        ),
                ),
                if (seconds > 0)
                  Text(
                    _shortDuration(seconds),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: 8.5,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                else
                  const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: GridView.count(
        crossAxisCount: 7,
        childAspectRatio: 0.72,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: cells,
      ),
    );
  }

  Widget _dayDetails(
    List<ReadingSessionRow> rows,
    Map<int, LibraryBookRow> books,
  ) {
    final total = rows.fold<int>(0, (sum, row) => sum + row.activeSeconds);
    final bookIds = rows.map((row) => row.bookId).toSet().toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                '${_selected.month}월 ${_selected.day}일',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            Text(
              total > 0 ? _duration(total) : '기록 없음',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (bookIds.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 28,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
                Text(
                  '이날 기록된 독서가 없습니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          )
        else
          for (final id in bookIds) ...[
            _bookDayCard(
              books[id],
              rows.where((row) => row.bookId == id).fold<int>(
                    0,
                    (sum, row) => sum + row.activeSeconds,
                  ),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _bookDayCard(LibraryBookRow? book, int seconds) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _coverThumb(book, 58, 82),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book?.title ?? '알 수 없는 책',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book?.author ?? '작가 미상',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${_duration(seconds)} 읽음',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverThumb(LibraryBookRow? book, double width, double height) {
    final path = book?.coverImagePath;
    final fallback = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        Icons.menu_book_outlined,
        size: width * 0.42,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (path == null || path.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(path),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  String _shortDuration(int seconds) {
    if (seconds < 60) return '<1분';
    final minutes = seconds ~/ 60;
    if (minutes >= 60) return '${minutes ~/ 60}h';
    return '${minutes}m';
  }

  String _duration(int seconds) {
    if (seconds < 60) return '<1분';
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      return minutes == 0 ? '$hours시간' : '$hours시간 $minutes분';
    }
    return '${seconds ~/ 60}분';
  }
}
