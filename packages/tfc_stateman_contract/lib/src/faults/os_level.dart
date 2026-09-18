/// Kernel traffic shaping: the faults that live below the byte stream.
///
/// `FaultProxy` owns everything expressible as "what bytes does the peer see,
/// and when". This file owns what is left: dropping an individual packet,
/// delivering it twice, delivering packet 7 before packet 6. Those are not
/// stream operations at all — a TCP connection reassembles in order by
/// definition, so a userspace proxy cannot inject reordering and cannot even
/// observe it. The kernel can, through `tc netem` on Linux and (unverified —
/// see the macOS section) `dnctl`/pf dummynet on macOS.
///
/// Nothing here is a test helper by accident. Two properties are load-bearing
/// and both are easy to lose in a refactor:
///
/// **Every command is an argument vector.** Each `…Argv` function returns a
/// `List<String>` that goes straight to [Process.run] with no shell in
/// between, and the interface name — the one value a caller supplies that ends
/// up next to `sudo` — is checked against [netemShapeableDevices] before it is
/// placed in that list. A device name must never be able to become a command
/// (threat T-02-14). The argv functions are public and pure precisely so a
/// test can assert on the exact vector without needing root.
///
/// **Teardown is registered the moment the install succeeds.** [installNetem]
/// takes a [TeardownRegistrar] — in a test, `addTearDown` itself — rather than
/// leaving removal to the end of the caller's body, because a body that throws
/// with `netem loss 100%` on `lo` leaves the whole machine unable to talk to
/// itself until somebody reboots or thinks to run `tc qdisc del` (threat
/// T-02-15). Passing the registrar in is also what keeps `package:test` out of
/// `lib/`.
///
/// Three measured facts from RESEARCH Finding 12 are encoded here rather than
/// left for each caller to rediscover:
///
/// 1. **netem shapes egress, and a loopback round trip crosses `lo`'s egress
///    twice.** `delay 50ms` measured a 108 ms RTT. The delay parameter is
///    therefore documented as *per traversal*, and [loopbackRoundTripFor] is
///    the single place the factor of two is written down.
/// 2. **The `change` and `replace` subcommands of `tc` preserve parameters
///    that the new command does not mention.** Verified: after a `rate
///    1mbit`, a further `… delay 7ms` through either of them still had the
///    rate attached. So setup is `del` (tolerating "nothing was installed")
///    then `add`, always. Neither keyword is constructed anywhere in this
///    file, and `oslevel_test.dart` asserts that on the argument vectors
///    themselves rather than on the source text.
/// 3. **`tc qdisc del` with nothing installed exits 2.** [removeNetem]
///    tolerates exactly that code and no other, which is what makes an
///    unconditional teardown safe without making a genuine failure silent.
///
/// Bandwidth throttling is deliberately absent even though netem can do it:
/// the proxy already throttles at the stream layer, and a `rate` here is the
/// parameter RESEARCH watched leak between tests. This file is for the faults
/// that have nowhere else to live.
library;

import 'dart:async';
import 'dart:io';

import 'capabilities.dart';

/// Registers a cleanup to run after the caller's unit of work, whatever
/// happens inside it.
///
/// `package:test`'s `addTearDown` satisfies this exactly, and is what every
/// caller in this repo passes. It is a parameter rather than an import so that
/// `lib/` never depends on the test package — and so that the registration
/// point is visibly the *caller's* scope, which is the scope the cleanup has
/// to outlive.
typedef TeardownRegistrar = void Function(FutureOr<void> Function() teardown);

/// The interfaces this harness will shape.
///
/// An allow-list rather than a metacharacter blocklist. The device name is
/// interpolated into an argument vector that runs under `sudo`, and while an
/// argv element cannot become a second command, "cannot" is doing a lot of
/// work in a security argument — an allow-list of the three interfaces the
/// harness actually uses removes the question instead of answering it
/// (threat T-02-14). `lo` is the harness's world; the veth pair is what
/// RESEARCH used to shape a non-loopback path in a container.
const netemShapeableDevices = {'lo', 'veth0', 'veth1'};

/// The privilege prefix, spelled the same way the capability probe spells it.
///
/// `capabilities.dart` answers [hasTc] by running `sudo -n tc qdisc show`, so
/// the helpers must run `sudo -n tc` too. A probe that tests one mechanism and
/// a helper that uses another is a gate that does not gate: the tests would
/// run on a machine that then fails at the first install, or skip on a machine
/// that could have run them.
///
/// `-n` is what keeps this non-interactive. A password prompt on a CI runner
/// does not fail — it hangs until the job times out.
const _sudo = ['sudo', '-n'];

