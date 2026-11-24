import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

/// How things move, in one place like [Paper] is for measures: short durations, one curve in and one out, and every duration is
/// zero when the person (or the system) wants no motion. A screen takes its timing from here instead of typing milliseconds.
abstract final class Motion {
  /// A small change in place (a mark, a bar of progress, a chevron turning).
  static const Duration fast = Duration(milliseconds: 150);

  /// Something appearing, opening or changing places (a section, a pane, a card).
  static const Duration medium = Duration(milliseconds: 220);

  /// A card turning over, a whole screen arriving.
  static const Duration slow = Duration(milliseconds: 320);

  /// Things that arrive decelerate, things that leave accelerate.
  static const Curve curveIn = Curves.easeOutCubic;
  static const Curve curveOut = Curves.easeInCubic;

  /// [d] unless motion is off, then zero (an animation of zero length ends in its first frame).
  static Duration of(BuildContext context, Duration d) => MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// The transition of a screen pushed over another: it fades in while it rises a few pixels. The same on every platform that has no
/// transition of its own to keep (iOS and macOS keep the swipe-back slide); [Motion.slow] is the length of the route itself.
class PaperPageTransitions extends PageTransitionsBuilder {
  const PaperPageTransitions();

  @override
  Duration get transitionDuration => Motion.medium;

  @override
  Duration get reverseTransitionDuration => Motion.fast;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.curveIn, reverseCurve: Motion.curveOut);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved), child: child),
    );
  }
}

/// The transitions of the paper look: ours where Material would slide the whole page, Cupertino's where the platform has a back swipe.
const paperPageTransitions = PageTransitionsTheme(builders: {
  TargetPlatform.android: PaperPageTransitions(),
  TargetPlatform.linux: PaperPageTransitions(),
  TargetPlatform.windows: PaperPageTransitions(),
  TargetPlatform.fuchsia: PaperPageTransitions(),
  TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
});

/// A part of a page that opens and closes: it grows to its height (and fades in) instead of appearing, and shrinks away before it is
/// taken out of the tree. [child] is only built while it is open or on its way out.
class Reveal extends StatefulWidget {
  final bool open;
  final Widget child;

  const Reveal({super.key, required this.open, required this.child});

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.medium, value: widget.open ? 1 : 0);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: Motion.curveIn, reverseCurve: Motion.curveOut);

  @override
  void didUpdateWidget(Reveal old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    _c.duration = Motion.of(context, Motion.medium);
    widget.open ? _c.forward() : _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) => _c.isDismissed
            ? const SizedBox(width: double.infinity)
            : ClipRect(child: SizeTransition(sizeFactor: _curve, alignment: Alignment.topCenter, child: FadeTransition(opacity: _curve, child: child))),
        child: widget.child,
      );
}

/// Fades its child in whenever [token] changes (and when it first appears): a pane that shows another tab does not cut to it. The
/// child stays where it is in the tree, so its state (and anything keyed inside it) is not touched.
class FadeOnChange extends StatefulWidget {
  final Object token;
  final Widget child;

  const FadeOnChange({super.key, required this.token, required this.child});

  @override
  State<FadeOnChange> createState() => _FadeOnChangeState();
}

class _FadeOnChangeState extends State<FadeOnChange> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.medium);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: Motion.curveIn);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _c.duration = Motion.of(context, Motion.medium);
    _c.forward();
  }

  @override
  void didUpdateWidget(FadeOnChange old) {
    super.didUpdateWidget(old);
    if (widget.token == old.token) return;
    _c.duration = Motion.of(context, Motion.medium);
    _c.forward(from: 0.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: Tween(begin: 0.0, end: 1.0).animate(_curve), child: RepaintBoundary(child: widget.child));
}
