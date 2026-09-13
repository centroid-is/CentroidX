/// Binding a device on the page to the EtherCAT subdevice it is drawn for.
///
/// Shown under an EtherCAT device's own form — by the page editor for a
/// device on the page, by a rack's slice dialog for a terminal inside one —
/// the way the tech-doc picker is: it is a fact about the hardware the box
/// stands for, and no device's own form has to know about it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import 'common.dart' show KeyField;
import 'ethercat_asset.dart';
import 'ethercat_name_match.dart';
import 'ethercat_autocable.dart';
import 'ethercat_masters.dart';
import 'ethercat_subdevice.dart';
import 'ethercat_subdevice_pane.dart';

class EcSubDeviceBindingEditor extends ConsumerStatefulWidget {
  const EcSubDeviceBindingEditor({super.key, required this.asset});

  final EtherCatAsset asset;

  @override
  ConsumerState<EcSubDeviceBindingEditor> createState() =>
      _EcSubDeviceBindingEditorState();
}

class _EcSubDeviceBindingEditorState extends ConsumerState<EcSubDeviceBindingEditor> {
  /// The dropdown value that stands for "type the two keys yourself".
  static const _customKeys = '__custom_keys__';

  List<EcBusConfig> _masters = const [];
  bool _custom = false;
  bool _finding = false;
  String? _findResult;

  EcSubDeviceBinding get _binding => widget.asset.ecSubDevice ??= EcSubDeviceBinding();

  @override
  void initState() {
    super.initState();
    _loadMasters();
  }

  Future<void> _loadMasters() async {
    List<EcBusConfig> found;
    try {
      final sm = await ref.read(stateManProvider.future);
      found = discoverEcMasters(sm.keyMappings);
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _masters = found;
      // Keys that are not one of the mapped masters are custom by definition,
      // and hiding them behind a dropdown that cannot show them would lose
      // them from view.
      final key = widget.asset.ecSubDevice?.diagKey ?? '';
      _custom = key.isNotEmpty && _masterFor(key) == null;
    });
  }

  EcBusConfig? _masterFor(String diagKey) {
    for (final m in _masters) {
      if (m.diagKey == diagKey) return m;
    }
    return null;
  }

  /// Drops a binding with nothing left in it, so an asset somebody opened the
  /// section on and left alone saves exactly as it was.
  void _prune() {
    final b = widget.asset.ecSubDevice;
    if (b != null && b.isEmpty) widget.asset.ecSubDevice = null;
  }

  Future<void> _findByName() async {
    setState(() {
      _finding = true;
      _findResult = null;
    });
    try {
      final sm = await ref.read(stateManProvider.future);
      final buses = await loadEcBuses(sm);
      final plan = planEcNameMatches([widget.asset], buses, overwrite: true);
      if (!mounted) return;
      final name = widget.asset.ecName.replaceAll(RegExp(r'\s+'), ' ').trim();
      setState(() {
        if (plan.matched.isNotEmpty) {
          applyEcNameMatches(plan);
          final m = plan.matched.single;
          _custom = false;
          _findResult = 'Bound to ${m.subdevice.label} on ${m.bus.label}.';
        } else if (plan.ambiguous.isNotEmpty) {
          final n = plan.ambiguous.single.candidates.length;
          _findResult = '"$name" is the name of $n subdevices on different '
              'masters. Pick the master above.';
        } else if (name.isEmpty) {
          _findResult = 'This device has no name to look for.';
        } else if (buses.isEmpty) {
          _findResult = 'No EtherCAT masters are mapped yet.';
        } else {
          _findResult = 'No subdevice on any master is called "$name".';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _findResult = 'Could not read the masters: $e');
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.asset.ecSubDevice;
    final bound = b?.isBound ?? false;
    final master = b == null ? null : _masterFor(b.diagKey);
    final masterValue = _custom ? _customKeys : master?.diagKey;

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      initiallyExpanded: bound,
      leading: const Icon(Icons.settings_ethernet, size: 20),
      title: const Text('EtherCAT subdevice'),
      subtitle: Text(
        bound
            ? '${b!.name ?? 'Position ${b.position}'}'
                '${master == null ? '' : ' · ${master.label}'}'
            : 'Not bound — cables to it carry no diagnostics',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('ec-master-$masterValue-${_masters.length}'),
          initialValue: masterValue,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Master'),
          items: [
            for (final m in _masters)
              DropdownMenuItem(value: m.diagKey, child: Text(m.label)),
            const DropdownMenuItem(
                value: _customKeys, child: Text('Custom keys…')),
          ],
          onChanged: (v) => setState(() {
            if (v == _customKeys) {
              _custom = true;
              return;
            }
            final m = v == null ? null : _masterFor(v);
            if (m == null) return;
            _custom = false;
            _binding
              ..diagKey = m.diagKey
              ..infoKey = m.infoKey;
          }),
        ),
        if (_custom) ...[
          const SizedBox(height: 8),
          KeyField(
            label: 'Diagnostics array key',
            initialValue: b?.diagKey ?? '',
            onChanged: (v) => setState(() {
              _binding.diagKey = v;
              _prune();
            }),
          ),
          const SizedBox(height: 8),
          KeyField(
            label: 'Subdevice info array key',
            initialValue: b?.infoKey ?? '',
            onChanged: (v) => setState(() {
              _binding.infoKey = v;
              _prune();
            }),
          ),
        ],
        const SizedBox(height: 8),
        _SlavePicker(
          binding: b,
          onPicked: (position, name) => setState(() {
            _binding
              ..position = position
              ..name = name;
          }),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: _finding ? null : _findByName,
              icon: _finding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search, size: 18),
              label: const Text('Find by name'),
            ),
            const Spacer(),
            if (b != null)
              TextButton.icon(
                onPressed: () => setState(() {
                  widget.asset.ecSubDevice = null;
                  _custom = false;
                  _findResult = null;
                }),
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Unbind'),
              ),
          ],
        ),
        if (_findResult != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_findResult!, style: theme.textTheme.bodySmall),
          ),
        if (bound)
          _BindingPreview(
            binding: b!,
            onFollow: (position) =>
                setState(() => _binding.position = position),
          ),
      ],
    );
  }
}

