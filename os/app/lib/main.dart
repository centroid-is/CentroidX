import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'answers.dart';
import 'system.dart';
import 'theme.dart';
import 'widgets.dart';

void main() => runApp(const SetupApp());

class SetupApp extends StatelessWidget {
  const SetupApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CentroidX station installer',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const SetupFlow(),
      );
}

enum _Stage { disk, station, vpn, confirm, progress }

class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key});

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  final _answers = Answers();
  final _stationForm = GlobalKey<FormState>();
  final _vpnForm = GlobalKey<FormState>();

  _Stage _stage = _Stage.disk;
  List<TargetDisk>? _disks;
  String? _diskError;

  @override
  void initState() {
    super.initState();
    _loadDisks();
  }

  Future<void> _loadDisks() async {
    if (await bootDiskUnknown()) {
      // No safe way to guess which disk not to erase, so offer none. The shell
      // installer refuses for the same reason.
      setState(() => _diskError =
          'Cannot identify the disk this installer booted from, so no target '
          'can be offered safely. Power off and report this.');
      return;
    }
    final d = await listDisks();
    setState(() {
      _disks = d;
      if (d.isEmpty) {
        _diskError = 'No disk found to install onto. The USB this is running '
            'from is deliberately excluded.';
      }
      if (d.length == 1) _answers.targetDisk = d.single.devicePath;
    });
  }

  void _go(_Stage s) => setState(() => _stage = s);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const _Brand(),
              Expanded(child: _body()),
            ],
          ),
        ),
      );

  Widget _body() {
    switch (_stage) {
      case _Stage.disk:
        return _diskStep();
      case _Stage.station:
        return _stationStep();
      case _Stage.vpn:
        return _vpnStep();
      case _Stage.confirm:
        return _confirmStep();
      case _Stage.progress:
        return ProgressStep(answers: _answers);
    }
  }

  Widget _diskStep() {
    if (_diskError != null) {
      return SetupStep(
        title: 'Cannot continue',
        body: [
          Text(_diskError!, style: Theme.of(context).textTheme.bodyLarge),
        ],
        primary: const SizedBox.shrink(),
      );
    }
    if (_disks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SetupStep(
      title: 'Install target',
      subtitle: 'Everything on the disk you choose will be erased. The USB this '
          'installer booted from is not listed.',
      body: [
        for (final d in _disks!) _DiskTile(
            disk: d,
            selected: _answers.targetDisk == d.devicePath,
            onTap: () => setState(() => _answers.targetDisk = d.devicePath),
          ),
      ],
      primary: FilledButton(
        onPressed:
            _answers.targetDisk == null ? null : () => _go(_Stage.station),
        child: const Text('Continue'),
      ),
    );
  }

  Widget _stationStep() => Form(
        key: _stationForm,
        child: SetupStep(
          title: 'Station',
          subtitle: 'Generate fills a field with a strong value and shows it '
              'once — use it for anything you do not need to recite.',
          body: [
            Field(
              label: 'Station name',
              helper: 'Shown in the browser tab, and used as the hostname',
              initial: _answers.stationName,
              validator: validateStationName,
              onChanged: (v) => _answers.stationName = v.trim(),
            ),
            PasswordField(
              label: "Password for the 'centroid' login",
              helper: 'The operator account on this machine',
              initial: _answers.centroidPassword,
              onChanged: (v) => _answers.centroidPassword = v,
            ),
            PasswordField(
              label: "Password for 'root'",
              helper: 'Administrative login',
              initial: _answers.rootPassword,
              onChanged: (v) => _answers.rootPassword = v,
            ),
            PasswordField(
              label: 'Password for the remote screen',
              helper: 'Asked for by a VNC client or the browser view',
              initial: _answers.vncPassword,
              onChanged: (v) => _answers.vncPassword = v,
            ),
            PasswordField(
              label: 'Password for the database',
              helper: 'Read only by containers on this machine — generate it',
              initial: _answers.dbPassword,
              onChanged: (v) => _answers.dbPassword = v,
            ),
          ],
          secondary: OutlinedButton(
            onPressed: () => _go(_Stage.disk),
            child: const Text('Back'),
          ),
          primary: FilledButton(
            onPressed: () {
              if (_stationForm.currentState?.validate() ?? false) {
                _go(_Stage.vpn);
              }
            },
            child: const Text('Continue'),
          ),
        ),
      );

  Widget _vpnStep() => Form(
        key: _vpnForm,
        child: SetupStep(
          title: 'Remote access',
          subtitle: 'This station generates its own WireGuard key — the private '
              'half never leaves the machine. Its public key is shown at the end '
              'for you to register on the server.',
          body: [
            Field(
              label: 'VPN server address and port',
              helper: 'e.g. vpn.example.is:13255',
              initial: _answers.vpnEndpoint,
              onChanged: (v) => _answers.vpnEndpoint = v.trim(),
            ),
            Field(
              label: 'Obfuscation key',
              helper: 'Shared with the server',
              initial: _answers.vpnObfuscatorKey,
              onChanged: (v) => _answers.vpnObfuscatorKey = v.trim(),
            ),
            Field(
              label: "Server's WireGuard public key",
              initial: _answers.vpnServerPublicKey,
              onChanged: (v) => _answers.vpnServerPublicKey = v.trim(),
            ),
            Field(
              label: "This station's VPN address",
              helper: 'e.g. 10.13.1.42/24',
              initial: _answers.vpnAddress,
              onChanged: (v) => _answers.vpnAddress = v.trim(),
            ),
            Field(
              label: 'Routed through the tunnel',
              initial: _answers.vpnAllowedIps,
              onChanged: (v) => _answers.vpnAllowedIps = v.trim(),
            ),
          ],
          secondary: OutlinedButton(
            onPressed: () {
              _answers.vpnWanted = false;
              _go(_Stage.confirm);
            },
            child: const Text('Skip'),
          ),
          primary: FilledButton(
            onPressed: () {
              _answers.vpnWanted = true;
              if (!_answers.vpnComplete) return;
              _go(_Stage.confirm);
            },
            child: const Text('Continue'),
          ),
        ),
      );

  Widget _confirmStep() {
    final t = Theme.of(context);
    return SetupStep(
      title: 'Ready to install',
      body: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: SolarizedColors.base02,
            border: Border.all(color: t.colorScheme.error, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Everything on ${_answers.targetDisk} will be erased.',
                  style: t.textTheme.titleMedium
                      ?.copyWith(color: t.colorScheme.error)),
              const SizedBox(height: 16),
              Text('Station: ${_answers.stationName}',
                  style: t.textTheme.bodyLarge),
              Text(
                _answers.vpnWanted && _answers.vpnComplete
                    ? 'Remote access: ${_answers.vpnEndpoint}'
                    : 'Remote access: not configured',
                style: t.textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ],
      secondary: OutlinedButton(
        onPressed: () => _go(_Stage.vpn),
        child: const Text('Back'),
      ),
      primary: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: t.colorScheme.error,
          foregroundColor: t.colorScheme.onError,
        ),
        onPressed: () => _go(_Stage.progress),
        child: const Text('Erase and install'),
      ),
    );
  }
}

