import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/language.dart';

/// A line of buttons that scrolls sideways when they do not fit, and says so: where some are out of view a quiet arrow stands at
/// that edge (fading what is under it), and a tap on it brings the hidden ones in, to the right or to the left, whichever side they
/// are on. When they all fit they stay put (at the start, or in the middle with [center]).
class OverflowStrip extends StatefulWidget {
  final List<Widget> children;

  /// Whether the buttons sit in the middle of the line when there is room to spare.
  final bool center;

  /// The scrollable's key (a test or a caller that needs to scroll it).
  final Key? scrollKey;

  const OverflowStrip({super.key, required this.children, this.center = false, this.scrollKey});

  @override
  State<OverflowStrip> createState() => _OverflowStripState();
}

class _OverflowStripState extends State<OverflowStrip> {
  final _controller = ScrollController();
  bool _more = false; // something hidden to the right
  bool _less = false; // something hidden to the left

  @override
  void initState() {
    super.initState();
    _controller.addListener(_look);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Looks at where the buttons end up: the arrows follow it.
  void _look() {
    if (!_controller.hasClients || !_controller.position.hasContentDimensions) return;
    final p = _controller.position;
    final less = p.pixels > 1;
    final more = p.pixels < p.maxScrollExtent - 1;
    if (less != _less || more != _more) {
      setState(() {
        _less = less;
        _more = more;
      });
    }
  }

  void _go(int direction) {
    final p = _controller.position;
    final step = math.max(80.0, p.viewportDimension * 0.7) * direction;
    _controller.animateTo((p.pixels + step).clamp(0.0, p.maxScrollExtent), duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Widget _arrow(BuildContext context, {required bool left}) {
    final ground = Theme.of(context).scaffoldBackgroundColor;
    final fade = LinearGradient(begin: left ? Alignment.centerLeft : Alignment.centerRight, end: left ? Alignment.centerRight : Alignment.centerLeft, colors: [ground, ground.withValues(alpha: 0)], stops: const [0.55, 1]);
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: fade),
        child: Align(
          widthFactor: 1,
          child: IconButton(
            key: ValueKey(left ? 'strip-less' : 'strip-more'),
            tooltip: tr(left ? 'More tools to the left' : 'More tools to the right'),
            visualDensity: VisualDensity.compact,
            icon: Icon(left ? Symbols.chevron_left : Symbols.chevron_right, size: 22),
            onPressed: () => _go(left ? -1 : 1),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          // (the size of the buttons or of the line changed: look again once it is laid out)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _look();
          });
          return false;
        },
        child: Stack(children: [
          SingleChildScrollView(
            key: widget.scrollKey,
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: widget.center ? MainAxisAlignment.center : MainAxisAlignment.start, children: widget.children),
            ),
          ),
          if (_less) _arrow(context, left: true),
          if (_more) _arrow(context, left: false),
        ]),
      ),
    );
  }
}