/// The master's subdevices by name when its info array is readable, a number
/// field when it is not. Choosing one records the name as well as the
/// position, so the binding survives a subdevice being added upstream.
class _SlavePicker extends StatelessWidget {
  const _SlavePicker({required this.binding, required this.onPicked});

  final EcSubDeviceBinding? binding;
  final void Function(int position, String? name) onPicked;

  @override
  Widget build(BuildContext context) {
    final infoKey = binding?.infoKey ?? '';
    final position = binding?.position ?? 0;
    Widget numberField() => TextFormField(
          key: ValueKey('ec-position-$position'),
          initialValue: position >= 1 ? '$position' : '',
          decoration: const InputDecoration(
            labelText: 'Position',
            helperText: 'Array index, 1 = first subdevice on the master',
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 1) onPicked(n, null);
          },
        );
    if (infoKey.isEmpty) return numberField();

    return EcKeyValues(
      keys: [infoKey],
      builder: (context, values, errors) {
        final bus = EcBus.fromValues('', info: values[infoKey]);
        if (bus.subdevices.isEmpty) return numberField();
        final current = binding?.resolve(bus)?.position;
        return DropdownButtonFormField<int>(
          key: ValueKey('ec-subdevice-$current'),
          initialValue: current,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Subdevice'),
          items: [
            for (final s in bus.subdevices)
              DropdownMenuItem(
                value: s.position,
                child: Text(
                  '${s.position} · ${s.label}'
                  '${(s.info?.model ?? '').isEmpty ? '' : ' (${s.info!.model})'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null) onPicked(v, bus.at(v)?.info?.shortName);
          },
        );
      },
    );
  }
}

/// What the binding reads now, so a wrong choice is obvious before the form
/// is closed — and the offer to follow a subdevice that has moved.
class _BindingPreview extends StatelessWidget {
  const _BindingPreview({required this.binding, required this.onFollow});

