import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';

import '../l10n/language.dart';
import '../l10n/text.dart';

/// Shows the pages of a note one at a time, as large as the screen allows, to present them: arrow keys, space, a tap on the right
/// or left of the screen or a swipe turn the page; L turns the laser pointer on (it follows the mouse, or a finger that is held down);
/// B blacks the screen out; Escape leaves. The bar on top and the page number go away when nothing moves.
class PresentationView extends StatefulWidget {
  final int pageCount;

  /// The size of page [index] in the units [pageBuilder] draws it in.
  final Size Function(int index) pageSize;

  /// Page [index], as large as [pageSize] says. It is shown as it is, and does not react to the pointer.
  final Widget Function(BuildContext context, int index) pageBuilder;

  /// The page (zero-based) to start with.
  final int initialPage;

  /// Called when the page shown changes (zero-based).
  final ValueChanged<int>? onPageChanged;

  /// Called when the person leaves.
  final VoidCallback onClose;

  /// How long the controls stay after the last movement.
  final Duration hideAfter;

  /// A flipbook: the pages are shown one after the other, [fps] to a second, round and round, as the frames of an animation. (The
  /// other keys and the laser stay, and the bar has a button to play and stop, and one for the speed.)
  final bool flipbook;
  final int fps;

  const PresentationView({
    super.key,
    required this.pageCount,
    required this.pageSize,
    required this.pageBuilder,
    this.initialPage = 0,
    required this.onClose,
    this.onPageChanged,
    this.hideAfter = const Duration(seconds: 3),
    this.flipbook = false,
    this.fps = 8,
  });

  @override
  State<PresentationView> createState() => _PresentationViewState();
}

class _PresentationViewState extends State<PresentationView> {
  late final PageController _pages = PageController(initialPage: widget.initialPage.clamp(0, widget.pageCount - 1));
  late int _page = widget.initialPage.clamp(0, widget.pageCount - 1);
  final _focus = FocusNode();
  final _clock = Stopwatch()..start();
  Timer? _hide, _tick, _laserIdle;
  bool _controls = true;
  bool _blackout = false;
  bool _laser = false;
  Offset? _laserAt;
  Timer? _play;
  late bool _playing = widget.flipbook;
  late int _fps = widget.fps.clamp(1, 30);

  /// The speeds the bar offers (frames a second).
  static const speeds = [2, 4, 8, 12, 24];

  /// Runs the frames (or stops them): the next page at each beat, the first after the last.
  void _startPlaying() {
    _play?.cancel();
    if (!_playing || widget.pageCount < 2) return;
    _play = Timer.periodic(Duration(microseconds: 1000000 ~/ _fps), (_) {
      if (mounted && !_pages.position.isScrollingNotifier.value) _pages.jumpToPage((_page + 1) % widget.pageCount);
    });
  }

