import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

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
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20),
            label: Text(widget.label),
          ),
        ),
        if (_open) ...widget.children,
      ]);
}
