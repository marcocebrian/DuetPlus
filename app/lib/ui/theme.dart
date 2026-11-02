import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF07070D);
  static const surface = Color(0xFF12121C);
  static const surface2 = Color(0xFF1B1B29);
  static const text = Color(0xFFF3F1FA);
  static const dim = Color(0xFF8E8BA3);
  static const a1 = Color(0xFFFF3D8B); // magenta
  static const a2 = Color(0xFF7B5CFF); // violet
  static const a3 = Color(0xFF22D3EE); // cyan
  static const good = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);
  static const grad = LinearGradient(colors: [a1, a2, a3]);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.a2,
      secondary: AppColors.a3,
      surface: AppColors.surface,
    ),
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      hintStyle: const TextStyle(color: AppColors.dim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: AppColors.surface, showDragHandle: true),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Big pill button with the brand gradient.
class GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool outlined;
  const GradientButton({super.key, required this.label, required this.icon, this.onTap, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: Colors.white),
      const SizedBox(width: 12),
      Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
    ]);
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: outlined ? null : AppColors.grad,
          color: outlined ? AppColors.surface2 : null,
          boxShadow: outlined
              ? null
              : [BoxShadow(color: AppColors.a2.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 8))],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(borderRadius: BorderRadius.circular(30), onTap: onTap, child: child),
        ),
      ),
    );
  }
}

class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const GradientText(this.text, {super.key, required this.style});
  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => AppColors.grad.createShader(r),
        child: Text(text, style: style.copyWith(color: Colors.white)),
      );
}
