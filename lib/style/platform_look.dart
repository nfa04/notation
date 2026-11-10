import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Which system the app is dressed like: the one it runs on, always Material, or always an iPhone app.
///
/// The iOS look is a layer over the Material widgets (their theme and [ThemeData.platform]), not a second set of screens:
/// every screen has it at once, and it can be switched on anywhere, so it can be looked at on a computer.
enum PlatformLook {
  automatic,
  material,
  ios;

  static PlatformLook fromName(String? name) => values.firstWhere((l) => l.name == name, orElse: () => automatic);

  /// Whether this is the iOS look right now ([automatic] is iOS on an iPhone or iPad, and nowhere else).
  bool get isIos => switch (this) {
        ios => true,
        material => false,
        automatic => defaultTargetPlatform == TargetPlatform.iOS,
      };
}

/// Marks a theme as the iOS look, for the widgets that have a shape of their own there (see `PlatformAlertDialog`): the platform of the
/// theme cannot tell, since an iPhone with the Material look has it too.
class IosLookMarker extends ThemeExtension<IosLookMarker> {
  const IosLookMarker();

  @override
  IosLookMarker copyWith() => this;

  @override
  IosLookMarker lerp(IosLookMarker? other, double t) => this;
}

/// Whether the theme above [context] is the iOS look.
bool isIosLook(BuildContext context) => Theme.of(context).extension<IosLookMarker>() != null;

/// The ground of a bar of tools (the side bar of the drawing tools, the bar at the foot of the page): the grey of the bars of iOS,
/// or the tinted surface of Material.
Color toolBarColor(BuildContext context) {
  final theme = Theme.of(context);
  return isIosLook(context) ? (theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface) : theme.colorScheme.surfaceContainerLow;
}

/// How high a bar of tools floats: [material] in the Material look, flat in the iOS one (which has a hairline instead, see [toolBarEdge]).
double toolBarElevation(BuildContext context, double material) => isIosLook(context) ? 0 : material;

/// The hairline on the side of a bar that faces the page, in the iOS look; null in the Material one.
Border? toolBarEdge(BuildContext context, {bool top = false, bool left = false}) {
  if (!isIosLook(context)) return null;
  final line = BorderSide(color: Theme.of(context).dividerTheme.color ?? Theme.of(context).dividerColor, width: 0.5);
  return Border(top: top ? line : BorderSide.none, left: left ? line : BorderSide.none);
}

/// The look of a tool that is switched on or off (the eraser, the highlighter): in the iOS look the one that is on has a pale accent
/// square behind it and the others nothing; null (the button's own style) in the Material look, where the tonal disc says it.
ButtonStyle? toggleToolStyle(BuildContext context) {
  if (!isIosLook(context)) return null;
  final accent = Theme.of(context).colorScheme.primary;
  return ButtonStyle(backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accent.withValues(alpha: 0.14) : Colors.transparent));
}

