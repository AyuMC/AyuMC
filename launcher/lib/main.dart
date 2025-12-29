import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'features/server_control/presentation/pages/server_control_page.dart';

void main() {
  runApp(const AyuMCLauncher());
}

class AyuMCLauncher extends StatelessWidget {
  const AyuMCLauncher({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AyuMC Launcher',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const ServerControlPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
