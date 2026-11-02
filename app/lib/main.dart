import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/ytdlp.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light.copyWith(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: AppColors.bg,
  ));
  runApp(const DuetApp());
  // Android: unpack Python/yt-dlp and keep yt-dlp current, in the background.
  YtDlp.updateInBackground();
}

class DuetApp extends StatelessWidget {
  const DuetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DuetPlus',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