/// [base] dressed the way an iPhone app is: the iOS font, the swipe-back page transition, the bouncing scroll and the iOS text
/// selection (all of them follow [ThemeData.platform]), a flat bar on top with a hairline under it, grey cards without a shadow,
/// round dialogs, sheets and menus, no ripple, and a tab bar without the pill behind the selected tab.
///
/// The colours of the scheme (the accent the person picked) are kept; only the surfaces around them change.
/// The widgets that have an iOS version of their own (the switch, the slider, the check box, the spinner) are made with
/// their `.adaptive` constructors where they are used, since only they can change shape.
ThemeData iosLook(ThemeData base) {
  final scheme = base.colorScheme;
  final dark = base.brightness == Brightness.dark;
  // the system colours of iOS: the background, the grey of what sits on it, the chrome of the bars, the hairline between rows
  final background = dark ? Colors.black : Colors.white;
  final card = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
  final chrome = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
  final floating = dark ? const Color(0xFF2C2C2E) : const Color(0xFFF9F9F9);
  final hairline = dark ? const Color(0xFF38383A) : const Color(0xFFC6C6C8);
  const round = BorderRadius.all(Radius.circular(14));
  const shape10 = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10)));
  const shape12 = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)));
  final tint = IconThemeData(color: scheme.primary);
  // (the button text is made from the theme's own label style, complete (inherit: false) like the Material one: styles of another 'inherit' cannot be animated between when the look is switched)
  final label = (base.textTheme.labelLarge ?? const TextStyle()).copyWith(inherit: false);

  // text fields: a grey rounded field without a line around it (the fill is the field; an error is drawn as a thin red line)
  OutlineInputBorder field([BorderSide side = BorderSide.none]) => OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: side);
  final errorLine = BorderSide(color: scheme.error, width: 1);

  return base.copyWith(
    platform: TargetPlatform.iOS,
    extensions: [...base.extensions.values, const IosLookMarker()],
    scaffoldBackgroundColor: background,
    canvasColor: background,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: scheme.onSurface.withValues(alpha: 0.08),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: chrome,
      foregroundColor: scheme.primary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      iconTheme: tint,
      actionsIconTheme: tint,
      titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 17, fontWeight: FontWeight.w600),
      shape: Border(bottom: BorderSide(color: hairline, width: 0.5)),
    ),
    cardTheme: base.cardTheme.copyWith(
      color: card,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: floating,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: round),
      titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 17, fontWeight: FontWeight.w600),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: floating,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: floating,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: round),
    ),
    dividerTheme: base.dividerTheme.copyWith(color: hairline, thickness: 0.5),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: card,
      border: field(),
      enabledBorder: field(),
      focusedBorder: field(),
      disabledBorder: field(),
      errorBorder: field(errorLine),
      focusedErrorBorder: field(errorLine),
    ),
    // iOS has no snack bar: a short dark-grey note, its action in a pale accent
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: const Color(0xFF3A3A3C),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 15),
      actionTextColor: Color.alphaBlend(Colors.white.withValues(alpha: 0.55), scheme.primary),
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: card,
      selectedColor: scheme.primary.withValues(alpha: 0.16),
      side: BorderSide.none,
      elevation: 0,
      pressElevation: 0,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
      secondaryLabelStyle: TextStyle(color: scheme.primary, fontSize: 14),
      checkmarkColor: scheme.primary,
    ),
    textButtonTheme: TextButtonThemeData(style: _plain(label.copyWith(fontSize: 16, fontWeight: FontWeight.w400), shape: shape10)),
    // (a button with a fill: the 'filled' look of iOS, a rounded rectangle with a semibold label)
    filledButtonTheme: FilledButtonThemeData(
      style: _plain(label.copyWith(fontSize: 16, fontWeight: FontWeight.w600), shape: shape12).copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        overlayColor: _pressed(scheme.onPrimary),
      ),
    ),
    // (iOS has no outlined button: its second kind is the 'tinted' one, the accent on a pale ground)
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _plain(label.copyWith(fontSize: 16, fontWeight: FontWeight.w600), shape: shape12).copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? null : scheme.primary.withValues(alpha: 0.12)),
      ),
    ),
    // (the icons of a toolbar: the accent on nothing, a rounded square rather than a disc under the finger, and a pale accent square
    // behind a tool that is on)
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        splashFactory: NoSplash.splashFactory,
        overlayColor: _pressed(scheme.onSurface),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.3) : scheme.primary),
      ),
    ),
    // (the same tinted button as the outlined one: iOS has no raised button)
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _plain(label.copyWith(fontSize: 16, fontWeight: FontWeight.w600), shape: shape12).copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.3) : scheme.primary),
        backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? null : scheme.primary.withValues(alpha: 0.12)),
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(elevation: 2, focusElevation: 2, hoverElevation: 2, highlightElevation: 2, shape: const StadiumBorder()),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        splashFactory: NoSplash.splashFactory,
        textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 13, fontWeight: FontWeight.w500)),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
        side: const WidgetStatePropertyAll(BorderSide.none),
        // a grey track, and the chosen segment raised out of it
        backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? (dark ? const Color(0xFF636366) : Colors.white) : card),
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        overlayColor: _pressed(scheme.onSurface),
      ),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: chrome,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(fontSize: 10, color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant)),
    ),
  );
}

/// What a button shows while it is pressed: iOS has no ripple, the button only goes pale (or dark) under the finger.
WidgetStateProperty<Color?> _pressed(Color colour) => WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return colour.withValues(alpha: 0.16);
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) return colour.withValues(alpha: 0.06);
      return null;
    });

/// The style all the buttons of the iOS look share: no ripple, the pressed look of [_pressed], a [shape] and a text style.
ButtonStyle _plain(TextStyle text, {required OutlinedBorder shape}) => ButtonStyle(
      splashFactory: NoSplash.splashFactory,
      elevation: const WidgetStatePropertyAll(0),
      textStyle: WidgetStatePropertyAll(text),
      shape: WidgetStatePropertyAll(shape),
      // (the colour of the text, since a button's text and its press go together; the filled one sets its own)
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return const Color(0x29808080);
        if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) return const Color(0x0F808080);
        return null;
      }),
    );
