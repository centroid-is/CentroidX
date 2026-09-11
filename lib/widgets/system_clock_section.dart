/// The Date & Time section of the About Linux page.
///
/// Split into two halves that need different permissions, and shown that way
/// on purpose:
///
/// * The status half — time, timezone, and whether sync is actually working —
///   reads unprivileged. It renders for anyone who opens the page, because
///   "is the clock right?" is an operator question.
/// * The settings half calls polkit `auth_admin_keep` actions. On a station
///   without the rule from `docs/polkit/49-centroid-clock.rules` these fail,
///   and the failure is reported as a missing station rule rather than as a
///   fault, since no amount of clicking in the HMI will fix it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/system_clock.dart';
import 'panes/pane_chrome.dart';
import 'panes/standard_dialog.dart';

/// How often the status is re-read. The clock display ticks locally between
/// polls, so this only paces the D-Bus traffic, not the seconds hand.
const Duration systemClockPollInterval = Duration(seconds: 10);

class SystemClockSection extends StatefulWidget {
  final TimeDateApi timeDate;

  /// Null on a host with no systemd-timesyncd. The clock half still works.
  final TimeSyncApi? timeSync;

  /// Called after the operator changes the server list, so it can be stored
  /// for re-application on the next start. See [ntpServersPrefsKey].
  final Future<void> Function(List<String> servers)? onServersChanged;

  /// The stored list, shown as what this HMI will re-apply at startup.
  final List<String> storedServers;

  /// Whether this session may change the clock — for rendering only. The
  /// status half ignores it and always renders: "is the clock right?" is an
  /// operator question, and locking the answer to it would be the reason
  /// nobody notices a station whose timestamps are an hour out.
  ///
  /// Required, with no default. A `= true` here would be a fail-open access
  /// parameter that a future caller acquires by forgetting about it, which is
  /// the one defect class this file cannot afford.
  final bool settingsAllowed;

  /// Asked at tap time, before any setter runs. Return true to proceed; a
  /// false return has already recorded the refusal and told the operator.
  ///
  /// Kept as a callback rather than reading Riverpod here so this widget stays
  /// constructible from a plain `WidgetTester` with fakes and no
  /// `ProviderScope` — which is what its unit tests and its seven golden
  /// frames do.
  final Future<bool> Function()? onBeforeChange;

  const SystemClockSection({
    super.key,
    required this.timeDate,
    required this.settingsAllowed,
    this.timeSync,
    this.onServersChanged,
    this.storedServers = const [],
    this.onBeforeChange,
  });

  @override
  State<SystemClockSection> createState() => _SystemClockSectionState();
}

class _SystemClockSectionState extends State<SystemClockSection> {
  SystemClockStatus? _clock;
  TimeSyncStatus? _sync;
  Object? _readError;
  bool _loading = true;

  /// Set while a write is in flight, to stop a poll landing on top of it.
  bool _busy = false;
  String? _actionError;

  Timer? _poll;

  /// Host time as of the last poll, plus how long ago that was — so the
  /// display ticks every second without a D-Bus call per second.
  DateTime? _timeAtPoll;
  final Stopwatch _sincePoll = Stopwatch();
  Timer? _tick;

  late List<String> _storedServers;

  @override
  void initState() {
    super.initState();
    _storedServers = [...widget.storedServers];
    unawaited(_refresh());
    _poll = Timer.periodic(systemClockPollInterval, (_) {
      if (!_busy) unawaited(_refresh(quiet: true));
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _timeAtPoll != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _sincePoll.stop();
    super.dispose();
  }

  /// [quiet] keeps a background poll from flashing the spinner or clearing an
  /// error the operator has not read yet.
  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final clock = await widget.timeDate.readStatus();
      final sync = await widget.timeSync?.readStatus();
      if (!mounted) return;
      setState(() {
        _clock = clock;
        _sync = sync;
        _readError = null;
        _loading = false;
        _timeAtPoll = clock.time;
        _sincePoll
          ..reset()
          ..start();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _readError = e;
        _loading = false;
      });
    }
  }