/// `tc qdisc del` when there is no qdisc to delete.
///
/// `Error: Cannot delete qdisc with handle of zero.` Measured, and the reason
/// teardown can be unconditional.
const _nothingToDelete = 2;

/// What netem should do to packets on the interface.
///
/// Every field is optional and at least one must be set — see [toArgs], which
/// refuses an empty spec rather than installing a qdisc that shapes nothing.
///
/// Percentages are `0`–`100` doubles because that is how `tc` reads them
/// (`loss 100%`, `corrupt 0.1%`), and durations are [Duration] because that is
/// how Dart reads them. The mismatch is resolved here, once.
class NetemSpec {
  /// Delay applied to each packet **leaving** the interface.
  ///
  /// Per traversal, not per round trip. See [loopbackRoundTripFor].
  final Duration? delay;

  /// Random variation around [delay]; `tc`'s second positional delay argument.
  ///
  /// Jitter alone reorders packets, because a packet given less jitter can
  /// overtake the one in front of it.
  final Duration? jitter;

  /// Percentage of packets dropped outright. `100` is a kernel blackhole.
  final double? lossPercent;

  /// Percentage of packets sent immediately instead of after [delay], which is
  /// what makes them overtake their predecessors.
  ///
  /// `tc` rejects `reorder` without a `delay` to reorder against, so [toArgs]
  /// does too — otherwise the refusal arrives from a root shell and reads like
  /// a privilege problem.
  final double? reorderPercent;

  /// Correlation between consecutive reorder decisions, in percent.
  final double? reorderCorrelationPercent;

  /// Percentage of packets delivered twice.
  final double? duplicatePercent;

  /// Percentage of packets delivered with a corrupted bit.
  final double? corruptPercent;

  /// Creates a spec. At least one fault must be set; [toArgs] enforces it.
  const NetemSpec({
    this.delay,
    this.jitter,
    this.lossPercent,
    this.reorderPercent,
    this.reorderCorrelationPercent,
    this.duplicatePercent,
    this.corruptPercent,
  });

  /// The netem parameters, in the order Finding 12's verified command used.
  ///
  /// Throws [ArgumentError] for a spec `tc` would accept and quietly ignore,
  /// or reject for a reason that would be misread. Both cases are worth
  /// catching before a process is spawned: a qdisc that shapes nothing lets an
  /// arm pass while injecting no fault at all, which is indistinguishable from
  /// the harness working.
  List<String> toArgs() {
    if (delay == null &&
        lossPercent == null &&
        reorderPercent == null &&
        duplicatePercent == null &&
        corruptPercent == null) {
      throw ArgumentError.value(this, 'spec',
          'a netem qdisc with no fault shapes nothing; every arm running '
          'under it passes without a fault having been injected');
    }
    if (jitter != null && delay == null) {
      throw ArgumentError.value(
          this, 'spec', 'jitter is a variation around delay, so it needs one');
    }
    if (reorderPercent == null && reorderCorrelationPercent != null) {
      throw ArgumentError.value(this, 'spec',
          'a reorder correlation without a reorder percentage is silently '
          'dropped by tc');
    }
    if (reorderPercent != null && delay == null) {
      throw ArgumentError.value(this, 'spec',
          'tc rejects reorder without delay: reordering is expressed as '
          '"send this one immediately instead of after the delay", so there '
          'has to be a delay to jump ahead of');
    }
    return [
      if (delay != null) ...[
        'delay',
        _duration(delay!, 'delay'),
        if (jitter != null) _duration(jitter!, 'jitter'),
      ],
      if (lossPercent != null) ...['loss', _percent(lossPercent!, 'loss')],
      if (reorderPercent != null) ...[
        'reorder',
        _percent(reorderPercent!, 'reorder'),
        if (reorderCorrelationPercent != null)
          _percent(reorderCorrelationPercent!, 'reorderCorrelation'),
      ],
      if (duplicatePercent != null) ...[
        'duplicate',
        _percent(duplicatePercent!, 'duplicate'),
      ],
      if (corruptPercent != null) ...[
        'corrupt',
        _percent(corruptPercent!, 'corrupt'),
      ],
    ];
  }
}

