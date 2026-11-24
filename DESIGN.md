# The paper look

Ink on paper: flat, hairlines, light type, quiet. It is `lib/style/paper_look.dart` (the theme layer), `lib/style/paper_tokens.dart`
(the measures) and `lib/widgets/paper.dart` (section, panel, row, page header). Screens say what a thing is and take the look from
those; they do not style themselves.

## Rules

- **Colour.** White page (dark: near-black), ink, one muted grey, one hairline grey. The accent the person chose marks the one thing
  that is current or actionable (a link, a switch's thumb, the selected colour), nothing else. No tinted boxes.
- **Surfaces.** No shadow and no elevation. A card that stands alone (a notice, a call to act) is a hairline box; a card that is a row of a list uses `ruledCardShape` (a hairline under it). A panel has a hairline above and below. A
  note page keeps its own frame and a faint shadow, because it is a page.
- **Type.** Inter. Large titles Light (300), body Regular (400), labels Medium (500) and small. Section names are small, muted and
  letter-spaced, never bold. Figures are tabular. Use the text theme, not a size typed in.
- **Icons.** Material Symbols (`Symbols.x`, never `Icons.x`), weight 300, no fill; the selected state of a tool uses `fill: 1`. A
  big icon is never a decoration; an empty state is one line of muted text.
- **Motion.** No ripple: a pale grey on hover and press. No page turn, no bounce.
- **Messages.** A snackbar is a flat, hairlined line. Say it in the place it happened where you can.
- **Space.** Gaps come from `Paper` (4, 8, 16, 24); the side margin is 16 on a phone and 24 elsewhere. Corners are 6 (fields,
  buttons) or 8 (pages, menus), never a pill.
- **One layout.** Phone, tablet and desktop differ in how many columns they show, not in what they look like.

## Guard

`test/paper_look_rules_test.dart` fails when `Icons.` comes back into `lib/`, and checks the theme (no splash, thin icons, ruled cards).