  /// Runs a write, surfacing a polkit refusal as the station-side problem it
  /// is, then re-reads so the display reflects what actually happened rather
  /// than what was asked for.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
      await _refresh(quiet: true);
    } catch (e) {
      if (mounted) setState(() => _actionError = describeClockError(e));
      // Re-read anyway: a partial failure still moves the host state.
      await _refresh(quiet: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Whether this action may proceed.
  ///
  /// Called as the *first* line of every entry point, ahead of the picker
  /// dialogs — not inside [_run]. Guarding at the write would open a
  /// six-hundred-entry timezone list, let the operator search it, take their
  /// choice, and only then refuse. A refusal has already written its audit row
  /// and published its prompt, so there is nothing to report from here.
  Future<bool> _allow() async =>
      widget.onBeforeChange == null || await widget.onBeforeChange!();

  /// The host clock, advanced locally since the last poll.
  DateTime? get _displayTime {
    final base = _timeAtPoll;
    if (base == null) return null;
    return base.add(_sincePoll.elapsed);
  }

  Future<void> _setNtp(bool enabled) async {
    if (!await _allow()) return;
    // The switch has already drawn itself in the new position; the refusal
    // leaves `clock.ntpEnabled` untouched, so the next build snaps it back.
    // The denial prompt is what says why.
    if (!mounted) return;
    await _run(() => widget.timeDate.setNtp(enabled));
  }

  Future<void> _pickTimezone() async {
    if (!await _allow() || !mounted) return;
    final current = _clock?.timezone ?? '';
    List<String> zones;
    try {
      zones = await widget.timeDate.listTimezones();
    } catch (e) {
      if (mounted) setState(() => _actionError = describeClockError(e));
      return;
    }
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _TimezonePicker(zones: zones, current: current),
    );
    if (chosen == null || chosen == current) return;
    await _run(() => widget.timeDate.setTimezone(chosen));
  }

  Future<void> _editServers() async {
    if (!await _allow() || !mounted) return;
    final sync = _sync;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _NtpServerEditor(
        servers: _storedServers.isNotEmpty
            ? _storedServers
            : (sync?.runtimeServers ?? const []),
      ),
    );
    if (result == null) return;

    await _run(() async {
      final api = widget.timeSync;
      if (api != null) await api.setRuntimeNtpServers(result);
      await widget.onServersChanged?.call(result);
    });
    if (mounted) setState(() => _storedServers = result);
  }

  Future<void> _setManualTime() async {
    if (!await _allow() || !mounted) return;
    final now = _displayTime ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null) return;
    final chosen = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    await _run(() => widget.timeDate.setTime(chosen));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final clock = _clock;
    if (clock == null) {
      return _Message(
        icon: Icons.error_outline,
        text: 'Could not read the system clock: '
            '${_readError == null ? 'unknown error' : describeClockError(_readError!)}',
      );
    }

    final health = timeSyncHealth(clock);
    final sync = _sync;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeading(
          label: 'Date & Time',
          trailing: _busy
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: () => _refresh(),
                ),
        ),
        _ClockCard(
          time: _displayTime ?? clock.time,
          timezone: clock.timezone,
          health: health,
        ),
        if (_actionError != null) ...[
          const SizedBox(height: 8),
          _Message(icon: Icons.lock_outline, text: _actionError!, error: true),
        ],
        const SizedBox(height: 8),
        // The settings half. Locked controls stay visible, enabled and
        // tappable — `access_lock_badge.dart`'s ruling: a greyed row teaches
        // the operator the panel is broken, while a tap that refuses tells
        // them which permission they need and offers a way to get it. The
        // badge is advisory; `onBeforeChange` in [_run] is the check.
        _SettingTile(
          icon: Icons.schedule,
          label: 'Time zone',
          value: clock.timezone.isEmpty ? '—' : clock.timezone,
          locked: !widget.settingsAllowed,
          onTap: _busy ? null : _pickTimezone,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.sync),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Network time (NTP)'),
              if (!widget.settingsAllowed) const _LockGlyph(),
            ],
          ),
          subtitle: Text(_ntpSubtitle(clock, health)),
          value: clock.ntpEnabled,
          // A host with no NTP client has nothing to switch. A locked session
          // still gets a live switch on purpose: it snaps back when the guard
          // refuses, and the denial prompt is what explains why.
          onChanged: !clock.canNtp || _busy ? null : _setNtp,
        ),
        if (!clock.ntpEnabled)
          _SettingTile(
            icon: Icons.edit_calendar,
            label: 'Set clock manually',
            value: 'Only while network time is off',
            locked: !widget.settingsAllowed,
            onTap: _busy ? null : _setManualTime,
          ),
        if (clock.rtcDrift != null &&
            clock.rtcDrift!.abs() > const Duration(seconds: 5))
          _Message(
            icon: Icons.battery_alert,
            // A drifting RTC still boots to a wrong time before NTP catches
            // up, which is when historised samples get bad timestamps.
            text: 'Hardware clock differs from system time by '
                '${formatSyncDuration(clock.rtcDrift!)} — the RTC battery may '
                'be failing.',
          ),
        if (sync != null) ...[
          const SizedBox(height: 12),
          _SyncDetail(
            sync: sync,
            storedServers: _storedServers,
            onEditServers: _busy || widget.onServersChanged == null
                ? null
                : _editServers,
            locked: !widget.settingsAllowed,
          ),
        ] else if (clock.ntpEnabled)
          _Message(
            icon: Icons.info_outline,
            text: 'systemd-timesyncd is not running, so no sync detail is '
                'available. The clock is managed by another NTP client.',
          ),
        const SizedBox(height: 8),
        Text(
          'Host clock, read over D-Bus. Changes need administrator rights.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  String _ntpSubtitle(SystemClockStatus clock, TimeSyncHealth health) {
    switch (health) {
      case TimeSyncHealth.synchronized:
        return 'Clock is synchronized';
      case TimeSyncHealth.notSynchronized:
        return 'Enabled, but the clock has not synchronized yet';
      case TimeSyncHealth.disabled:
        return 'Off — the clock is free-running';
      case TimeSyncHealth.unavailable:
        return 'No NTP client available on this host';
    }
  }
}

