import 'dart:async';

import 'package:flutter/material.dart';

import '../discovery/domain_scan_screen.dart';
import '../monitors/list_clipboard.dart';
import '../monitors/add_monitor_screen.dart';
import '../monitors/monitor_coordinator.dart';
import '../monitors/monitors_screen.dart';
import '../settings/settings_screen.dart';

enum HomeDestination { monitors, scan, settings }

/// The application shell keeps navigation stable while each destination keeps
/// its own local state (for example, an in-progress scan or filter selection).
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.coordinator,
    this.initialDestination = HomeDestination.monitors,
    this.clipboard = const SystemListClipboard(),
  });

  final MonitorCoordinator coordinator;
  final HomeDestination initialDestination;
  final ListClipboard clipboard;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late HomeDestination _destination;
  int _monitorRevision = 0;

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
    unawaited(widget.coordinator.refreshReminders().catchError((Object _) {}));
    // The service restarts on boot without asking, so the stored pause has to be
    // re-applied here — otherwise turning monitoring off would only last until
    // the next reboot.
    unawaited(
      widget.coordinator.syncMonitoringPreference().catchError((Object _) {}),
    );
  }

  Future<void> _openAddMonitor() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AddMonitorScreen(coordinator: widget.coordinator),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showMonitors() {
    if (!mounted) return;
    setState(() {
      _destination = HomeDestination.monitors;
      _monitorRevision++;
    });
  }

  void _select(HomeDestination destination) {
    if (_destination == destination) return;
    setState(() => _destination = destination);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _destination == HomeDestination.monitors,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _destination != HomeDestination.monitors) {
          setState(() => _destination = HomeDestination.monitors);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _destination.index,
          children: [
            TickerMode(
              enabled: _destination == HomeDestination.monitors,
              child: MonitorsScreen(
                key: ValueKey(_monitorRevision),
                coordinator: widget.coordinator,
                onAddMonitor: _openAddMonitor,
                onOpenSettings: () => _select(HomeDestination.settings),
              ),
            ),
            TickerMode(
              enabled: _destination == HomeDestination.scan,
              child: DomainScanScreen(
                coordinator: widget.coordinator,
                onWatched: _showMonitors,
              ),
            ),
            TickerMode(
              enabled: _destination == HomeDestination.settings,
              child: SettingsScreen(
                coordinator: widget.coordinator,
                clipboard: widget.clipboard,
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _destination.index,
          onDestinationSelected: (index) =>
              _select(HomeDestination.values[index]),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.sensors_outlined),
              selectedIcon: Icon(Icons.sensors_rounded),
              label: 'Monitors',
            ),
            NavigationDestination(
              icon: Icon(Icons.travel_explore_outlined),
              selectedIcon: Icon(Icons.travel_explore_rounded),
              label: 'Scan',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