/// The round trip to expect on loopback when netem is delaying by [perTraversal].
///
/// netem shapes egress. A packet to `127.0.0.1` leaves through `lo` and its
/// reply leaves through `lo` again, so a round trip pays the delay twice:
/// RESEARCH measured `delay 50ms` as a 108 ms RTT and `delay 100ms` as
/// 208–222 ms. An assertion written on the assumption that `delay` means
/// round-trip time is wrong by exactly 2x — and passes, because it is a lower
/// bound. This function is the only place that factor is written down.
Duration loopbackRoundTripFor(Duration perTraversal) => perTraversal * 2;

/// `sudo -n tc qdisc add dev <device> root netem …`.
///
/// `add`, never `change` or `replace`: both of those merge with whatever is
/// already installed (Finding 12).
List<String> netemAddArgv(String device, NetemSpec spec) => [
      ..._sudo,
      'tc',
      'qdisc',
      'add',
      'dev',
      _checkedDevice(device),
      'root',
      'netem',
      ...spec.toArgs(),
    ];

/// `sudo -n tc qdisc del dev <device> root`.
List<String> netemDeleteArgv(String device) =>
    [..._sudo, 'tc', 'qdisc', 'del', 'dev', _checkedDevice(device), 'root'];

/// `sudo -n tc qdisc show dev <device>`.
List<String> netemShowArgv(String device) =>
    [..._sudo, 'tc', 'qdisc', 'show', 'dev', _checkedDevice(device)];

/// Installs [spec] on [device] and registers its removal through
/// [registerTeardown].
///
/// The sequence is: validate, `del`, `add`, **register the removal**, return.
/// Validation happens before any process is spawned so a rejected device name
/// never reaches a root shell, and registration happens the instant the `add`
/// reports success so that everything the caller does afterwards — including
/// throwing — happens with the removal already booked.
///
/// Throws [StateError] if the `add` fails, with the exact command in the
/// message: the usual cause is missing privileges, and the second usual cause
/// is a parameter combination `tc` will not take.
Future<void> installNetem(
  String device,
  NetemSpec spec, {
  required TeardownRegistrar registerTeardown,
}) async {
  final argv = netemAddArgv(device, spec);

  // Finding 12: the only clean way to set parameters is to remove whatever is
  // there and add fresh. `change`/`replace` keep the old ones.
  await removeNetem(device);

  final result = await Process.run(argv.first, argv.sublist(1));
  if (result.exitCode != 0) {
    throw StateError('could not install netem on $device '
        '(exit ${result.exitCode}): ${result.stderr}\n'
        'command was: ${argv.join(' ')}');
  }
  registerTeardown(() => removeNetem(device));
}

/// Removes any root qdisc from [device], tolerating there being none.
///
/// Safe to call unconditionally — that is the point. Exit 2 means nothing was
/// installed, which is the state this function exists to reach. Any other
/// non-zero exit throws, loudly and with the manual command, because a netem
/// qdisc nobody removed degrades every connection on the machine and the
/// person who can fix it is the one reading the test output.
Future<void> removeNetem(String device) async {
  final argv = netemDeleteArgv(device);
  final result = await Process.run(argv.first, argv.sublist(1));
  if (result.exitCode == 0 || result.exitCode == _nothingToDelete) return;
  throw StateError('could not remove the qdisc from $device '
      '(exit ${result.exitCode}): ${result.stderr}\n'
      'THE MACHINE MAY STILL BE SHAPED. Run: ${argv.join(' ')}');
}

/// What `tc qdisc show dev <device>` prints.
///
/// Exposed raw because the interesting assertions are about which parameters
/// are present — a test proving `del`-then-`add` really discarded the previous
/// spec needs to look for the absence of `duplicate`, not just for `netem`.
Future<String> netemShow(String device) async {
  final argv = netemShowArgv(device);
  final result = await Process.run(argv.first, argv.sublist(1));
  if (result.exitCode != 0) {
    throw StateError('could not read the qdisc on $device '
        '(exit ${result.exitCode}): ${result.stderr}');
  }
  return result.stdout as String;
}

/// Whether a netem qdisc is currently installed on [device].
Future<bool> netemInstalled(String device) async =>
    (await netemShow(device)).contains('netem');

// ---------------------------------------------------------------------------
// macOS: dnctl + pf dummynet. A spike, not a supported leg.
// ---------------------------------------------------------------------------

/// The loopback interface on macOS, which is `lo0` and not `lo`.
const dummynetLoopbackInterface = 'lo0';

/// Where the stock pf ruleset lives, and therefore what teardown restores.
const _systemPfConf = '/etc/pf.conf';

