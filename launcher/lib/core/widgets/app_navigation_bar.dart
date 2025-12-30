import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../navigation/navigation_cubit.dart';
import '../navigation/navigation_state.dart';
import '../theme/app_colors.dart';
import 'app_logo.dart';
import 'navigation_tab_item.dart';

class AppNavigationBar extends StatelessWidget {
  const AppNavigationBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: _buildDecoration(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLogoRow(),
                const SizedBox(height: 12),
                _buildTabsRow(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  BoxDecoration _buildDecoration() {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppColors.backgroundMedium.withOpacity(0.9),
          AppColors.backgroundMedium.withOpacity(0.8),
        ],
      ),
      border: const Border(
        bottom: BorderSide(color: AppColors.borderLight, width: 1),
      ),
    );
  }

  Widget _buildLogoRow() {
    return const Row(children: [AppLogo(size: 40), Spacer()]);
  }

  Widget _buildTabsRow(BuildContext context) {
    return BlocBuilder<NavigationCubit, NavigationState>(
      builder: (context, state) {
        return Row(
          children: [
            NavigationTabItem(
              icon: Icons.dashboard,
              label: 'Control',
              isSelected: state.selectedTab == NavigationTab.control,
              onTap: () => _selectTab(context, NavigationTab.control),
            ),
            NavigationTabItem(
              icon: Icons.article,
              label: 'Logs',
              isSelected: state.selectedTab == NavigationTab.logs,
              onTap: () => _selectTab(context, NavigationTab.logs),
            ),
            NavigationTabItem(
              icon: Icons.terminal,
              label: 'Console',
              isSelected: state.selectedTab == NavigationTab.console,
              onTap: () => _selectTab(context, NavigationTab.console),
            ),
            NavigationTabItem(
              icon: Icons.speed,
              label: 'Performance',
              isSelected: state.selectedTab == NavigationTab.performance,
              onTap: () => _selectTab(context, NavigationTab.performance),
            ),
            NavigationTabItem(
              icon: Icons.people,
              label: 'Players',
              isSelected: state.selectedTab == NavigationTab.players,
              onTap: () => _selectTab(context, NavigationTab.players),
            ),
            NavigationTabItem(
              icon: Icons.settings,
              label: 'Settings',
              isSelected: state.selectedTab == NavigationTab.settings,
              onTap: () => _selectTab(context, NavigationTab.settings),
            ),
          ],
        );
      },
    );
  }

  void _selectTab(BuildContext context, NavigationTab tab) {
    context.read<NavigationCubit>().selectTab(tab);
  }
}