  @override
  void initState() {
    super.initState();
    _startPlaying();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _controls) setState(() {});
    });
    _wake();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _tick?.cancel();
    _play?.cancel();
    _laserIdle?.cancel();
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _wake() {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    _hide = Timer(widget.hideAfter, () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _go(int to) {
    final target = to.clamp(0, widget.pageCount - 1);
    if (target == _page) return;
    _pages.animateToPage(target, duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      _go(_page + 1);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.backspace) {
      _go(_page - 1);
    } else if (k == LogicalKeyboardKey.home) {
      _go(0);
    } else if (k == LogicalKeyboardKey.end) {
      _go(widget.pageCount - 1);
    } else if (k == LogicalKeyboardKey.keyL) {
      _toggleLaser();
    } else if (k == LogicalKeyboardKey.keyB || k == LogicalKeyboardKey.period) {
      setState(() => _blackout = !_blackout);
    } else if (k == LogicalKeyboardKey.escape) {
      widget.onClose();
    } else {
      return KeyEventResult.ignored;
    }
    _wake();
    return KeyEventResult.handled;
  }

  void _toggleLaser() => setState(() {
        _laser = !_laser;
        _laserAt = null;
      });

  void _pointer(PointerEvent e) {
    _wake();
    if (!_laser) return;
    // a mouse shows the laser by moving over the page; a finger or pen by being held down on it
    final shows = e.kind == PointerDeviceKind.mouse ? true : e is! PointerUpEvent && e is! PointerCancelEvent;
    setState(() => _laserAt = shows ? e.localPosition : null);
    _laserIdle?.cancel();
    _laserIdle = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _laserAt = null);
    });
  }

  static String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, box) => Listener(
            onPointerHover: _pointer,
            onPointerMove: _pointer,
            onPointerDown: _pointer,
            onPointerUp: _pointer,
            child: Stack(children: [
              Positioned.fill(
                child: PageView.builder(
                  key: const ValueKey('presentation-pages'),
                  controller: _pages,
                  // while the laser is on a drag is the laser, not a swipe
                  physics: _laser ? const NeverScrollableScrollPhysics() : null,
                  itemCount: widget.pageCount,
                  onPageChanged: (i) {
                    setState(() => _page = i);
                    widget.onPageChanged?.call(i);
                  },
                  itemBuilder: (context, i) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // a tap on the left third goes back, anywhere else on
                    onTapUp: _laser ? null : (d) => _go(d.localPosition.dx < box.maxWidth / 3 ? _page - 1 : _page + 1),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox.fromSize(
                            size: widget.pageSize(i),
                            child: IgnorePointer(child: ColoredBox(color: Colors.white, child: widget.pageBuilder(context, i))),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_laserAt != null) Positioned.fill(child: IgnorePointer(child: CustomPaint(key: const ValueKey('presentation-laser'), painter: _LaserPainter(_laserAt!)))),
              if (_blackout) Positioned.fill(child: GestureDetector(key: const ValueKey('presentation-blackout'), onTap: () => setState(() => _blackout = false), child: const ColoredBox(color: Colors.black))),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _controls ? 1 : 0,
                  child: IgnorePointer(ignoring: !_controls, child: _bar(context)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    const white = Colors.white;
    return Container(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)])),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      child: IconTheme(
        data: const IconThemeData(color: white),
        child: Row(children: [
          IconButton(key: const ValueKey('presentation-close'), tooltip: tr('Leave the presentation'), icon: const Icon(Icons.close), onPressed: widget.onClose),
          const Spacer(),
          Text.verbatim(tr('Page {n} of {total}', {'n': _page + 1, 'total': widget.pageCount}), key: const ValueKey('presentation-page'), style: const TextStyle(color: white)),
          const SizedBox(width: 12),
          Text.verbatim(_time(_clock.elapsed), key: const ValueKey('presentation-clock'), style: const TextStyle(color: white, fontFeatures: [FontFeature.tabularFigures()])),
          const Spacer(),
          if (widget.flipbook) ...[
            IconButton(
              key: const ValueKey('flipbook-play'),
              tooltip: tr(_playing ? 'Stop' : 'Play'),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => setState(() {
                _playing = !_playing;
                _startPlaying();
              }),
            ),
            PopupMenuButton<int>(
              key: const ValueKey('flipbook-speed'),
              tooltip: tr('Speed'),
              initialValue: _fps,
              onSelected: (v) => setState(() {
                _fps = v;
                _startPlaying();
              }),
              itemBuilder: (_) => [for (final v in speeds) PopupMenuItem(key: ValueKey('flipbook-fps-$v'), value: v, child: Text.verbatim(tr('{n} frames a second', {'n': v})))],
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text.verbatim('$_fps / s', style: const TextStyle(color: white))),
            ),
          ],
          IconButton(key: const ValueKey('presentation-previous'), tooltip: tr('Previous page'), icon: const Icon(Icons.chevron_left), onPressed: _page > 0 ? () => _go(_page - 1) : null),
          IconButton(key: const ValueKey('presentation-next'), tooltip: tr('Next page'), icon: const Icon(Icons.chevron_right), onPressed: _page < widget.pageCount - 1 ? () => _go(_page + 1) : null),
          IconButton(key: const ValueKey('presentation-laser-toggle'), tooltip: tr('Laser pointer (L)'), icon: Icon(Icons.adjust, color: _laser ? Colors.redAccent : white), onPressed: _toggleLaser),
          IconButton(key: const ValueKey('presentation-blackout-toggle'), tooltip: tr('Black screen (B)'), icon: const Icon(Icons.brightness_1_outlined), onPressed: () => setState(() => _blackout = !_blackout)),
        ]),
      ),
    );
  }
}

class _LaserPainter extends CustomPainter {
  final Offset at;
  _LaserPainter(this.at);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(at, 18, Paint()..color = const Color(0x44FF1744)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawCircle(at, 7, Paint()..color = const Color(0xFFFF1744));
    canvas.drawCircle(at, 2.5, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(_LaserPainter old) => old.at != at;
}
