import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/navigation/navigation_cubit.dart';
import 'core/theme/app_theme.dart';
import 'features/console/data/repositories/log_repository_impl.dart';
import 'features/console/presentation/bloc/console_bloc.dart';
import 'features/console/presentation/bloc/console_event.dart';
import 'features/main/presentation/pages/main_page.dart';

void main() {
  runApp(const AyuMCLauncher());
}

class AyuMCLauncher extends StatelessWidget {
  const AyuMCLauncher({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => NavigationCubit()),
        BlocProvider(
          create: (context) =>
              ConsoleBloc(logRepository: LogRepositoryImpl())
                ..add(const ConsoleStartListening()),
        ),
      ],
      child: MaterialApp(
        title: 'AyuMC Launcher',
        theme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const MainPage(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
