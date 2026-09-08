import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:dbus/dbus.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';
import 'dart:async';
import '../dbus/ipc-ruler.dart';
import '../widgets/base_scaffold.dart';
import 'config_edit.dart';

/// A map from typeId -> string. Matches the Rust backend's impl_type_identifier.
const Map<int, String> _typeLabels = {
  1: 'bool',
  2: 'i64',
  3: 'u64',
  4: 'f64',
  5: 'string',
  6: 'json',
  7: 'mass',
};

class ConnectionsPage extends StatelessWidget {
  final DBusClient dbusClient;

  ConnectionsPage({Key? key, required this.dbusClient}) : super(key: key);

  Future<IpcRulerClient> _connectClient() async {
    try {
      return await IpcRulerClient.create(dbusClient);
    } catch (e) {
      debugPrint('Failed to connect to IpcRulerClient: $e');
      throw e;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IpcRulerClient>(
      future: _connectClient(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return BaseScaffold(
            title: 'Signals & Slots',
            body: Center(child: Text('Failed to connect to IPC service')),
          );
        }

        if (!snapshot.hasData) {
          return BaseScaffold(
            title: 'Signals & Slots',
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return _ConnectionsPageContent(
          client: snapshot.data!,
          dbusClient: dbusClient,
        );
      },
    );
  }
}

class _ConnectionsPageContent extends StatefulWidget {
  final IpcRulerClient client;
  final DBusClient dbusClient;

  const _ConnectionsPageContent({
    Key? key,
    required this.client,
    required this.dbusClient,
  }) : super(key: key);

  @override
  State<_ConnectionsPageContent> createState() =>
      _ConnectionsPageContentState();
}

class _ConnectionsPageContentState extends State<_ConnectionsPageContent> {
  final TextEditingController _searchController = TextEditingController();

  /// Full list of signals and slots from the server
  List<SignalInfo> _allSignals = [];
  List<SlotInfo> _allSlots = [];

  /// Filtered lists to display
  List<SignalInfo> _filteredSignals = [];

  /// For the type dropdown filter:
  /// We'll store a negative or null for "All types".
  int? _selectedType;

  bool _isLoading = false;

  late StreamSubscription<ConnectionChangeEvent> _connectionChangesSub;

  @override
  void initState() {
    super.initState();
    _loadData();

    // Listen to any connection changes from the DBus signal
    _connectionChangesSub = widget.client.connectionChanges.listen((event) {
      debugPrint(
          'Connection change event: ${event.slotName} -> ${event.signalName}');
      // Re-fetch data so the UI is up-to-date
      _loadData();
    });

    // Listen for search text changes
    _searchController.addListener(_applyFilters);
  }

  @override
  void dispose() {
    _connectionChangesSub.cancel();
    _searchController.removeListener(_applyFilters);
    _searchController.dispose();
    super.dispose();
  }

  /// Fetch signals and slots from DBus
  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final signals = await widget.client.getSignals();
      final slots = await widget.client.getSlots();
      setState(() {
        _allSignals = signals;
        _allSlots = slots;
      });
      _applyFilters();
    } catch (e) {
      debugPrint('Error loading data: $e');
    }

    setState(() => _isLoading = false);
  }

  /// Apply the search + type filter to produce _filteredSignals
  void _applyFilters() {
    final query = _searchController.text.trim().toLowerCase();

    // A signal is kept when it — or any of its connected slots (each slot is
    // displayed only under its signal, so a matching slot must keep its
    // signal visible) — matches the search; the type filter always applies.
    // The best match anywhere on the row decides its rank.
    final scored = <(int, SignalInfo)>[];
    for (final sig in _allSignals) {
      if (_selectedType != null && sig.sigType != _selectedType) continue;
      if (query.isEmpty) {
        scored.add((0, sig));
        continue;
      }
      int? best = fuzzyScoreFields(
          [sig.name.toLowerCase(), sig.description.toLowerCase()], query);
      for (final slot in _allSlots) {
        if (slot.connectedTo != sig.name) continue;
        if (_selectedType != null && slot.slotType != _selectedType) continue;
        final s = fuzzyScoreFields(
            [slot.name.toLowerCase(), slot.description.toLowerCase()], query);
        if (s != null && (best == null || s > best)) best = s;
      }
      if (best != null) scored.add((best, sig));
    }

    setState(() => _filteredSignals = rankedItems(scored));
  }

  /// Called when user taps “Disconnect” on a sub-slot
  Future<void> _disconnectSlot(String slotName) async {
    try {
      await widget.client.disconnect(slotName);
      await _loadData();
    } catch (e) {
      debugPrint('Error disconnecting slot "$slotName": $e');
    }
  }

