import 'package:flutter/material.dart';
import '../../../../core/navigation/navigation_state.dart';
import '../../../console/data/repositories/log_repository_impl.dart';
import '../../../console/presentation/pages/console_page.dart';
import '../../../logs/presentation/pages/logs_page.dart';
import '../../../performance/presentation/pages/performance_page.dart';
import '../../../players/presentation/pages/players_page.dart';
import '../../../server_control/presentation/pages/server_control_page.dart';
import '../../../settings/presentation/pages/settings_page.dart';

class PageContentBuilder {
  PageContentBuilder._();

  static Widget build(NavigationTab tab) {
    switch (tab) {
      case NavigationTab.control:
        return const ServerControlPage();
      case NavigationTab.logs:
        return const LogsPage();
      case NavigationTab.console:
        return ConsolePage(logRepository: LogRepositoryImpl());
      case NavigationTab.performance:
        return const PerformancePage();
      case NavigationTab.players:
        return const PlayersPage();
      case NavigationTab.settings:
        return const SettingsPage();
    }
  }
}
