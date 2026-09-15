import 'dart:async';

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
    // Resolved once and handed to listDisks: this used to call bootDisk()
    // here and again inside listDisks, probing the same thing twice.
    final boot = await bootDisk();
    if (boot == null) {
      // No safe way to guess which disk not to erase, so offer none. The shell
      // installer refuses for the same reason.
      setState(() => _diskError =
          'Cannot identify the disk this installer booted from, so no target '
          'can be offered safely. Power off and report this.');
      return;
    }
    final d = await listDisks(boot: boot);
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
              'once — use it for anything you do not need to recite. '
              '$passwordRule',
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
            // Last on the form, deliberately: boot-test.py taps the first
            // field by coordinates read off a screenshot, so the name stays
            // where it is.
            ChoiceField(
              label: 'Keyboard layout the station starts in',
              helper: 'The other two stay one Alt+Shift, or one globe key, away',
              options: {for (final l in keyboardLayouts) l.code: l.name},
              value: _answers.keyboardLayout,
              onChanged: (v) => setState(() => _answers.keyboardLayout = v),
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
              helper: "Centroid's obfuscator; change it only for a site that "
                  'runs its own',
              validator: validateRequired,
              initial: _answers.vpnEndpoint,
              onChanged: (v) => _answers.vpnEndpoint = v.trim(),
            ),
            Field(
              label: 'Obfuscation key',
              helper: 'Shared with the server — not this station\'s own key',
              validator: validateRequired,
              initial: _answers.vpnObfuscatorKey,
              onChanged: (v) => _answers.vpnObfuscatorKey = v.trim(),
            ),
            Field(
              label: "Server's WireGuard public key",
              helper: 'The 44-character key of the server the tunnel ends at',
              validator: validateRequired,
              initial: _answers.vpnServerPublicKey,
              onChanged: (v) => _answers.vpnServerPublicKey = v.trim(),
            ),
            Field(
              label: "This station's VPN address",
              helper: 'e.g. 192.0.2.42/24',
              validator: validateRequired,
              initial: _answers.vpnAddress,
              onChanged: (v) => _answers.vpnAddress = v.trim(),
            ),
            Field(
              label: 'Routed through the tunnel',
              helper: 'Subnet reachable over the VPN, e.g. 192.0.2.0/24',
              initial: _answers.vpnAllowedIps,
              validator: validateRequired,
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
              // Was a bare `if (!vpnComplete) return`, so an incomplete form
              // made Continue do nothing at all, with no message: the operator
              // is left pressing a button that looks broken. validate() puts
              // the reason under the field that is missing.
              if (!_vpnForm.currentState!.validate()) return;
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
            const AddressBar(),
            const SizedBox(width: 20),
            Text('Station installer',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}

/// Where to reach this installer, in the header band.
///
/// Read-only, deliberately: nothing here configures networking — the station's
/// own image runs NetworkManager and has a settings page for it. The panel is
/// almost always on DHCP, and the lease it took is invisible to whoever is
/// standing in front of it and needed by whoever is not.
///
/// Same shape as the HMI's About page header (`lib/pages/about_linux.dart`) —
/// a globe, then the addresses joined by a middle dot — rather than the same
/// code: that widget reads NetworkManager over D-Bus and neither is on the USB.
///
/// When the remote view is up this also carries the credential for it, because
/// the two facts are only useful together: an address with no code is a login
/// prompt nobody can answer, and a code with no address is nothing at all. This
/// line is what one person reads aloud to another.
///
/// Polled rather than read once: the app starts within a couple of seconds of
/// boot, and neither the DHCP lease nor the credential file is necessarily
/// there yet.
/// What the operator reads out of the header band.
///
/// https, not http, and not a bare address: noVNC's RA2ne handshake needs
/// `window.crypto.subtle`, which browsers withhold on an insecure origin, so an
/// http URL loads a page that then cannot authenticate at all. The certificate
/// is self-signed and the browser warns once.
///
/// A null code means centroidx-remote-access did not run, and the remote view
/// is then unreachable no matter what is typed — so no URL is offered rather
/// than one that cannot work.
@visibleForTesting
String addressBarDescribe(List<String> addresses, String? code) {
  if (addresses.isEmpty) return 'no network';
  if (code == null) return addresses.join('  ·  ');
  return 'https://${addresses.first}   root / $code';
}

@visibleForTesting
class AddressBar extends StatefulWidget {
  const AddressBar({
    super.key,
    this.probe,
    this.codeProbe,
    this.interval = const Duration(seconds: 5),
  });

  /// Overridden by tests; the defaults ask this machine.
  final Future<List<String>> Function()? probe;
  final Future<String?> Function()? codeProbe;
  final Duration interval;

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  List<String> _addresses = const [];
  String? _code;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(widget.interval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final a = await (widget.probe ?? hostAddresses)();
    final c = await (widget.codeProbe ?? remoteAccessCode)();
    if (!mounted) return;
    // Comparing before setState: this runs every few seconds for the whole
    // install, and the answer almost never changes.
    if (c == _code &&
        a.length == _addresses.length &&
        List.generate(a.length, (i) => a[i] == _addresses[i]).every((e) => e)) {
      return;
    }
    setState(() {
      _addresses = a;
      _code = c;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dim = _addresses.isEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.public,
            size: 16,
            color: dim ? SolarizedColors.base01 : t.textTheme.bodyMedium?.color),
        const SizedBox(width: 8),
        // Said rather than left blank: "no network" is an answer, and on a
        // panel with an unplugged cable it is the one worth seeing.
        Text(
          addressBarDescribe(_addresses, _code),
          style: t.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            color:
                dim ? SolarizedColors.base01 : t.textTheme.bodyMedium?.color,
          ),
        ),
      ],
    );
  }
}

