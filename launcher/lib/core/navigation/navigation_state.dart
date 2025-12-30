import 'package:equatable/equatable.dart';

class NavigationState extends Equatable {
  final NavigationTab selectedTab;

  const NavigationState({required this.selectedTab});

  const NavigationState.initial() : selectedTab = NavigationTab.control;

  NavigationState copyWith({NavigationTab? selectedTab}) {
    return NavigationState(selectedTab: selectedTab ?? this.selectedTab);
  }

  @override
  List<Object> get props => [selectedTab];
}

enum NavigationTab { control, logs, console, performance, players, settings }
