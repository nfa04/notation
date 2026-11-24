import 'package:flutter/material.dart';

import 'platform_look.dart';

/// The bundled UI font (SIL Open Font License).
const paperFont = 'Inter';

/// The default look of the app: ink on paper. Flat bars and cards with a hairline instead of a shadow, light titles, quiet
/// grey icons, a square selection; the accent the person chose stays the accent (buttons, switches, links).
///
/// A layer over the Material theme like [iosLook] (which is put over it, so the iOS look still wins where it has an opinion), and
/// like it only about surfaces and type: no widget changes. With high contrast the colours of the scheme are left alone.
ThemeData paperLook(ThemeData base, {bool highContrast = false}) {
  final dark = base.brightness == Brightness.dark;
  var scheme = base.colorScheme;
  if (!highContrast) {
    final page = dark ? const Color(0xFF141416) : const Color(0xFFFFFFFF);
    final ink = dark ? const Color(0xFFECECEE) : const Color(0xFF1C1C1E);
    scheme = scheme.copyWith(
      surface: page,
      onSurface: ink,
      onSurfaceVariant: dark ? const Color(0xFFA0A0A6) : const Color(0xFF6B6B70),
      outlineVariant: dark ? const Color(0xFF2C2C30) : const Color(0xFFE5E5E3),
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: page,
      surfaceContainerLow: dark ? const Color(0xFF18181B) : const Color(0xFFFAFAF9),
      surfaceContainer: dark ? const Color(0xFF1A1A1D) : const Color(0xFFF7F7F5),
      surfaceContainerHigh: dark ? const Color(0xFF222226) : const Color(0xFFF1F1EF),
      surfaceContainerHighest: dark ? const Color(0xFF2A2A2E) : const Color(0xFFEAEAE7),
      // the tinted containers of Material become the pale grey of the selection; the accent itself stays for marks
      primaryContainer: dark ? const Color(0xFF26262A) : const Color(0xFFF0F0EE),
      onPrimaryContainer: ink,
      secondaryContainer: dark ? const Color(0xFF26262A) : const Color(0xFFF0F0EE),
      onSecondaryContainer: ink,
      tertiaryContainer: dark ? const Color(0xFF26262A) : const Color(0xFFF0F0EE),
      onTertiaryContainer: ink,
    );
  }
  final rule = BorderSide(color: scheme.outlineVariant);
  final r6 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final title = TextStyle(fontFamily: paperFont, color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w300, letterSpacing: 0.1);
  return base.copyWith(
    // Inter is bundled (SIL Open Font License), so the light weights look the same on every platform
    textTheme: base.textTheme.apply(fontFamily: paperFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: paperFont),
    extensions: [...base.extensions.values, const PaperLookMarker()],
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerTheme: base.dividerTheme.copyWith(color: scheme.outlineVariant, thickness: 1, space: 1),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: title,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      actionsIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      shape: Border(bottom: rule),
    ),
    cardTheme: base.cardTheme.copyWith(surfaceTintColor: Colors.transparent, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: rule)),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: rule),
      titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w400),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: const BorderRadius.vertical(top: Radius.circular(10)), side: rule)),
    popupMenuTheme: base.popupMenuTheme.copyWith(color: scheme.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: rule)),
    // the bar of the phone: flat, a hairline on top, no pill behind the chosen place (it is the ink one)
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 60,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(fontSize: 11, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w500 : FontWeight.w400, color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant)),
    ),
    // a button that floats: flat with a hairline instead of a shadow
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: scheme.onSurfaceVariant.withValues(alpha: 0.5))),
    ),
    // buttons: small square corners, no pill; chips and segments flat with a hairline and a pale selection
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: r6, elevation: 0, textStyle: const TextStyle(fontWeight: FontWeight.w500))),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: r6, elevation: 0, shadowColor: Colors.transparent, surfaceTintColor: Colors.transparent, backgroundColor: scheme.surface, foregroundColor: scheme.onSurface, side: rule)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: r6, side: BorderSide(color: scheme.outlineVariant), foregroundColor: scheme.onSurface)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: r6)),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: rule), side: rule, backgroundColor: scheme.surface, selectedColor: scheme.secondaryContainer, surfaceTintColor: Colors.transparent, elevation: 0, pressElevation: 0, labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: r6,
        side: rule,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurfaceVariant,
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSurface,
      ),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(dividerColor: scheme.outlineVariant, indicatorColor: scheme.onSurface, labelColor: scheme.onSurface, unselectedLabelColor: scheme.onSurfaceVariant),
    listTileTheme: base.listTileTheme.copyWith(selectedTileColor: scheme.onSurface.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
  );
}