  /// Show a dialog allowing user to pick multiple slots of the same type
  /// that are NOT yet connected, then connect them.
  void _showAddSlotDialog(SignalInfo signal) {
    showDialog(
      context: context,
      builder: (_) => AddSlotDialog(
        client: widget.client,
        signal: signal,
        allSlots: _allSlots,
        onRefresh: () => _loadData(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final typeDropdownItems = <DropdownMenuItem<int?>>[
      DropdownMenuItem(
        value: null,
        child: Text('All Types'),
      ),
      // Provide an item for each known type
      ..._typeLabels.entries.map(
        (e) => DropdownMenuItem(
          value: e.key,
          child: Text(e.value),
        ),
      ),
    ];

    return BaseScaffold(
      title: 'Signals & Slots',
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Search + Type Filter
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: 'Search signals or slots...',
                      suffixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      Text('Type: '),
                      SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<int?>(
                          isExpanded: true,
                          value: _selectedType,
                          items: typeDropdownItems,
                          onChanged: (value) {
                            setState(() {
                              _selectedType = value;
                              _applyFilters();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filteredSignals.length,
                    itemBuilder: (context, index) {
                      final signal = _filteredSignals[index];

                      // Gather connected slots
                      final connectedSlots = _allSlots
                          .where((slot) => slot.connectedTo == signal.name)
                          .toList();

                      return Card(
                        child: ExpansionTile(
                          leading: Icon(
                            Icons.radio_button_checked,
                            color: connectedSlots.isNotEmpty
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).unselectedWidgetColor,
                          ),
                          trailing: Icon(Icons.expand_more),
                          backgroundColor: Colors.transparent,
                          collapsedBackgroundColor: Colors.transparent,
                          title: Text(signal.name),
                          subtitle: Text(
                            'Type: ${_typeLabels[signal.sigType] ?? signal.sigType}\n'
                            '${signal.description}',
                          ),
                          children: [
                            // Connected Slots
                            if (connectedSlots.isNotEmpty)
                              ...connectedSlots.map((slot) {
                                // Create config path from slot name
                                final configPath =
                                    '/is/centroid/Config/filters/${slot.name.split('.').sublist(2).join('/')}';

                                return ListTile(
                                  dense: true,
                                  leading: Icon(Icons.input),
                                  title: Text(slot.name),
                                  subtitle: Text(
                                    'Type: ${_typeLabels[slot.slotType] ?? slot.slotType}\n'
                                    '${slot.description}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Config button
                                      if (slot.createdBy.isNotEmpty)
                                        IconButton(
                                          icon: Icon(Icons.settings),
                                          tooltip: 'Configure',
                                          onPressed: () {
                                            showDialog(
                                              context: context,
                                              builder: (_) => ConfigEditDialog(
                                                dbusClient: widget.dbusClient,
                                                serviceName: slot.createdBy,
                                                objectPath: configPath,
                                              ),
                                            );
                                          },
                                        ),
                                      // Disconnect button
                                      IconButton(
                                        icon: Icon(Icons.link_off),
                                        tooltip: 'Disconnect',
                                        onPressed: () =>
                                            _disconnectSlot(slot.name),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            // Connect new slot(s)
                            ListTile(
                              dense: true,
                              title: Text('Connect new slot(s) to this signal'),
                              trailing: IconButton(
                                icon: Icon(Icons.add),
                                onPressed: () => _showAddSlotDialog(signal),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class AddSlotDialog extends StatefulWidget {
  final IpcRulerClient client;
  final SignalInfo signal;
  final List<SlotInfo> allSlots;
  final VoidCallback onRefresh;

  const AddSlotDialog({
    Key? key,
    required this.client,
    required this.signal,
    required this.allSlots,
    required this.onRefresh,
  }) : super(key: key);

  @override
  State<AddSlotDialog> createState() => _AddSlotDialogState();
}

class _AddSlotDialogState extends State<AddSlotDialog> {
  final Map<String, bool> _selected = {};
  final TextEditingController _searchController = TextEditingController();
  List<SlotInfo> _filteredSlots = [];

  @override
  void initState() {
    super.initState();
    // Pre-populate checkboxes
    for (final slot in widget.allSlots) {
      _selected[slot.name] = false;
    }
    _applyFilter(''); // Initial filter
    _searchController.addListener(() => _applyFilter(_searchController.text));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _applyFilter(String query) {
    setState(() {
      final connectable = widget.allSlots
          .where((slot) =>
              slot.slotType == widget.signal.sigType &&
              slot.connectedTo.isEmpty)
          .toList();
      _filteredSlots = fuzzyFilter(
          connectable, query, [(slot) => slot.name, (slot) => slot.description]);
    });
  }

  Future<void> _handleAdd() async {
    // Filter out slots that we actually selected
    final chosenSlots = widget.allSlots.where((slot) {
      return _selected[slot.name] == true;
    });

    for (final slot in chosenSlots) {
      // Only connect if slot matches the signal type
      // and if slot is not already connected
      if (slot.slotType == widget.signal.sigType &&
          (slot.connectedTo.isEmpty || slot.connectedTo == '')) {
        try {
          await widget.client.connect(slot.name, widget.signal.name);
        } catch (e) {
          debugPrint(
              'Failed to connect slot "${slot.name}" to signal "${widget.signal.name}": $e');
        }
      }
    }

    widget.onRefresh();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Connect to signal "${widget.signal.name}"',
      subtitle:
          'Type: ${_typeLabels[widget.signal.sigType] ?? widget.signal.sigType}',
      icon: Icons.link,
      actions: [
        PaneAction.primary(
          label: 'Connect',
          icon: Icons.link,
          onPressed: _filteredSlots.isEmpty ? null : _handleAdd,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search slots...',
              suffixIcon: Icon(Icons.search),
            ),
          ),
          SizedBox(height: 8),
          if (_filteredSlots.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text('No matching slots available.'),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _filteredSlots.map((slot) {
                    return CheckboxListTile(
                      title: Text(slot.name),
                      subtitle: Text(slot.description),
                      value: _selected[slot.name],
                      onChanged: (val) {
                        setState(() {
                          _selected[slot.name] = val ?? false;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
