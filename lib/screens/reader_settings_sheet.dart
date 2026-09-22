import 'dart:async';

import 'package:flutter/material.dart';
import '../models/reader_settings.dart';

class ReaderSettingsSheet extends StatefulWidget {
  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  const ReaderSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late ReaderSettings _s = widget.initial;
  Timer? _notifyTimer;
  ReaderSettings? _pendingNotification;

  void _update(ReaderSettings Function(ReaderSettings) fn) {
    final next = fn(_s);
    setState(() => _s = next);
    _pendingNotification = next;
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      final pending = _pendingNotification;
      _pendingNotification = null;
      if (pending != null && mounted) widget.onChanged(pending);
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.4,
      minChildSize: 0.28,
      maxChildSize: 0.5,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('읽기 설정', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          _buildFontSection(),
          const Divider(height: 32),
          _buildFontSizeSection(),
          const Divider(height: 32),
          _buildMarginSection(),
          const Divider(height: 32),
          _buildVerticalMarginSection(),
          const Divider(height: 32),
          _buildLineHeightSection(),
          const Divider(height: 32),
          _buildParagraphSpacingSection(),
          const Divider(height: 32),
          _buildThemeSection(),
          const Divider(height: 32),
          _buildDisplaySection(),
        ],
      ),
    );
  }

  Widget _buildFontSection() {
    return _SectionLabel(
      title: '폰트',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: kFontChoices.map((choice) {
          final (label, cssValue) = choice;
          final isOriginal = cssValue.isEmpty;
          final selected = isOriginal ? _s.fontFamily == null : _s.fontFamily == cssValue;
          return ChoiceChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => _update((s) => s.copyWith(fontFamily: () => isOriginal ? null : cssValue)),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFontSizeSection() {
    final useOriginal = _s.fontSizePercent == null;
    final value = _s.fontSizePercent ?? 100;
    return _SectionLabel(
      title: '글자 크기',
      trailing: _OriginalToggle(useOriginal: useOriginal, onChanged: (useOrig) => _update((s) => s.copyWith(fontSizePercent: () => useOrig ? null : 100))),
      child: _AdjustableSlider(value: value.toDouble(), min: 70, max: 250, step: 5, enabled: !useOriginal, label: (v) => '${v.round()}%', onChanged: (v) => _update((s) => s.copyWith(fontSizePercent: () => v.round()))),
    );
  }

  Widget _buildMarginSection() {
    final useOriginal = _s.horizontalMarginPx == null;
    final value = _s.horizontalMarginPx ?? 16;
    return _SectionLabel(
      title: '좌우 여백',
      trailing: _OriginalToggle(useOriginal: useOriginal, onChanged: (useOrig) => _update((s) => s.copyWith(horizontalMarginPx: () => useOrig ? null : 16.0))),
      child: _AdjustableSlider(value: value, min: 0, max: 48, step: 2, enabled: !useOriginal, label: (v) => '${v.round()}px', onChanged: (v) => _update((s) => s.copyWith(horizontalMarginPx: () => v))),
    );
  }

  Widget _buildVerticalMarginSection() {
    final useOriginal = _s.verticalMarginPx == null;
    final value = _s.verticalMarginPx ?? 16;
    return _SectionLabel(
      title: '상하 여백',
      trailing: _OriginalToggle(useOriginal: useOriginal, onChanged: (useOrig) => _update((s) => s.copyWith(verticalMarginPx: () => useOrig ? null : 16.0))),
      child: _AdjustableSlider(value: value, min: 0, max: 64, step: 2, enabled: !useOriginal, label: (v) => '${v.round()}px', onChanged: (v) => _update((s) => s.copyWith(verticalMarginPx: () => v))),
    );
  }

  Widget _buildLineHeightSection() {
    final useOriginal = _s.lineHeightPercent == null;
    final value = _s.lineHeightPercent ?? 150;
    return _SectionLabel(
      title: '줄 간격',
      trailing: _OriginalToggle(useOriginal: useOriginal, onChanged: (useOrig) => _update((s) => s.copyWith(lineHeightPercent: () => useOrig ? null : 150))),
      child: _AdjustableSlider(value: value.toDouble(), min: 100, max: 250, step: 5, enabled: !useOriginal, label: (v) => '${v.round()}%', onChanged: (v) => _update((s) => s.copyWith(lineHeightPercent: () => v.round()))),
    );
  }

  Widget _buildParagraphSpacingSection() {
    final useOriginal = _s.paragraphSpacingPx == null;
    final value = _s.paragraphSpacingPx ?? 12;
    return _SectionLabel(
      title: '문단 간격',
      trailing: _OriginalToggle(useOriginal: useOriginal, onChanged: (useOrig) => _update((s) => s.copyWith(paragraphSpacingPx: () => useOrig ? null : 12.0))),
      child: _AdjustableSlider(value: value, min: 0, max: 32, step: 2, enabled: !useOriginal, label: (v) => '${v.round()}px', onChanged: (v) => _update((s) => s.copyWith(paragraphSpacingPx: () => v))),
    );
  }

  Widget _buildThemeSection() {
    return _SectionLabel(
      title: '테마',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            _themeChip('원본', ReaderThemeMode.original),
            _themeChip('라이트', ReaderThemeMode.light),
            _themeChip('다크', ReaderThemeMode.dark),
            _themeChip('사용자 지정', ReaderThemeMode.custom),
          ]),
          if (_s.themeMode == ReaderThemeMode.custom) ...[
            const SizedBox(height: 16),
            Text('배경색', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            _colorSwatchRow(kBackgroundPalette, _s.customBackgroundColorValue, (v) => _update((s) => s.copyWith(customBackgroundColorValue: () => v))),
            const SizedBox(height: 16),
            Text('글자색', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            _colorSwatchRow(kTextPalette, _s.customTextColorValue, (v) => _update((s) => s.copyWith(customTextColorValue: () => v))),
          ],
        ],
      ),
    );
  }

  Widget _buildDisplaySection() {
    final whitePoint = _s.whitePointReductionPercent;
    return _SectionLabel(
      title: '화면',
      child: Column(
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('전자잉크 질감'),
            subtitle: const Text('화면 전체에 아주 미세한 흑백 입자를 추가합니다.'),
            value: _s.eInkGrainEnabled,
            onChanged: (value) => _update((s) => s.copyWith(eInkGrainEnabled: value)),
          ),
          _AdjustableSlider(
            value: whitePoint.toDouble(),
            min: 0,
            max: 40,
            step: 1,
            enabled: true,
            label: (v) => '${v.round()}%',
            onChanged: (v) => _update((s) => s.copyWith(whitePointReductionPercent: v.round())),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('화이트 포인트 줄이기', style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _themeChip(String label, ReaderThemeMode mode) {
    return ChoiceChip(label: Text(label), selected: _s.themeMode == mode, onSelected: (_) => _update((s) => s.copyWith(themeMode: mode)));
  }

  Widget _colorSwatchRow(List<int> palette, int? selected, ValueChanged<int> onPick) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: palette.map((argb) {
        final isSelected = selected == argb;
        return GestureDetector(
          onTap: () => onPick(argb),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Color(argb),
              shape: BoxShape.circle,
              border: Border.all(color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey, width: isSelected ? 3 : 1),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _SectionLabel({required this.title, required this.child, this.trailing});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(title, style: Theme.of(context).textTheme.titleMedium), if (trailing != null) trailing!]),
    const SizedBox(height: 4),
    child,
  ]);
}

class _AdjustableSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final String Function(double value) label;
  final ValueChanged<double> onChanged;
  const _AdjustableSlider({required this.value, required this.min, required this.max, required this.step, required this.enabled, required this.label, required this.onChanged});
  @override
  State<_AdjustableSlider> createState() => _AdjustableSliderState();
}

class _AdjustableSliderState extends State<_AdjustableSlider> {
  Timer? _repeatTimer;
  double get _clampedValue => widget.value.clamp(widget.min, widget.max);
  void _step(double direction) {
    final next = (_clampedValue + direction * widget.step).clamp(widget.min, widget.max);
    if (next != _clampedValue) widget.onChanged(next);
  }
  void _startRepeating(double direction) {
    _step(direction);
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(const Duration(milliseconds: 180), (_) => _step(direction));
  }
  void _stopRepeating() { _repeatTimer?.cancel(); _repeatTimer = null; }
  @override
  void dispose() { _repeatTimer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final atMin = _clampedValue <= widget.min;
    final atMax = _clampedValue >= widget.max;
    return Row(children: [
      _StepButton(icon: Icons.remove, enabled: widget.enabled && !atMin, onTap: () => _step(-1), onHoldStart: () => _startRepeating(-1), onHoldEnd: _stopRepeating),
      Expanded(child: Column(children: [
        Slider(value: _clampedValue, min: widget.min, max: widget.max, label: widget.label(_clampedValue), onChanged: widget.enabled ? widget.onChanged : null),
        Text(widget.label(_clampedValue), style: Theme.of(context).textTheme.bodySmall),
      ])),
      _StepButton(icon: Icons.add, enabled: widget.enabled && !atMax, onTap: () => _step(1), onHoldStart: () => _startRepeating(1), onHoldEnd: _stopRepeating),
    ]);
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  const _StepButton({required this.icon, required this.enabled, required this.onTap, required this.onHoldStart, required this.onHoldEnd});
  @override
  Widget build(BuildContext context) {
    final color = enabled ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor;
    return GestureDetector(
      onLongPressStart: enabled ? (_) => onHoldStart() : null,
      onLongPressEnd: enabled ? (_) => onHoldEnd() : null,
      onLongPressCancel: enabled ? onHoldEnd : null,
      child: IconButton(icon: Icon(icon), color: color, onPressed: enabled ? onTap : null, style: IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest, shape: const CircleBorder())),
    );
  }
}

class _OriginalToggle extends StatelessWidget {
  final bool useOriginal;
  final ValueChanged<bool> onChanged;
  const _OriginalToggle({required this.useOriginal, required this.onChanged});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('원본 사용', style: Theme.of(context).textTheme.bodySmall),
    Switch(value: useOriginal, onChanged: onChanged),
  ]);
}