/// The pf rules that push loopback traffic through a dummynet pipe.
///
/// One pipe for both directions rather than the two the `dnctl(8)` examples
/// use. Two pipes exist to shape the directions independently; the spike wants
/// symmetric delay, and one pipe keeps the arithmetic identical to the netem
/// arm's — each traversal pays the pipe's delay, so a round trip pays it
/// twice ([loopbackRoundTripFor]).
///
/// **This is the unverified part** (RESEARCH Assumptions Log A1). Two things
/// were measured on macOS 15.1.1 while writing this, and they point opposite
/// ways:
///
/// - The stock `/etc/pf.conf` on that machine does **not** contain
///   `set skip on lo0` — the exclusion usually blamed for pf ignoring
///   loopback. It contains `dummynet-anchor "com.apple/*"`, so the platform's
///   own ruleset has a dummynet anchor point already. That is encouraging.
/// - `pf.conf(5)` on that machine documents no `dummynet` keyword at all; the
///   syntax comes only from `dnctl(8)`'s examples. A parse error here is a
///   plausible outcome, and a legitimate answer to the spike.
///
/// Whether the packets then actually enter the pipe is still unanswered, and
/// needs root to answer. See [pfRulesetWithDummynet] for how these lines reach
/// the kernel without flushing the ruleset they are added to.
String dummynetLoopbackRules({required int pipe}) {
  final n = _checkedPipe(pipe);
  return 'dummynet in quick on $dummynetLoopbackInterface all pipe $n\n'
      'dummynet out quick on $dummynetLoopbackInterface all pipe $n\n';
}

/// [baseRuleset] with [dummynetLoopbackRules] spliced in at the right place.
///
/// `pfctl -f` **replaces** the active ruleset, and the stock `/etc/pf.conf`
/// opens with a warning about exactly that: "Care must be taken to ensure that
/// the main ruleset does not get flushed, as the nested anchors rely on the
/// anchor point defined here." Loading a two-line file of our own would drop
/// `scrub-anchor`, `nat-anchor`, `rdr-anchor`, `dummynet-anchor` and
/// `anchor "com.apple/*"` for as long as the spike runs — on a developer's
/// Mac, with whatever system services depend on them (threat T-02-17). So the
/// spike adds to the ruleset instead of substituting for it.
///
/// Placement is not cosmetic: pf requires rule *types* in order — options,
/// normalisation, queueing, translation, then filtering — so the dummynet
/// lines go immediately after the `dummynet-anchor` line, ahead of the filter
/// anchors. Throws [ArgumentError] on a ruleset with no anchor to place them
/// against, because guessing at a position in a firewall configuration is not
/// a thing this file should do.
String pfRulesetWithDummynet({
  required String baseRuleset,
  required int pipe,
}) {
  final lines = baseRuleset.split('\n');
  final anchor = RegExp(r'^\s*dummynet-anchor\b');
  final earlierAnchor = RegExp(r'^\s*(scrub|nat|rdr)-anchor\b');

  var at = lines.lastIndexWhere(anchor.hasMatch);
  at = at >= 0 ? at : lines.lastIndexWhere(earlierAnchor.hasMatch);
  if (at < 0) {
    throw ArgumentError.value(
        baseRuleset,
        'baseRuleset',
        'has no dummynet-anchor or translation-anchor line to place the '
            'dummynet rules after, and pf orders rule types strictly enough '
            'that the wrong position is a parse error rather than a subtle '
            'bug. Place them by hand on this machine');
  }
  return [
    ...lines.sublist(0, at + 1),
    dummynetLoopbackRules(pipe: pipe).trimRight(),
    ...lines.sublist(at + 1),
  ].join('\n');
}

/// `sudo -n dnctl pipe <n> config [delay <ms>] [bw <rate>]`.
///
/// At least one of [delay] or [bandwidth] must be given: a pipe configured
/// with neither shapes nothing, and the spike would then measure no delay and
/// report the capability as absent when in fact nothing was asked of it.
List<String> dnctlPipeConfigArgv({
  required int pipe,
  Duration? delay,
  String? bandwidth,
}) {
  final n = _checkedPipe(pipe);
  if (delay == null && bandwidth == null) {
    throw ArgumentError('a dummynet pipe needs a delay, a bandwidth or both; '
        'one configured with neither shapes nothing and would read as the '
        'platform being incapable');
  }
  return [
    ..._sudo,
    'dnctl',
    'pipe',
    '$n',
    'config',
    if (delay != null) ...['delay', _duration(delay, 'delay')],
    if (bandwidth != null) ...['bw', _checkedBandwidth(bandwidth)],
  ];
}

