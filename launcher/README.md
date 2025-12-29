# AyuMC Launcher

Graphical user interface (GUI) launcher for AyuMC Minecraft Server built with Flutter Desktop.

## Features

- **Server Control**: Start, Stop, and Restart server
- **Status Monitoring**: Real-time server status display
- **Log Viewer**: View server logs in real-time
- **Settings**: Configure server settings
- **Modern UI**: Beautiful and intuitive interface

## Structure

```
launcher/
├── lib/
│   ├── main.dart                    # Entry point
│   ├── app.dart                     # Main app widget
│   ├── screens/                     # Screen widgets
│   │   ├── home_screen.dart         # Main screen
│   │   ├── settings_screen.dart     # Settings screen
│   │   └── logs_screen.dart         # Logs viewer
│   ├── widgets/                     # Reusable widgets
│   │   ├── server_status_widget.dart
│   │   ├── server_controls_widget.dart
│   │   └── log_viewer_widget.dart
│   ├── services/                    # Business logic
│   │   ├── server_service.dart      # Server management
│   │   └── log_service.dart         # Log reading
│   ├── models/                      # Data models
│   │   └── server_state.dart
│   └── utils/                       # Utilities
│       ├── constants.dart
│       └── theme.dart
└── pubspec.yaml
```

## Running the Launcher

```bash
cd launcher
flutter pub get
flutter run -d windows  # For Windows
flutter run -d macos    # For macOS
flutter run -d linux    # For Linux
```

## Development

The launcher is built with Flutter Desktop and provides a complete GUI for managing the AyuMC server. All server operations must be performed through this launcher.

