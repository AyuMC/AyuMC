import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/navigation/navigation_cubit.dart';
import '../../../../core/navigation/navigation_state.dart';
import '../../../../core/widgets/app_navigation_bar.dart';
import '../builders/page_content_builder.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const AppNavigationBar(),
          Expanded(
            child: BlocBuilder<NavigationCubit, NavigationState>(
              builder: (context, state) {
                return PageContentBuilder.build(state.selectedTab);
              },
            ),
          ),
        ],
      ),
    );
  }
}