/// `sudo -n dnctl -f flush` — removes every pipe on the machine.
List<String> dnctlFlushArgv() => [..._sudo, 'dnctl', '-f', 'flush'];

/// `sudo -n pfctl -f <rules>` — replaces the active ruleset.
List<String> pfctlLoadArgv(String rulesFile) =>
    [..._sudo, 'pfctl', '-f', _checkedPath(rulesFile)];

/// `sudo -n pfctl -e` — enables pf.
List<String> pfctlEnableArgv() => [..._sudo, 'pfctl', '-e'];

/// `sudo -n pfctl -d` — disables pf.
List<String> pfctlDisableArgv() => [..._sudo, 'pfctl', '-d'];

/// Attempts to delay loopback traffic on macOS, and books the undo.
///
/// The whole macOS leg is one attempt: configure a pipe, point a pf rule at
/// loopback, and see whether a round trip slows down. It is gated on both
/// halves of the platform's capability — [hasDnctl] configures the pipe and
/// [hasPfctl] is what gets traffic into it, and having one without the other
/// is a machine where this cannot work.
///
/// Teardown is registered as soon as the pipe exists, and it restores more
/// than it created: `dnctl -f flush` drops the pipe, `/etc/pf.conf` is
/// reloaded, and pf is switched back off if it was off to begin with. Leaving
/// a developer's Mac with a replaced ruleset and pf enabled would be a far
/// worse outcome than the spike failing (threat T-02-17).
///
/// Throws [StateError] when the platform cannot do this, naming which half
/// said no; the caller is expected to have skipped already.
Future<void> installDummynetLoopbackDelay({
  required Duration perTraversalDelay,
  required TeardownRegistrar registerTeardown,
  int pipe = 1,
}) async {
  if (!Platform.isMacOS) {
    throw StateError('dnctl/pf dummynet is macOS-only; this is '
        '${Platform.operatingSystem}, where tc netem is the mechanism');
  }
  final dnctl = await hasDnctl();
  if (!dnctl.available) throw StateError(dnctl.reason);
  final pfctl = await hasPfctl();
  if (!pfctl.available) throw StateError(pfctl.reason);

  // Read pf's state before touching anything: whether teardown should turn it
  // back off is only knowable now.
  final wasEnabled = await _pfEnabled();

  // Add to the system ruleset rather than replace it: `pfctl -f` flushes what
  // it does not carry, and /etc/pf.conf's own header warns that its nested
  // anchors depend on staying loaded.
  final directory = await Directory.systemTemp.createTemp('dummynet_spike');
  final rules = File('${directory.path}/loopback.pf.conf');
  await rules.writeAsString(pfRulesetWithDummynet(
    baseRuleset: await File(_systemPfConf).readAsString(),
    pipe: pipe,
  ));

  await _mustRun(
    dnctlPipeConfigArgv(pipe: pipe, delay: perTraversalDelay),
    'configure dummynet pipe $pipe',
  );

  // The pipe now exists on the machine. Everything after this point is undone
  // by the teardown, including its own failures.
  registerTeardown(() => restoreFromDummynet(
        wasEnabled: wasEnabled,
        directory: directory,
      ));

  await _mustRun(pfctlLoadArgv(rules.path), 'load the dummynet pf rules');
  // `pfctl -e` exits non-zero when pf is already enabled, which is a success
  // for our purposes: the state we need is "enabled".
  if (!wasEnabled) {
    await _mustRun(pfctlEnableArgv(), 'enable pf');
  }
}

