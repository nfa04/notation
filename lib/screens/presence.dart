import 'package:flutter/material.dart' hide Text;

import '../collab/session.dart';
import '../l10n/text.dart';

/// The colour that stands for a person in a live session, the same on every device (it comes from the id of the device in the
/// session); the person themselves is not given one, so their own page is not framed.
Color presenceColor(String site) {
  var h = 0;
  for (final c in site.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 12) * 30.0 + 8, 0.7, 0.45).toColor();
}

/// Someone else in the session, the page they have in view, and which sheet of it (for a page shown as several sheets; else 0).
typedef Viewer = ({Participant who, int page, int sheet});

/// The others in [session] who have told which page they are on, by page.
List<Viewer> viewersOf(CollabSession? session) {
  if (session == null || session.state == SessionState.ended) return const [];
  final all = session.participants;
  return [
    for (final p in all)
      if (p.site != session.site && session.viewing[p.site] != null) (who: p, page: session.viewing[p.site]!,
          sheet: session.viewingSheet[p.site] ?? 0,),
  ];
}

/// One coloured border on a page: around the part [top] down and [height] tall (one sheet of a page shown as several; null: down to the
/// end of the page), with the names of [viewers] on it.
typedef PresenceRegion = ({
  List<Participant> viewers,
  double top,
  double? height,
});

/// [child] (a page) with a coloured border and a tag with the names for each of [frames].
///
/// It is the same Stack with no frame at all: the page under it is never taken out of the tree and built anew when somebody comes onto
/// it or leaves it (what is in it would lose its state - the focus of the text being written, what is built of a long document).
class PresenceFrame extends StatelessWidget {
  final List<PresenceRegion> frames;
  final List<Participant> everyone;
  final Widget child;

  /// Space at the bottom of [child] that is not the page (the gap to the next one): a frame with no height stays off it.
  final double bottomGap;

  const PresenceFrame({super.key, required this.frames, required this.everyone, required this.child, this.bottomGap = 0});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      child,
        for (final f in frames)
          if (f.viewers.isNotEmpty) ...[
      Positioned(
        left: 0,
        right: 0,
        top: f.top,
              height: f.height,
        bottom: f.height == null ? bottomGap : null,
        child: IgnorePointer(child: DecoratedBox(key: const ValueKey('presence-frame'), decoration: BoxDecoration(border: Border.all(color: presenceColor(f.viewers.first.site), width: 4,)))),
      ),
      Positioned(
        top: f.top,
        right: 0,
        child: IgnorePointer(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final v in f. viewers)
              Container(
                margin: const EdgeInsets.only(left: 2),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                color: presenceColor(v.site),
                child: Text.verbatim(Participant.labelOf(v, everyone), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
      ),
    ]
      ],);
  }
}