  final EcSubDeviceBinding binding;
  final ValueChanged<int> onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;
    return EcKeyValues(
      keys: binding.keys,
      builder: (context, values, errors) {
        final bus = EcBus.fromValues('',
            info: values[binding.infoKey], diag: values[binding.diagKey]);
        final subdevice = binding.resolve(bus);
        final diag = subdevice?.diag;
        final String text;
        final EcHealth health;
        if (errors.containsKey(binding.diagKey)) {
          text = 'Cannot read the diagnostics array.';
          health = EcHealth.unknown;
        } else if (values[binding.diagKey] == null) {
          text = 'Waiting for the master…';
          health = EcHealth.unknown;
        } else if (diag == null) {
          text = 'No subdevice at position ${binding.position} on that master.';
          health = EcHealth.unknown;
        } else {
          text = ecSubDeviceSummary(diag);
          health = diag.health;
        }
        final moved = binding.drifted(bus) ? subdevice : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: ecHealthColor(states, health),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
              ],
            ),
            if (moved != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.swap_vert, size: 16),
                  label: Text('${moved.label} is now #${moved.position} '
                      '(was #${binding.position}) — follow it'),
                  onPressed: () => onFollow(moved.position),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// What "Bind EtherCAT devices by name" would do, for the confirm dialog.
/// What drawing the cables from the PLC would add, before it adds it.
class EcAutoCableReview extends StatelessWidget {
  const EcAutoCableReview({super.key, required this.plan});

  final EcAutoCablePlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Every cable the PLC\'s own topology puts between two bound '
            'devices on this page. Nothing is drawn until you confirm, and it '
            'is one undo step.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (plan.cables.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Will draw (${plan.cables.length})',
                style: theme.textTheme.titleSmall),
          ),
          for (final c in plan.cables)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.cable, size: 18),
              title: Text(c.label),
              subtitle: Text(c.busLabel),
            ),
        ],
        if (plan.notes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Left alone (${plan.notes.length})',
                style: theme.textTheme.titleSmall),
          ),
          for (final n in plan.notes)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.info_outline, size: 18),
              title: Text(n, style: theme.textTheme.bodySmall),
            ),
        ],
      ],
    );
  }
}

class EcNameMatchReview extends StatelessWidget {
  const EcNameMatchReview({super.key, required this.plan});

  final EcNameMatchPlan plan;

  static String _assetLabel(EtherCatAsset a) {
    final name = a.ecName.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name.isEmpty ? '${a.displayName} (no name)' : name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: theme.textTheme.titleSmall),
        );
    Widget row(String title, String subtitle, {IconData? icon}) => ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: icon == null ? null : Icon(icon, size: 18),
          title: Text(title),
          subtitle: Text(subtitle),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Matches each device\'s name against the subdevice names the PLC '
            'publishes. Nothing is bound until you confirm, and it is one '
            'undo step.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (plan.matched.isNotEmpty) ...[
          heading('Will bind (${plan.matched.length})'),
          for (final m in plan.matched)
            row(
              _assetLabel(m.asset),
              '${m.subdevice.label} · ${m.bus.label} #${m.subdevice.position}'
              '${m.viaPageMaster ? ' — the master the rest of this page is on' : ''}',
              icon: m.viaPageMaster ? Icons.help_outline : Icons.link,
            ),
        ],
        if (plan.ambiguous.isNotEmpty) ...[
          heading('More than one subdevice by that name (${plan.ambiguous.length})'),
          for (final a in plan.ambiguous)
            row(
              _assetLabel(a.asset),
              [for (final c in a.candidates) '${c.bus.label} #${c.subdevice.position}']
                  .join(', '),
              icon: Icons.call_split,
            ),
        ],
        if (plan.unmatched.isNotEmpty) ...[
          heading('No match (${plan.unmatched.length})'),
          for (final a in plan.unmatched)
            row(_assetLabel(a), a.displayName, icon: Icons.link_off),
        ],
        if (plan.skipped.isNotEmpty) ...[
          heading('Already bound, left alone (${plan.skipped.length})'),
          for (final a in plan.skipped)
            row(_assetLabel(a),
                a.ecSubDevice?.name ?? 'Position ${a.ecSubDevice?.position}'),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}
