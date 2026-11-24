import 'package:flutter/material.dart' hide Text;

import '../l10n/text.dart';

/// Small building blocks of the paper look, so the screens say "a section", "a panel", "a row" instead of each styling its own.

/// The quiet label above a group: small, letter-spaced, muted.
class PaperSection extends StatelessWidget {
  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  const PaperSection(this.label, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 8)});

  /// The style of the label (for places that lay the text out themselves).
  static TextStyle style(BuildContext context) => TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 1.2, color: Theme.of(context).colorScheme.onSurfaceVariant);

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(label, style: style(context))),
          ?trailing,
        ]),
      );
}

/// A flat surface with a hairline, in place of a tinted box or a card with a shadow.
class PaperPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// A pale ground instead of the page's own (for something that sits on a page and should stand out a little).
  final bool tinted;
  final VoidCallback? onTap;
  const PaperPanel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.margin, this.tinted = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final box = Material(
      // ruled, not boxed: a hairline above and below (a pale ground with small corners when it is to stand out a little)
      color: tinted ? scheme.surfaceContainerLow : Colors.transparent,
      shape: tinted ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)) : _Ruled(BorderSide(color: scheme.outlineVariant)),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? Padding(padding: padding, child: child) : InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
    return margin == null ? box : Padding(padding: margin!, child: box);
  }
}

/// A row of a list: a hairline under it instead of a card around it.
class PaperRow extends StatelessWidget {
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool divider;
  const PaperRow({super.key, this.leading, required this.title, this.subtitle, this.trailing, this.onTap, this.selected = false, this.divider = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: scheme.outlineVariant)) : null),
      child: ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
        selected: selected,
        iconColor: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// The head of a page that is not a route of its own (an AppBar is for routes): a light title, actions at the right, a hairline.
class PageHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  const PageHeader({super.key, required this.title, this.leading, this.actions = const [], this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(64 + (bottom == null ? 0 : 48));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(children: [
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300, letterSpacing: 0.1, color: scheme.onSurface))),
                ...actions,
              ]),
            ),
          ),
          ?bottom,
        ]),
      ),
    );
  }
}


/// A shape with a line at its top and bottom edge only.
class _Ruled extends ShapeBorder {
  final BorderSide side;
  const _Ruled(this.side);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.symmetric(vertical: side.width);

  @override
  ShapeBorder scale(double t) => _Ruled(side.scale(t));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = side.toPaint();
    canvas.drawLine(rect.topLeft, rect.topRight, paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomRight, paint);
  }
}
