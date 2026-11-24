import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import '../style/motion.dart';

/// Settings that most people never need, kept behind one "Advanced" button so that the page stays short.
/// Opens by itself when [initiallyOpen] (something in it is not at its default, say).
class AdvancedSection extends StatefulWidget {
  final List<Widget> children;
  final String label;
  final bool initiallyOpen;

  const AdvancedSection({super.key, required this.children, this.label = 'Advanced', this.initiallyOpen = false});

  @override
  State<AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<AdvancedSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('advanced-${widget.label}'),
            onPressed: () => setState(() => _open = !_open),
            icon: AnimatedRotation(turns: _open ? 0.5 : 0, duration: Motion.of(context, Motion.fast), child: const Icon(Symbols.expand_more, size: 20)),
            label: Text(widget.label),
          ),
        ),
        Reveal(open: _open, child: Smooth(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.children))),
      ]);
}
