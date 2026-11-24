import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart';
import '../l10n/language.dart';

import 'markdown_formatting.dart';

/// Formatting bar for the Markdown text being edited in [controller].
class MarkdownToolbar extends StatelessWidget {
  final TextEditingController controller;

  /// Adds a "solve / differentiate / integrate" button when given.
  final VoidCallback? onSolve;

  /// Adds a "table" button when given.
  final VoidCallback? onTable;

  /// Adds a "cite a source" button when given.
  final VoidCallback? onCite;

  /// Adds a "list of sources" button when given.
  final VoidCallback? onBibliography;

  const MarkdownToolbar({super.key, required this.controller, this.onSolve, this.onTable, this.onCite, this.onBibliography});

  void _inline(String marker) => controller.value = toggleInline(controller.value, marker);
  void _line(LineStyle style) => controller.value = toggleLineStyle(controller.value, style);

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tr(tooltip),
          visualDensity: VisualDensity.compact,
          onPressed: onPressed,
        );
    const divider = SizedBox(height: 24, child: VerticalDivider(width: 16));

    // taps must not take the focus away from the text field being edited
    return ExcludeFocus(
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            // (more rows when the tools do not fit in one, in place of scrolling)
            child: Align(
              alignment: Alignment.center,
              heightFactor: 1,
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  button(Symbols.looks_one, 'Heading 1', () => _line(LineStyle.heading1)),
                  button(Symbols.looks_two, 'Heading 2', () => _line(LineStyle.heading2)),
                  button(Symbols.looks_3, 'Heading 3', () => _line(LineStyle.heading3)),
                  divider,
                  button(Symbols.format_bold, 'Bold', () => _inline('**')),
                  button(Symbols.format_italic, 'Italic', () => _inline('*')),
                  button(Symbols.format_strikethrough, 'Strikethrough', () => _inline('~~')),
                  button(Symbols.code, 'Code', () => _inline('`')),
                  divider,
                  button(Symbols.format_list_bulleted, 'Bulleted list', () => _line(LineStyle.bullet)),
                  button(Symbols.format_list_numbered, 'Numbered list', () => _line(LineStyle.numbered)),
                  if (onTable != null)
                    IconButton(
                      key: const ValueKey('table-in-text'),
                      icon: const Icon(Symbols.table_chart, size: 20),
                      tooltip: tr('Insert a table'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onTable,
                    ),
                  if (onCite != null)
                    IconButton(
                      key: const ValueKey('cite-in-text'),
                      icon: const Icon(Symbols.format_quote, size: 20),
                      tooltip: tr('Cite a source'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onCite,
                    ),
                  if (onBibliography != null)
                    IconButton(
                      key: const ValueKey('bibliography-in-text'),
                      icon: const Icon(Symbols.menu_book, size: 20),
                      tooltip: tr('Insert the list of sources'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onBibliography,
                    ),
                  if (onSolve != null) ...[
                    divider,
                    IconButton(
                      key: const ValueKey('solve-in-text'),
                      icon: const Icon(Symbols.functions, size: 20),
                      tooltip: tr('Solve, differentiate or integrate'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onSolve,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
