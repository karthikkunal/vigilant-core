import 'dart:async';

import 'package:flutter/material.dart';

import 'home/home_shell.dart';
import 'monitors/monitor_coordinator.dart';
import 'monitors/list_clipboard.dart';
import 'monitors/monitor_service.dart';
import 'theme/vigilant-core_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const MonitorService().init();
  runApp(const vigilant-coreApp());
}

class vigilant-coreApp extends StatefulWidget {
  const vigilant-coreApp({
    super.key,
    this.coordinator,
    this.clipboard = const SystemListClipboard(),
  });

  /// Injecting a coordinator keeps widget tests and previews isolated from
  /// platform plugins.
  final MonitorCoordinator? coordinator;

  /// Injectable for the same reason: the clipboard is a platform channel, and
  /// awaiting one with no handler behind it hangs a test.
  final ListClipboard clipboard;

  @override
  State<vigilant-coreApp> createState() => _vigilant-coreAppState();
}

class _vigilant-coreAppState extends State<vigilant-coreApp> {
  late final MonitorCoordinator _coordinator =
      widget.coordinator ?? MonitorCoordinator();

  @override
  void initState() {
    super.initState();
    // Read the saved resolver choice before the first scan can run, so a scan
    // never silently falls back to a default the user did not choose.
    unawaited(_coordinator.loadResolver());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'vigilant-core',
      debugShowCheckedModeBanner: false,
      theme: buildvigilant-coreTheme(brightness: Brightness.light),
      darkTheme: buildvigilant-coreTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      themeAnimationDuration: const Duration(milliseconds: 200),
      home: HomeShell(coordinator: _coordinator, clipboard: widget.clipboard),
    );
  }
}

/// Kept as a small compatibility wrapper for callers that used the original
/// screen name.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.coordinator});

  final MonitorCoordinator? coordinator;

  @override
  Widget build(BuildContext context) => HomeShell(
    coordinator: coordinator ?? MonitorCoordinator(),
    initialDestination: HomeDestination.scan,
  );
}
