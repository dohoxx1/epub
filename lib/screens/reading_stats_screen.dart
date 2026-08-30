import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database/app_database.dart';

/// 세션 원본 데이터를 이용해 계산하는 독서 통계 화면.
class ReadingStatsScreen extends ConsumerWidget {
  const ReadingStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    final weekStart =
        DateUtils.dateOnly(now.subtract(Duration(days: now.weekday - 1)));
    final db = ref.read(appDatabaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('독서 통계')),
      body: StreamBuilder<List<ReadingSessionRow>>(
        stream: db.watchSessionsBetween(DateTime(2000), DateTime(now.year + 1)),
        builder: (context, sessionsSnapshot) =>
            StreamBuilder<List<BookReadingStateRow>>(
          stream: db.watchReadingStates(),
          builder: (context, stateSnapshot) {
            final sessions =
                sessionsSnapshot.data ?? const <ReadingSessionRow>[];
            final states = stateSnapshot.data ?? const <BookReadingStateRow>[];
            int secondsSince(DateTime date) => sessions
                .where((s) => !s.startedAt.isBefore(date))
                .fold(0, (sum, s) => sum + s.activeSeconds);
            final total =
                sessions.fold<int>(0, (sum, s) => sum + s.activeSeconds);
            final readingDays = sessions
                .where((s) => s.activeSeconds > 0)
                .map((s) => DateUtils.dateOnly(s.startedAt))
                .toSet()
                .length;
            final perBook = <int, int>{};
            for (final s in sessions) {
              perBook[s.bookId] = (perBook[s.bookId] ?? 0) + s.activeSeconds;
            }
            final mostReadId = perBook.entries.isEmpty
                ? null
                : (perBook.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .first
                    .key;
            return StreamBuilder<List<LibraryBookRow>>(
              stream: db.watchAllBooks(),
              builder: (context, booksSnapshot) {
                final books = {
                  for (final b
                      in booksSnapshot.data ?? const <LibraryBookRow>[])
                    b.id: b
                };
                return ListView(padding: const EdgeInsets.all(16), children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _card(context, '총 독서 시간', _duration(total)),
                    _card(context, '이번 주', _duration(secondsSince(weekStart))),
                    _card(context, '이번 달', _duration(secondsSince(monthStart))),
                    _card(context, '독서한 날', '$readingDays일'),
                    _card(context, '완독 권수',
                        '${states.fold<int>(0, (sum, s) => sum + s.completedCount)}권'),
                    _card(
                        context,
                        '하루 평균',
                        readingDays == 0
                            ? '0분'
                            : _duration(total ~/ readingDays)),
                  ]),
                  const SizedBox(height: 28),
                  Text('가장 많이 읽은 책',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ListTile(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(mostReadId == null
                          ? '아직 기록이 없습니다'
                          : books[mostReadId]?.title ?? '알 수 없는 책'),
                      subtitle: mostReadId == null
                          ? null
                          : Text(_duration(perBook[mostReadId] ?? 0))),
                ]);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _card(BuildContext context, String label, String value) => SizedBox(
      width: (MediaQuery.sizeOf(context).width - 44) / 2,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    const SizedBox(height: 8),
                    Text(value, style: Theme.of(context).textTheme.titleLarge)
                  ]))));
  String _duration(int seconds) => seconds >= 3600
      ? '${seconds ~/ 3600}시간 ${(seconds % 3600) ~/ 60}분'
      : '${seconds ~/ 60}분';
}
