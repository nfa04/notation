import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';

import 'calendar_style.dart';
import 'style_service.dart';
import 'styled_box.dart';
import 'platform_dialog.dart';

/// Lets the user dress up one calendar, event, task or day. Returns the new
/// look (an empty [ItemStyle] means "back to default"), or null if cancelled.
///
/// [base] is what applies when nothing is chosen, shown in the preview.
/// Days have no border, so they pass [showBorder] false.
Future<ItemStyle?> showStyleDialog(
  BuildContext context, {
  required String title,
  required String sample,
  required ItemStyle initial,
  required ResolvedStyle base,
  bool showBorder = true,
}) {
  return showDialog<ItemStyle>(
    context: context,
    builder: (context) => _StyleDialog(title: title, sample: sample, initial: initial, base: base, showBorder: showBorder),
  );
}

class _StyleDialog extends StatefulWidget {
  final String title;
  final String sample;
  final ItemStyle initial;
  final ResolvedStyle base;
  final bool showBorder;

  const _StyleDialog({
    required this.title,
    required this.sample,
    required this.initial,
    required this.base,
    required this.showBorder,
  });

  @override
  State<_StyleDialog> createState() => _StyleDialogState();
}

class _StyleDialogState extends State<_StyleDialog> {
  late ItemStyle _style = widget.initial;
  late final _emoji = TextEditingController(text: widget.initial.emoji ?? '');

  @override
  void dispose() {
    _emoji.dispose();
    super.dispose();
  }

  ResolvedStyle get _preview => ResolvedStyle(
        color: _style.color ?? widget.base.color,
        border: _style.border ?? widget.base.border,
        borderWidth: widget.base.borderWidth,
        radius: widget.base.radius,
        emoji: _style.emoji ?? widget.base.emoji,
      );

  void _setEmoji(String? emoji) {
    _emoji.text = emoji ?? '';
    setState(() => _style = emoji == null || emoji.isEmpty ? _style.copyWith(clearEmoji: true) : _style.copyWith(emoji: emoji));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            StyledBox(
              style: _preview,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text.verbatim(_preview.label(widget.sample), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 16),
            const Text('Color'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _swatch(null, scheme),
              for (final c in swatchColors) _swatch(c, scheme),
            ]),
            if (widget.showBorder) ...[
              const SizedBox(height: 16),
              const Text('Border'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ChoiceChip(
                  label: const Text('Default'),
                  selected: _style.border == null,
                  onSelected: (_) => setState(() => _style = _style.copyWith(clearBorder: true)),
                ),
                for (final b in BorderKind.values)
                  ChoiceChip(
                    label: Text(b.label),
                    selected: _style.border == b,
                    onSelected: (_) => setState(() => _style = _style.copyWith(border: b)),
                  ),
              ]),
            ],
            const SizedBox(height: 16),
            const Text('Emoji'),
            const SizedBox(height: 6),
            Wrap(spacing: 2, runSpacing: 2, children: [
              for (final e in cuteEmoji)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _setEmoji(e),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: _style.emoji == e ? scheme.primaryContainer : null,
                    ),
                    child: Text.verbatim(e, style: const TextStyle(fontSize: 20)),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _emoji,
                  decoration: InputDecoration(
                    labelText: tr('Or type any emoji'),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _style = v.trim().isEmpty ? _style.copyWith(clearEmoji: true) : _style.copyWith(emoji: v.trim())),
                ),
              ),
              IconButton(tooltip: tr('No emoji'), icon: const Icon(Icons.clear), onPressed: () => _setEmoji(null)),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, const ItemStyle()), child: const Text('Reset')),
        FilledButton(onPressed: () => Navigator.pop(context, _style), child: const Text('Save')),
      ],
    );
  }

  /// A colour dot; the first one (null) means "no colour of its own".
  Widget _swatch(Color? color, ColorScheme scheme) {
    final selected = _style.color == color;
    return Tooltip(
      message: color == null ? 'Default color' : '',
      child: InkWell(
        key: ValueKey('swatch-${color?.toARGB32()}'),
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _style = color == null ? _style.copyWith(clearColor: true) : _style.copyWith(color: color)),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color ?? widget.base.color.withValues(alpha: 0.25),
            border: Border.all(color: selected ? scheme.primary : Colors.black12, width: selected ? 3 : 1),
          ),
          child: color == null ? const Icon(Icons.auto_awesome, size: 15) : null,
        ),
      ),
    );
  }
}