/// The sync verdict as a [PaneStatus], so this chip reads the same as the
/// connection chips on the IP settings page next door.
PaneStatus _healthStatus(TimeSyncHealth health) {
  switch (health) {
    case TimeSyncHealth.synchronized:
      // PaneStatus.running's green, but a tick rather than a play glyph —
      // a clock is not "running" in the equipment sense.
      return const PaneStatus(
          label: 'Synchronized', color: Colors.green, icon: Icons.check_circle);
    case TimeSyncHealth.notSynchronized:
      // Warning, not fault: this is also the normal state for the first
      // minute after boot.
      return const PaneStatus.warning('Not synchronized');
    case TimeSyncHealth.disabled:
      return const PaneStatus.stopped('Network time off');
    case TimeSyncHealth.unavailable:
      return const PaneStatus.unknown('Unavailable');
  }
}

class _ClockCard extends StatelessWidget {
  final DateTime time;
  final String timezone;
  final TimeSyncHealth health;

  const _ClockCard({
    required this.time,
    required this.timezone,
    required this.health,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatClock(time),
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  timezone.isEmpty ? _formatDate(time) : '${_formatDate(time)} · $timezone',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PaneStatusChip(status: _healthStatus(health)),
        ],
      ),
    );
  }
}

/// The "is it actually working" half.
class _SyncDetail extends StatelessWidget {
  final TimeSyncStatus sync;
  final List<String> storedServers;
  final VoidCallback? onEditServers;
  final bool locked;

