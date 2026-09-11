import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/library_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: EpubReaderApp()));
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({super.key});

  static const _ink = Color(0xFF282722);
  static const _paper = Color(0xFFF5F1E8);
  static const _paper2 = Color(0xFFECE7DC);
  static const _sage = Color(0xFF71816C);
  static const _darkInk = Color(0xFFE9E4D8);
  static const _darkPaper = Color(0xFF242421);
  static const _darkSurface = Color(0xFF2E2E2A);

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: dark ? const Color(0xFF9EAD98) : _sage,
      onPrimary: dark ? const Color(0xFF20251F) : Colors.white,
      primaryContainer: dark ? const Color(0xFF3A4438) : const Color(0xFFDCE4D6),
      onPrimaryContainer: dark ? _darkInk : const Color(0xFF273226),
      secondary: dark ? const Color(0xFFB6AAA0) : const Color(0xFF8D8177),
      onSecondary: dark ? const Color(0xFF292723) : Colors.white,
      secondaryContainer: dark ? const Color(0xFF3D3833) : const Color(0xFFE7DED5),
      onSecondaryContainer: dark ? _darkInk : const Color(0xFF352F2A),
      tertiary: dark ? const Color(0xFF9AA9B4) : const Color(0xFF788B95),
      onTertiary: dark ? const Color(0xFF20262A) : Colors.white,
      tertiaryContainer: dark ? const Color(0xFF354047) : const Color(0xFFDCE5E9),
      onTertiaryContainer: dark ? _darkInk : const Color(0xFF263137),
      error: const Color(0xFFA34F48),
      onError: Colors.white,
      errorContainer: dark ? const Color(0xFF4A2926) : const Color(0xFFF1D8D4),
      onErrorContainer: dark ? const Color(0xFFFFDAD5) : const Color(0xFF421B18),
      surface: dark ? _darkPaper : _paper,
      onSurface: dark ? _darkInk : _ink,
      surfaceContainerHighest: dark ? _darkSurface : _paper2,
      onSurfaceVariant: dark ? const Color(0xFFC7C1B6) : const Color(0xFF69645B),
      outline: dark ? const Color(0xFF817C72) : const Color(0xFFB7B0A5),
      outlineVariant: dark ? const Color(0xFF4A4843) : const Color(0xFFD9D3C8),
      shadow: Colors.black.withValues(alpha: .14),
      scrim: Colors.black.withValues(alpha: .38),
      inverseSurface: dark ? _paper : _darkPaper,
      onInverseSurface: dark ? _ink : _darkInk,
      inversePrimary: dark ? _sage : const Color(0xFFB7C5B0),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      fontFamily: 'sans-serif',
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 26,
          fontWeight: FontWeight.w700,
          letterSpacing: -.55,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerHighest.withValues(alpha: dark ? .72 : .68),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: .72),
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: .72),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface.withValues(alpha: .96),
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        height: 70,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant.withValues(alpha: .65),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EPUB Reader',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}
