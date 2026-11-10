import 'package:flutter/material.dart' as m;
import 'package:flutter/material.dart' hide Text;

import '../l10n/text.dart';
import 'platform_look.dart';

/// An alert: the Material [AlertDialog], or, in the iOS look, the alert of an iPhone (a rounded sheet, the title and the message in the
/// middle, and the buttons below a hairline, side by side when there are two and one under the other when there are more).
///
/// It takes what [AlertDialog] takes at the places it is used, so that it can stand in for it. It is made of a [Dialog], not of
/// `CupertinoAlertDialog`, which has no Material above it: the forms, lists and switches that many alerts hold need one.
class PlatformAlertDialog extends StatelessWidget {
  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;
  final AlignmentGeometry? alignment;
  final EdgeInsetsGeometry? contentPadding;

  const PlatformAlertDialog({super.key, this.icon, this.title, this.content, this.actions, this.scrollable = false, this.alignment, this.contentPadding});

  @override
  Widget build(BuildContext context) {
    if (!isIosLook(context)) {
      return AlertDialog(icon: icon, title: title, content: content, actions: actions, scrollable: scrollable, alignment: alignment, contentPadding: contentPadding);
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hairline = theme.dividerTheme.color ?? scheme.outlineVariant;
    final buttons = actions ?? const <Widget>[];

    // (a text that stands alone is centred, as in an iOS alert; a form or a list is left as it is)
    bool isText(Widget? w) => w is Text || w is m.Text;
    final head = <Widget>[
      if (icon != null)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: IconTheme.merge(data: IconThemeData(size: 32, color: scheme.primary), child: Center(child: icon)),
        ),
      if (title != null)
        Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, content == null ? 20 : 4),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            textAlign: isText(title) ? TextAlign.center : null,
            child: title!,
          ),
        ),
    ];
    final message = content == null
        ? null
        : Padding(
            padding: contentPadding ?? EdgeInsets.fromLTRB(20, title == null && icon == null ? 20 : 0, 20, 20),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 13),
              textAlign: isText(content) ? TextAlign.center : null,
              child: content!,
            ),
          );

    Widget body;
    if (scrollable) {
      body = SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, ?message]));
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, if (message != null) Flexible(child: message)]);
    }

    // the buttons of an alert: plain accent text, a hairline above them and between them
    Widget row(List<Widget> items) {
      final sideBySide = items.length <= 2;
      Widget line() => sideBySide ? VerticalDivider(width: 0.5, thickness: 0.5, color: hairline) : Divider(height: 0.5, thickness: 0.5, color: hairline);
      final cells = [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) line(),
          if (sideBySide) Expanded(child: items[i]) else items[i],
        ],
      ];
      return sideBySide ? IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells)) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells);
    }

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    final plainButton = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      foregroundColor: WidgetStatePropertyAll(scheme.primary),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
    );
    return Dialog(
      alignment: alignment,
      backgroundColor: theme.dialogTheme.backgroundColor,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 270, maxWidth: 560),
        child: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Flexible(child: body),
            if (buttons.isNotEmpty) ...[
              Divider(height: 0.5, thickness: 0.5, color: hairline),
              // (a filled button in an alert is a plain one that says the same in bold)
              TextButtonTheme(
                data: TextButtonThemeData(style: plainButton),
                child: FilledButtonTheme(
                  data: FilledButtonThemeData(style: plainButton.copyWith(textStyle: WidgetStatePropertyAll(theme.textTheme.labelLarge?.copyWith(fontSize: 17, fontWeight: FontWeight.w600)))),
                  child: row(buttons),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