  const _SyncDetail({
    required this.sync,
    required this.storedServers,
    this.onEditServers,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = sync.lastMessage;
    final rows = <(String, String)>[];

    if (sync.serverName.isNotEmpty) {
      rows.add((
        'Server',
        sync.serverAddress == null || sync.serverAddress == sync.serverName
            ? sync.serverName
            : '${sync.serverName} (${sync.serverAddress})',
      ));
    }
    if (message != null) {
      rows.add(('Stratum', '${message.stratum}'));
      rows.add(('Offset', formatSyncDuration(message.offset)));
      rows.add(('Round trip', formatSyncDuration(message.roundTrip)));
      rows.add(('Jitter', formatSyncDuration(message.jitter)));
      rows.add(('Packets', '${message.packetCount}'));
    }
    if (sync.pollInterval > Duration.zero) {
      rows.add(('Poll interval', formatSyncDuration(sync.pollInterval)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(label: 'Time sync'),
        if (message == null)
          const _Message(
            icon: Icons.hourglass_empty,
            // The state a wrong server address leaves timesyncd in, so it must
            // not read as healthy.
            text: 'No NTP packet has been received yet.',
          ),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(row.$1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Text(row.$2, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _ServerList(
          sync: sync,
          storedServers: storedServers,
          onEdit: onEditServers,
          locked: locked,
        ),
      ],
    );
  }
}

class _ServerList extends StatelessWidget {
  final TimeSyncStatus sync;
  final List<String> storedServers;
  final VoidCallback? onEdit;
  final bool locked;

  const _ServerList({
    required this.sync,
    required this.storedServers,
    this.onEdit,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = sync.effectiveServers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('NTP servers',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (onEdit != null) ...[
              TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Edit'),
              ),
              if (locked) const _LockGlyph(),
            ],
          ],
        ),
        if (effective.isEmpty)
          Text('None configured',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final server in effective)
                Chip(
                  label: Text(server),
                  avatar: Icon(
                    server == sync.serverName ? Icons.star : Icons.dns,
                    size: 16,
                  ),
                ),
            ],
          ),
        const SizedBox(height: 6),
        Text(
          _provenance(),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        const _InfoPill(
          icon: Icons.terminal,
          // The list edited here is runtime-only — `SetRuntimeNTPServers` is
          // the only setter systemd exposes on the bus, and timesyncd forgets
          // it on restart. The HMI re-applies it at startup, which works until
          // the HMI is the thing that did not start. Anyone who wants the host
          // to own the list has to go around this page entirely, and the route
          // is a file in a container this process cannot write — so it is
          // worth one line here rather than only in docs/polkit/README.md.
          text: 'To have the host own the list instead: ssh to this station, '
              'set NTP= in /etc/systemd/timesyncd.conf, and restart '
              'systemd-timesyncd. Those show above as "From '
              '/etc/systemd/timesyncd.conf on the host" and outlive the HMI.',
        ),
      ],
    );
  }

  /// Where the servers in use came from, and — when it applies — the fact
  /// that this HMI is the thing keeping them there across reboots.
  String _provenance() {
    if (sync.linkServers.isNotEmpty) {
      return 'Supplied by DHCP on the active connection; these take precedence '
          'over anything configured here.';
    }
    if (sync.usingFallbackOnly) {
      return 'Built-in fallback servers — nothing is configured for this '
          'station.';
    }
    final parts = <String>[];
    if (sync.systemServers.isNotEmpty) {
      parts.add('From /etc/systemd/timesyncd.conf on the host.');
    }
    if (sync.runtimeServers.isNotEmpty) {
      parts.add(storedServers.isEmpty
          // Someone else pushed them; say so rather than implying we will
          // restore them.
          ? 'Set at runtime. systemd does not persist these, and this HMI has '
              'no stored list to re-apply after a reboot.'
          : 'Set at runtime. systemd forgets these on reboot, so this HMI '
              're-applies the list when it starts.');
    }
    return parts.join(' ');
  }
}

/// Editor for the NTP server list. Order is preserved because timesyncd tries
/// servers in order.
class _NtpServerEditor extends StatefulWidget {
  final List<String> servers;

  const _NtpServerEditor({required this.servers});

  @override
  State<_NtpServerEditor> createState() => _NtpServerEditorState();
}

