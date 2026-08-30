import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database/app_database.dart';

/// 날짜별 실제 독서 시간과 읽은 책을 보여 주는 개인 독서 기록장.
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
      appBar: AppBar(title: const Text('독서 캘린더')),
      body: StreamBuilder<List<ReadingSessionRow>>(
        stream: db.watchSessionsBetween(start, end),
        builder: (context, snapshot) {
          final sessions = snapshot.data ?? const <ReadingSessionRow>[];
          final byDay = <DateTime, List<ReadingSessionRow>>{};
          for (final session in sessions) {
            final day = DateUtils.dateOnly(session.startedAt.toLocal());
            (byDay[day] ??= []).add(session);
          }
          return Column(
            children: [
              _monthHeader(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  for (final d in ['월', '화', '수', '목', '금', '토', '일'])
                    Expanded(child: Center(child: Text(d)))
                ]),
              ),
              const SizedBox(height: 4),
              _calendarGrid(byDay),
              const Divider(height: 24),
              Expanded(child: _dayDetails(byDay[_selected] ?? const [])),
            ],
          );
        },
      ),
    );
  }

  Widget _monthHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Row(
          children: [
            IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left)),
            Expanded(
                child: Center(
                    child: Text('${_month.year}년 ${_month.month}월',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18)))),
            IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right)),
          ],
        ),
      );

  Widget _calendarGrid(Map<DateTime, List<ReadingSessionRow>> byDay) {
    final offset = _month.weekday - 1;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <Widget>[for (var i = 0; i < offset; i++) const SizedBox()];
    for (var day = 1; day <= days; day++) {
      final date = DateTime(_month.year, _month.month, day);
      final rows = byDay[date] ?? const <ReadingSessionRow>[];
      final seconds = rows.fold<int>(0, (sum, row) => sum + row.activeSeconds);
      final selected = DateUtils.isSameDay(date, _selected);
      cells.add(InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _selected = date),
        child: Container(
          margin: const EdgeInsets.all(2),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Text('$day'),
            if (seconds > 0)
              Text(_duration(seconds),
                  style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.primary)),
            if (rows.isNotEmpty) const Icon(Icons.menu_book, size: 13),
          ]),
        ),
      ));
    }
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: cells));
  }

  Widget _dayDetails(List<ReadingSessionRow> rows) {
    final total = rows.fold<int>(0, (sum, row) => sum + row.activeSeconds);
    final bookIds = rows.map((r) => r.bookId).toSet();
    return StreamBuilder<List<LibraryBookRow>>(
      stream: ref.read(appDatabaseProvider).watchAllBooks(),
      builder: (context, snapshot) {
        final books = {
          for (final b in snapshot.data ?? const <LibraryBookRow>[]) b.id: b
        };
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text('${_selected.month}월 ${_selected.day}일 · ${_duration(total)}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text('기록된 독서 시간이 없습니다.')),
            for (final id in bookIds)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(books[id]?.title ?? '알 수 없는 책'),
                subtitle: Text(
                    '${_duration(rows.where((r) => r.bookId == id).fold<int>(0, (s, r) => s + r.activeSeconds))} 읽음'),
              ),
          ],
        );
      },
    );
  }

  String _duration(int seconds) => seconds >= 3600
      ? '${seconds ~/ 3600}시간 ${(seconds % 3600) ~/ 60}분'
      : '${seconds ~/ 60}분';
}