/// Streams the shell installer's output. Everything destructive lives there.
class ProgressStep extends StatefulWidget {
  const ProgressStep({
    super.key,
    required this.answers,
    this.install = runInstaller,
  });

  final Answers answers;

  /// The install itself, injectable for the same reason [AddressBar.probe] is:
  /// the real one wipes a disk, so nothing that runs in a test may reach it.
  final Future<InstallResult> Function(
    Answers answers, {
    required void Function(String line) onLine,
  }) install;

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
    final r = await widget.install(widget.answers, onLine: _append);
    if (mounted) setState(() => _result = r);
  }

  /// Appends a line to the log AND scrolls to it.
  ///
  /// The scroll is not decoration. The log is a 300px window onto a run that is
  /// hundreds of lines long and already scrolled to the bottom, so a line
  /// appended without it lands just below the fold -- which is precisely how a
  /// refused reboot used to report itself to nobody. Every writer goes through
  /// here so there is no second way to append.
  void _append(String line) {
    if (!mounted) return;
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _result;
    return SetupStep(
      title: r == null
          ? 'Installing…'
          : (r.ok ? 'Installed' : 'Installation failed'),
      // The instruction is a sentence, not part of the button label: the key
      // has to be out BEFORE the button is pressed, or the firmware boots the
      // installer again, and a label reads as "the button does both".
      subtitle: r == null
          ? 'Do not remove the USB key or power off.'
          : (r.ok ? 'Remove the USB key, then press Reboot.' : null),
      body: [
        if (r != null && !r.ok) ...[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: SolarizedColors.base02,
              border: Border.all(color: t.colorScheme.error, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('The disk was not installed.',
                    style: t.textTheme.titleMedium
                        ?.copyWith(color: t.colorScheme.error)),
                const SizedBox(height: 12),
                // A partly-written target is erased on the way out
                // (centroidx-install's disarm_target), so the machine stops at
                // the firmware rather than booting something half made. Saying
                // so here is the difference between "try again" and "wait, is
                // it broken now?" — deliberately not promising anything about
                // a disk the installer never got as far as writing.
                Text(
                  'No half-installed station was left behind: if the image had '
                  'already been written, the disk was erased again on the way '
                  'out. Read the log below, leave the USB key in, and reboot '
                  'to try again.',
                  style: t.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
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
        // Above the log, not in it: this is the one message on this screen that
        // the operator cannot act around, and the log is where it went
        // unnoticed before.
        if (_shutdownError != null) ...[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: SolarizedColors.base02,
              border: Border.all(color: t.colorScheme.error, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This machine refused to shut down.',
                    style: t.textTheme.titleMedium
                        ?.copyWith(color: t.colorScheme.error)),
                const SizedBox(height: 12),
                Text(
                  'The install itself is finished and the disk is written -- '
                  'power the machine off at the switch, remove the USB key, '
                  'and turn it back on.',
                  style: t.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                SelectableText(_shutdownError!,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14, height: 1.4)),
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
      // A dead button labelled "Failed" was the whole action row on a failed
      // install: it restated the title, did nothing, and left the operator
      // with no way off the screen but the power switch. Both outcomes now
      // offer the thing you actually do next.
      secondary: r == null || r.ok
          ? null
          : OutlinedButton(
              onPressed: _busy ? null : () => _shutdown(powerOff, 'Power off'),
              child: const Text('Power off'),
            ),
      primary: r == null
          ? const SizedBox(
              width: 200,
              height: minTarget,
              child: Center(child: CircularProgressIndicator()),
            )
          : FilledButton(
              onPressed: _busy ? null : () => _shutdown(reboot, 'Reboot'),
              child: const Text('Reboot'),
            ),
    );
  }

  bool _busy = false;

  /// What every rung of [reboot]/[powerOff] said when none of them worked.
  String? _shutdownError;

  /// systemd tears this process down on success, so the only outcome that can
  /// come back here is a refusal by all three rungs -- which, on the last screen
  /// of an install, leaves the power switch as the only way forward. It is
  /// stated on the screen, put in the log, and the button is handed back.
  Future<void> _shutdown(
      Future<String> Function() request, String what) async {
    setState(() {
      _busy = true;
      _shutdownError = null;
    });
    final err = await request();
    if (!mounted) return;
    _append('$what failed:');
    for (final line in err.split('\n')) {
      _append('  $line');
    }
    setState(() {
      _busy = false;
      _shutdownError = err;
    });
  }
}