class _NtpServerEditorState extends State<_NtpServerEditor> {
  late List<String> _servers;
  final _controller = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _servers = [...widget.servers];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    if (!isValidNtpServer(value)) {
      setState(() => _error = 'Not a valid hostname or IP address');
      return;
    }
    if (_servers.contains(value)) {
      setState(() => _error = 'Already in the list');
      return;
    }
    setState(() {
      _servers.add(value);
      _controller.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'NTP servers',
      icon: Icons.dns,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: 'Apply',
          onPressed: () => Navigator.of(context).pop(_servers),
        ),
      ],
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_servers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No servers — the host falls back to its defaults.'),
              )
            else
              // Tried in order, so the list is reorderable rather than sorted.
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  itemCount: _servers.length,
                  // onReorder, not the newer onReorderItem. The original reason
                  // was the ivi image's Flutter 3.38.7, which predated the new
                  // callback; that image is gone, but every other
                  // ReorderableListView in the repo (server_config,
                  // key_repository, page_editor) is still on onReorder and they
                  // should move together — a half-migrated codebase is where
                  // the off-by-one below gets applied to a callback that
                  // already adjusted it.
                  // ignore: deprecated_member_use
                  onReorder: (oldIndex, newIndex) => setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    _servers.insert(newIndex, _servers.removeAt(oldIndex));
                  }),
                  itemBuilder: (context, index) {
                    final server = _servers[index];
                    return ListTile(
                      key: ValueKey(server),
                      dense: true,
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle),
                      ),
                      title: Text(server),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove',
                        onPressed: () =>
                            setState(() => _servers.removeAt(index)),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      labelText: 'Add server',
                      hintText: '10.104.29.1 or ntp.example.com',
                      errorText: _error,
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: FilledButton(onPressed: _add, child: const Text('Add')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Searchable timezone list — `ListTimezones` returns around 600 entries, so
/// a plain dropdown is unusable on a touchscreen.
class _TimezonePicker extends StatefulWidget {
  final List<String> zones;
  final String current;

  const _TimezonePicker({required this.zones, required this.current});

  @override
  State<_TimezonePicker> createState() => _TimezonePickerState();
}

class _TimezonePickerState extends State<_TimezonePicker> {
  final _search = TextEditingController();
  late List<String> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.zones;
    _search.addListener(() {
      final query = _search.text.trim().toLowerCase();
      setState(() {
        _filtered = query.isEmpty
            ? widget.zones
            : widget.zones
                .where((z) => z.toLowerCase().contains(query))
                .toList();
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Time zone',
      icon: Icons.public,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _filtered.length,
                itemBuilder: (context, index) {
                  final zone = _filtered[index];
                  return ListTile(
                    dense: true,
                    selected: zone == widget.current,
                    title: Text(zone),
                    onTap: () => Navigator.of(context).pop(zone),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String label;
  final Widget? trailing;

  const _SectionHeading({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The lock this section draws beside a control the session cannot use.
///
/// Not `GroupLockBadge`: that one is a `ConsumerWidget` and reads the session
/// itself, and this file is deliberately Riverpod-free so its tests and its
/// golden frames can build it from fakes alone. The two draw the same glyph in
/// the same colour for the same reason — not orange, which means forced, and
/// not red, because a lock is not a fault.
class _LockGlyph extends StatelessWidget {
  const _LockGlyph();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Locked. Needs the "administer" permission.',
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(
          Icons.lock_outline,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  /// Draws the lock and swaps the chevron for it. Advisory only — the tile
  /// stays tappable, and the guard in [_SystemClockSectionState._run] is what
  /// actually refuses.
  final bool locked;

  const _SettingTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (locked) const _LockGlyph(),
        ],
      ),
      subtitle: Text(value),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// A boxed aside: standing guidance that is true whatever the clock is doing.
///
/// Deliberately not a [_Message], which is for something that has happened —
/// a refusal, a drifting RTC. A tinted, bounded box keeps a paragraph of
/// how-to from reading as one more status line in a column of status lines.
class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool error;

  const _Message({required this.icon, required this.text, this.error = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _formatClock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _formatDate(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}';