/// A tappable disk choice. Deliberately not RadioListTile: its onChanged is
/// deprecated in favour of RadioGroup, and a 96px card is a better target for a
/// finger than a radio dot.
class _DiskTile extends StatelessWidget {
  const _DiskTile({
    required this.disk,
    required this.selected,
    required this.onTap,
  });

  final TargetDisk disk;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: SolarizedColors.base02,
            border: Border.all(
              color: selected ? t.colorScheme.primary : SolarizedColors.base01,
              width: selected ? 3 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 32,
                color: selected ? t.colorScheme.primary : SolarizedColors.base01,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(disk.devicePath, style: t.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text('${disk.size}  -  ${disk.model}',
                        style: t.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
        child: Row(
          children: [
            // Same treatment as the HMI's login screen: a srcIn filter onto the
            // scheme, so the wordmark follows the theme instead of being baked.
            SvgPicture.asset(
              'assets/centroid.svg',
              height: 34,
              colorFilter: const ColorFilter.mode(
                  headingForeground, BlendMode.srcIn),
            ),
            const Spacer(),
            Text('Station installer',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}

/// Streams the shell installer's output. Everything destructive lives there.
class ProgressStep extends StatefulWidget {
  const ProgressStep({super.key, required this.answers});
  final Answers answers;

  @override
  State<ProgressStep> createState() => _ProgressStepState();
}

class _ProgressStepState extends State<ProgressStep> {
  final _lines = <String>[];
  final _scroll = ScrollController();
  InstallResult? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final r = await runInstaller(widget.answers, onLine: (l) {
      if (!mounted) return;
      setState(() => _lines.add(l));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
    if (mounted) setState(() => _result = r);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _result;
    return SetupStep(
      title: r == null
          ? 'Installing…'
          : (r.ok ? 'Installed' : 'Installation failed'),
      subtitle: r == null ? 'Do not remove the USB key or power off.' : null,
      body: [
        if (r != null && r.ok && r.publicKey != null) ...[
          Container(
            padding: const EdgeInsets.all(20),
            color: SolarizedColors.base02,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Register this station's public key on the VPN server:",
                    style: t.textTheme.titleMedium),
                const SizedBox(height: 12),
                SelectableText(r.publicKey!,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 20,
                        color: SolarizedColors.green)),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        Container(
          height: 300,
          color: SolarizedColors.base02,
          padding: const EdgeInsets.all(12),
          child: ListView.builder(
            controller: _scroll,
            itemCount: _lines.length,
            itemBuilder: (_, i) => Text(
              _lines[i],
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 14, height: 1.4),
            ),
          ),
        ),
      ],
      primary: r == null
          ? const SizedBox(
              width: 200,
              height: minTarget,
              child: Center(child: CircularProgressIndicator()),
            )
          : FilledButton(
              onPressed: r.ok ? reboot : null,
              child: Text(r.ok ? 'Remove USB and reboot' : 'Failed'),
            ),
    );
  }
}