/// Undoes [installDummynetLoopbackDelay], one independent step at a time.
///
/// **Every step is attempted, and the ruleset goes back first.** The obvious
/// shape — four sequential awaits on a function that throws — makes the whole
/// restoration hostage to its first step: a `dnctl -f flush` that fails
/// because a concurrent run already flushed, or because sudo's credential
/// cache expired between install and teardown, would abort before
/// `/etc/pf.conf` is reloaded and leave a developer's Mac running the spike's
/// ruleset with `dummynet in/out quick on lo0` classifying every loopback
/// packet, and `pf` enabled when it was found disabled. That is threat T-02-17
/// arriving through the code written to prevent it. So the reload — the step
/// whose omission is the residue — runs first, nothing is gated on anything
/// else, and the failures are collected and reported together at the end.
///
/// [run] is a seam, for the same reason the argv builders are public and pure:
/// what this function does when a step *fails* is its whole subject, every
/// step needs root, and a test that could not substitute the runner could only
/// re-run the happy path on the one kind of machine where the residue does not
/// matter.
///
/// Throws [StateError] naming every step that failed and the commands that
/// finish the job by hand.
Future<void> restoreFromDummynet({
  required bool wasEnabled,
  required Directory directory,
  PrivilegedRunner run = _mustRun,
}) async {
  final failures = <String>[];
  Future<void> attempt(List<String> argv, String what) async {
    try {
      await run(argv, what);
    } catch (error) {
      failures.add('$error');
    }
  }

  await attempt(pfctlLoadArgv(_systemPfConf), 'restore $_systemPfConf');
  await attempt(dnctlFlushArgv(), 'flush the dummynet pipes');
  if (!wasEnabled) {
    await attempt(pfctlDisableArgv(), 'disable pf again, as it was found');
  }
  try {
    await directory.delete(recursive: true);
  } catch (error) {
    failures.add('could not delete ${directory.path}: $error');
  }

  if (failures.isEmpty) return;
  throw StateError('the dummynet teardown did not fully restore this machine. '
      'THE MACHINE MAY STILL BE SHAPED — run '
      '`${pfctlLoadArgv(_systemPfConf).join(' ')}` and '
      '`${dnctlFlushArgv().join(' ')}` by hand.\n${failures.join('\n')}');
}

/// Whether pf reports itself enabled right now.
Future<bool> _pfEnabled() async {
  final result = await Process.run('sudo', ['-n', 'pfctl', '-s', 'info']);
  return (result.stdout as String).contains('Status: Enabled');
}

/// Runs one privileged command, throwing when it does not succeed.
///
/// The shape of [_mustRun], named so [restoreFromDummynet] can take it as a
/// parameter — see that function for why substituting it is the only way its
/// behaviour can be judged without root.
typedef PrivilegedRunner = Future<void> Function(
    List<String> argv, String what);

/// Runs [argv], turning a non-zero exit into a [StateError] that says what was
/// being attempted and how to finish it by hand.
Future<void> _mustRun(List<String> argv, String what) async {
  final result = await Process.run(argv.first, argv.sublist(1));
  if (result.exitCode == 0) return;
  throw StateError('could not $what (exit ${result.exitCode}): '
      '${result.stderr}\ncommand was: ${argv.join(' ')}');
}

// ---------------------------------------------------------------------------
// Validation. Everything a caller supplies that ends up beside `sudo`.
// ---------------------------------------------------------------------------

String _checkedDevice(String device) {
  if (netemShapeableDevices.contains(device)) return device;
  throw ArgumentError.value(device, 'device',
      'not an interface this harness shapes. The name is placed in a command '
      'that runs as root, so it is checked against the allow-list '
      '$netemShapeableDevices rather than against a list of the characters '
      'someone thought to forbid');
}

int _checkedPipe(int pipe) {
  // dummynet numbers pipes from 1; 65535 is the documented ceiling.
  if (pipe >= 1 && pipe <= 65535) return pipe;
  throw ArgumentError.value(pipe, 'pipe', 'a dummynet pipe number is 1-65535');
}

String _checkedBandwidth(String bandwidth) {
  if (RegExp(r'^\d+(\.\d+)?(bit|Kbit|Mbit|Gbit)/s$').hasMatch(bandwidth)) {
    return bandwidth;
  }
  throw ArgumentError.value(bandwidth, 'bandwidth',
      'expected something like "1Mbit/s"; the value goes into a command that '
      'runs as root, so it is matched against a shape rather than passed on');
}

String _checkedPath(String path) {
  if (path.isNotEmpty && !RegExp(r'\s').hasMatch(path)) return path;
  throw ArgumentError.value(path, 'path',
      'a rules path must be non-empty and whitespace-free, which keeps the '
      '"no argument contains a space" invariant that makes these vectors '
      'readable as vectors');
}

/// `Duration` as `tc`/`dnctl` spell it: whole milliseconds with a `ms` suffix.
String _duration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be positive');
  }
  return '${value.inMilliseconds}ms';
}

/// A percentage as `tc` spells it, without a stray `.0`.
///
/// `100.0%` parses, but `100%` is what the manual pages and every example use,
/// and a test asserting on the exact argument vector should assert on the
/// spelling a human would write.
String _percent(double value, String name) {
  if (value <= 0 || value > 100) {
    throw ArgumentError.value(
        value, name, 'a netem percentage is greater than 0 and at most 100');
  }
  final rendered = value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
  return '$rendered%';
}
