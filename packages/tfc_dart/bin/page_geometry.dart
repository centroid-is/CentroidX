/// Reads the geometry of a page editor page and reports how its conveyors
/// actually connect, so a key assignment can be argued from the drawing
/// instead of guessed.
///
///   dart run bin/page_geometry.dart --page /boxes/freezers
///   dart run bin/page_geometry.dart --page /boxes/freezers --runs
///   dart run bin/page_geometry.dart --page /boxes/freezers --chain 34
///   dart run bin/page_geometry.dart --page /boxes/freezers --score preds.json
///
/// The page comes from the HMI's own preferences file, because
/// `get_asset_detail` over MCP hangs on large pages (three timeouts at
/// 120s/400s/500s on `/boxes/freezers`, which holds 118 assets).
///
/// ## STALE SINCE PHASE 1 -- it reads a file no station writes any more
///
/// That preferences file is a `shared_preferences` JSON file, and Phase 1
/// removed `shared_preferences` from the app. No station has written one
/// since, so this tool works only against a file captured **before** that
/// upgrade -- an old panel, or a copy somebody kept. Pointed at a current
/// station it finds nothing, or finds something stale and says nothing about
/// how old it is, which is the worse of the two.
///
/// This is **not** a casualty of the relational-config cutover. Pages moved
/// out of `flutter_preferences` into `config_item` rows in Phase 3, but this
/// tool never read that table either; it was already reading a file by then.
///
/// The replacement is a read of the `page` and `asset` `config_item` rows,
/// which is where the geometry lives now. It is deliberately left unbuilt:
/// this is a developer tool for arguing about a drawing, not a runtime path,
/// and nothing on a plant depends on it. Anyone who needs it should write
/// that read rather than hunting for an old preferences file.
///
/// ## Why this exists
///
/// A first attempt at keying `/boxes/freezers` ran a shortest path over
/// conveyor endpoint distance and got the line wrong. Endpoint proximity is
/// not connection: a plant lays parallel lines a few centimetres apart, so the
/// nearest endpoint to the end of line 1's belt is frequently the *side* of
/// line 2's belt. Distance alone cannot tell those apart -- alignment can.
/// Every edge here is therefore classified, and a `parallel` neighbour is
/// never a step in a chain.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';

// -- geometry ---------------------------------------------------------------

class Pt {
  final double x, y;
  const Pt(this.x, this.y);
  double distanceTo(Pt o) => math.sqrt(math.pow(x - o.x, 2) + math.pow(y - o.y, 2));
}

/// One conveyor on the page.
///
/// [angle] is degrees, 0 pointing along +x. A conveyor is drawn as a segment
/// of length [width] centred on ([cx], [cy]), so its two ends are the centre
/// plus and minus half the width along the angle.
class Belt {
  final int index;
  final String type;
  final String key;
  final double cx, cy, angle, width;

  Belt(this.index, this.type, this.key, this.cx, this.cy, this.angle, this.width);

  Pt get centre => Pt(cx, cy);
  double get _rad => angle * math.pi / 180.0;
  Pt get a => Pt(cx - width / 2 * math.cos(_rad), cy - width / 2 * math.sin(_rad));
  Pt get b => Pt(cx + width / 2 * math.cos(_rad), cy + width / 2 * math.sin(_rad));
  List<Pt> get ends => [a, b];

  /// Orientation folded to [0, 180): a belt drawn at 270 lies on the same axis
  /// as one drawn at 90, it merely points the other way. Direction of travel
  /// is not recoverable from the drawing, so only the axis is used.
  double get axis {
    var v = angle % 180.0;
    if (v < 0) v += 180.0;
    return v;
  }

  /// Smallest angle between two axes, in degrees, so 179 vs 1 reads as 2.
  double axisDeltaTo(Belt o) {
    final d = (axis - o.axis).abs();
    return d > 90 ? 180 - d : d;
  }

  /// Perpendicular distance from [o]'s centre to the infinite line this belt
  /// lies on. This is what separates "the next belt in the run" from "the belt
  /// in the neighbouring lane": both may have a near endpoint, but only the
  /// first sits on the same line.
  double perpOffsetTo(Belt o) {
    final dx = math.cos(_rad), dy = math.sin(_rad);
    final vx = o.cx - cx, vy = o.cy - cy;
    return (vx * dy - vy * dx).abs();
  }

  double endGapTo(Belt o) {
    var best = double.infinity;
    for (final p in ends) {
      for (final q in o.ends) {
        final d = p.distanceTo(q);
        if (d < best) best = d;
      }
    }
    return best;
  }

  /// How much of [o] lies alongside this belt, measured along this belt's
  /// axis. Two belts are lane-neighbours only if they actually run beside each
  /// other; without this, every horizontal belt on the page counts as a
  /// neighbour of every other horizontal belt.
  double projectionOverlapWith(Belt o) {
    final dx = math.cos(_rad), dy = math.sin(_rad);
    double proj(Pt p) => (p.x - cx) * dx + (p.y - cy) * dy;
    final mine = [proj(a), proj(b)]..sort();
    final theirs = [proj(o.a), proj(o.b)]..sort();
    final lo = math.max(mine[0], theirs[0]);
    final hi = math.min(mine[1], theirs[1]);
    return hi - lo;
  }
}

/// How two belts relate. Only [inline] and [transfer] can be steps in a chain.
enum Link {
  /// Same axis, same line, ends meet: the run continues.
  inline,

  /// Ends meet at an angle: a corner or a transfer onto another run.
  transfer,

  /// Same axis but offset sideways: a neighbouring lane. Never a chain step,
  /// and the single mistake that produced the bad line 1 assignment.
  parallel,

  none,
}

class Edge {
  final Belt from, to;
  final Link kind;
  final double gap;
  Edge(this.from, this.to, this.kind, this.gap);
}

/// Tolerances are in page units (the page is 0..1 in both axes).
class Tol {
  /// Two ends count as meeting within this distance.
  final double join;

  /// Axes within this many degrees count as the same axis.
  final double axisDeg;

  /// Centres further than this off the line count as a different lane rather
  /// than a continuation of the same run.
  final double lane;

  /// Beyond this sideways offset two belts are simply elsewhere on the page,
  /// not neighbouring lanes. Without an upper bound every horizontal belt is
  /// a "neighbour" of every other one and the signal is worthless.
  final double laneMax;

  const Tol({
    this.join = 0.035,
    this.axisDeg = 15.0,
    this.lane = 0.02,
    this.laneMax = 0.12,
  });
}

Link classify(Belt i, Belt j, Tol t) {
  final sameAxis = i.axisDeltaTo(j) <= t.axisDeg;
  final offset = i.perpOffsetTo(j);
  final gap = i.endGapTo(j);

  if (gap <= t.join) {
    // Ends meet. Same line means the run continues; a different line at the
    // same angle means they touch side-on, which is not a continuation.
    if (!sameAxis) return Link.transfer;
    if (offset > t.lane) return Link.parallel;
    // Two belts in one run abut; they do not lie on top of one another. A
    // real overlap means these are stacked rows a hair apart, and treating
    // them as one run lets a group drift across the page in small steps.
    return i.projectionOverlapWith(j) <= t.join ? Link.inline : Link.parallel;
  }

  // Ends do not meet, so the only relationship left worth recording is
  // running alongside -- close, aligned, and actually overlapping.
  if (sameAxis &&
      offset > t.lane &&
      offset <= t.laneMax &&
      i.projectionOverlapWith(j) > 0) {
    return Link.parallel;
  }
  return Link.none;
}

// -- loading ----------------------------------------------------------------

String? _defaultPrefsPath() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData == null) return null;
    return '$appData\\centroidx\\shared_preferences.json';
  }
  final home = env['HOME'];
  if (home == null) return null;
  if (Platform.isMacOS) {
    return '$home/Library/Containers/is.centroid.centroidx/Data/Documents/shared_preferences.json';
  }
  return '$home/.local/share/centroidx/shared_preferences.json';
}

List<dynamic> loadAssets(String prefsPath, String pageKey) {
  final raw = jsonDecode(File(prefsPath).readAsStringSync()) as Map<String, dynamic>;
  final blob = raw['page_editor_data'] ?? raw['flutter.page_editor_data'];
  if (blob == null) {
    throw StateError('no page_editor_data in $prefsPath');
  }
  final pages = jsonDecode(blob as String) as Map<String, dynamic>;
  final page = pages[pageKey];
  if (page == null) {
    final known = pages.keys.toList()..sort();
    throw StateError('no page "$pageKey". Known pages:\n  ${known.join('\n  ')}');
  }
  return (page as Map<String, dynamic>)['assets'] as List<dynamic>;
}

List<Belt> beltsOf(List<dynamic> assets, {String type = 'ConveyorConfig'}) {
  final out = <Belt>[];
  for (var i = 0; i < assets.length; i++) {
    final a = assets[i] as Map<String, dynamic>;
    if (a['asset_name'] != type) continue;
    final c = a['coordinates'] as Map<String, dynamic>;
    final s = a['size'] as Map<String, dynamic>;
    out.add(Belt(
      i,
      a['asset_name'] as String,
      (a['key'] as String?) ?? '',
      (c['x'] as num).toDouble(),
      (c['y'] as num).toDouble(),
      ((c['angle'] as num?) ?? 0).toDouble(),
      (s['width'] as num).toDouble(),
    ));
  }
  return out;
}

// -- reports ----------------------------------------------------------------

List<Edge> allEdges(List<Belt> belts, Tol t) {
  final out = <Edge>[];
  for (var i = 0; i < belts.length; i++) {
    for (var j = i + 1; j < belts.length; j++) {
      final k = classify(belts[i], belts[j], t);
      if (k == Link.none) continue;
      out.add(Edge(belts[i], belts[j], k, belts[i].endGapTo(belts[j])));
    }
  }
  return out;
}

void printInventory(List<Belt> belts) {
  stdout.writeln('${belts.length} conveyors');
  stdout.writeln('idx    x      y      ang   width  span                  key');
  final sorted = [...belts]..sort((p, q) {
      final c = p.cy.compareTo(q.cy);
      return c != 0 ? c : p.cx.compareTo(q.cx);
    });
  for (final b in sorted) {
    final span = b.axis < 45 || b.axis > 135
        ? 'x ${b.a.x.toStringAsFixed(3)}..${b.b.x.toStringAsFixed(3)}'
        : 'y ${b.a.y.toStringAsFixed(3)}..${b.b.y.toStringAsFixed(3)}';
    stdout.writeln('${b.index.toString().padRight(6)}'
        '${b.cx.toStringAsFixed(3)} ${b.cy.toStringAsFixed(3)}  '
        '${b.angle.toStringAsFixed(0).padLeft(3)}   '
        '${b.width.toStringAsFixed(3)}  ${span.padRight(21)} '
        '${b.key.isEmpty ? '(none)' : b.key}');
  }
}

/// Collinear groups: belts sharing an axis and a line, joined end to end.
/// A run is the part of a layout that is unambiguous -- no key assignment
/// inside a run can be reordered without contradicting the drawing.
void printRuns(List<Belt> belts, Tol t) {
  final parent = <int, int>{for (final b in belts) b.index: b.index};
  int find(int x) => parent[x] == x ? x : (parent[x] = find(parent[x]!));
  void union(int x, int y) => parent[find(x)] = find(y);

  for (final e in allEdges(belts, t)) {
    if (e.kind == Link.inline) union(e.from.index, e.to.index);
  }
  final groups = <int, List<Belt>>{};
  for (final b in belts) {
    groups.putIfAbsent(find(b.index), () => []).add(b);
  }
  final runs = groups.values.toList()
    ..sort((p, q) => q.length.compareTo(p.length));

  stdout.writeln('${runs.length} runs (collinear, end-to-end)');
  var n = 0;
  for (final r in runs) {
    n++;
    r.sort((p, q) {
      final horiz = p.axis < 45 || p.axis > 135;
      return horiz ? p.cx.compareTo(q.cx) : p.cy.compareTo(q.cy);
    });
    final horiz = r.first.axis < 45 || r.first.axis > 135;
    stdout.writeln('\nrun $n  ${r.length} belt(s)  ${horiz ? 'horizontal' : 'vertical'}');
    for (final b in r) {
      stdout.writeln('    idx ${b.index.toString().padRight(4)}'
          'x=${b.cx.toStringAsFixed(3)} y=${b.cy.toStringAsFixed(3)}  '
          '${b.key.isEmpty ? '(none)' : b.key}');
    }
  }
}

/// Everything reachable from [start], with each step's link type, refusing to
/// cross a `parallel` edge. Where a belt has more than one continuation the
/// ambiguity is printed rather than resolved -- picking one silently is how
/// the first attempt went wrong.
void printChain(List<Belt> belts, int start, Tol t) {
  final byIndex = {for (final b in belts) b.index: b};
  final from = byIndex[start];
  if (from == null) {
    stderr.writeln('no conveyor at index $start');
    exitCode = 2;
    return;
  }
  final adj = <int, List<Edge>>{};
  for (final e in allEdges(belts, t)) {
    if (e.kind == Link.parallel) continue;
    adj.putIfAbsent(e.from.index, () => []).add(e);
    adj.putIfAbsent(e.to.index, () => []).add(Edge(e.to, e.from, e.kind, e.gap));
  }

  final seen = <int>{start};
  var cur = from;
  var step = 0;
  stdout.writeln('walk from idx $start');
  while (true) {
    final key = cur.key.isEmpty ? '(none)' : cur.key;
    stdout.writeln('  ${step.toString().padLeft(2)}  idx ${cur.index.toString().padRight(4)}'
        'x=${cur.cx.toStringAsFixed(3)} y=${cur.cy.toStringAsFixed(3)}  $key');
    final nexts = (adj[cur.index] ?? [])
        .where((e) => !seen.contains(e.to.index))
        .toList()
      ..sort((p, q) {
        // Prefer staying in the run: a continuation beats a corner.
        if (p.kind != q.kind) return p.kind == Link.inline ? -1 : 1;
        return p.gap.compareTo(q.gap);
      });
    if (nexts.isEmpty) {
      stdout.writeln('      end of chain');
      break;
    }
    if (nexts.length > 1) {
      stdout.writeln('      AMBIGUOUS - ${nexts.length} continuations:');
      for (final e in nexts) {
        stdout.writeln('        idx ${e.to.index} (${e.kind.name}, gap ${e.gap.toStringAsFixed(3)})'
            '  ${e.to.key.isEmpty ? '(none)' : e.to.key}');
      }
      stdout.writeln('      taking idx ${nexts.first.to.index} - verify before trusting the rest');
    }
    cur = nexts.first.to;
    seen.add(cur.index);
    step++;
  }
}

/// Lane-neighbours. Belts listed together here are almost certainly on
/// different production lines, so they must never end up consecutive in one
/// line's key sequence.
void printLanes(List<Belt> belts, Tol t) {
  final pairs = allEdges(belts, t).where((e) => e.kind == Link.parallel).toList();
  stdout.writeln('${pairs.length} lane-neighbour pairs (same axis, offset sideways)');
  pairs.sort((p, q) => p.from.index.compareTo(q.from.index));
  for (final e in pairs) {
    final off = e.from.perpOffsetTo(e.to);
    stdout.writeln('  idx ${e.from.index.toString().padRight(4)}<-> idx ${e.to.index.toString().padRight(4)}'
        'offset ${off.toStringAsFixed(3)}  '
        '${e.from.key.isEmpty ? '(none)' : e.from.key} | ${e.to.key.isEmpty ? '(none)' : e.to.key}');
  }
}

/// Keys bound to more than one asset, and assets with no key. One drive cannot
/// run thirteen belts, so a duplicate is always a copy-paste that was never
/// finished.
void printValidation(List<Belt> belts) {
  final byKey = <String, List<int>>{};
  for (final b in belts) {
    byKey.putIfAbsent(b.key, () => []).add(b.index);
  }
  final dups = byKey.entries.where((e) => e.value.length > 1).toList()
    ..sort((p, q) => q.value.length.compareTo(p.value.length));
  stdout.writeln('duplicate / placeholder keys:');
  for (final e in dups) {
    stdout.writeln('  ${(e.key.isEmpty ? '(none)' : e.key).padRight(24)}'
        'x${e.value.length.toString().padRight(4)}idx ${e.value.join(' ')}');
  }
  final unique = byKey.entries.where((e) => e.value.length == 1 && e.key.isNotEmpty).length;
  stdout.writeln('\n${belts.length} conveyors, $unique uniquely keyed, '
      '${belts.length - unique} needing attention');
}

/// Scores a notarised prediction file against what the page holds now.
void printScore(List<dynamic> assets, String path) {
  final rec = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final preds = rec['predictions'] as List<dynamic>;
  var right = 0, wrong = 0, moved = 0;
  stdout.writeln('idx   predicted                 actual                    verdict');
  for (final p in preds) {
    final m = p as Map<String, dynamic>;
    final idx = m['index'] as int;
    final predicted = m['predicted_key'] as String;
    if (idx >= assets.length) {
      moved++;
      stdout.writeln('${idx.toString().padRight(6)}${predicted.padRight(26)}'
          '${'(index gone)'.padRight(26)}INDEX MOVED');
      continue;
    }
    final a = assets[idx] as Map<String, dynamic>;
    if (a['asset_name'] != m['asset_name']) {
      moved++;
      stdout.writeln('${idx.toString().padRight(6)}${predicted.padRight(26)}'
          '${(a['asset_name'] as String).padRight(26)}INDEX MOVED');
      continue;
    }
    final actual = (a['key'] as String?) ?? '';
    final ok = actual == predicted;
    ok ? right++ : wrong++;
    stdout.writeln('${idx.toString().padRight(6)}${predicted.padRight(26)}'
        '${(actual.isEmpty ? '(none)' : actual).padRight(26)}${ok ? 'ok' : 'WRONG'}');
  }
  final scored = right + wrong;
  stdout.writeln('\n$right/$scored correct'
      '${moved > 0 ? ', $moved skipped (index moved)' : ''}');
}

// -- main -------------------------------------------------------------------

void main(List<String> argv) {
  final parser = ArgParser()
    ..addOption('page', help: 'Page key, e.g. /boxes/freezers')
    ..addOption('prefs', help: 'Path to shared_preferences.json')
    ..addOption('chain', help: 'Walk the chain from this asset index')
    ..addOption('score', help: 'Score a notarised predictions JSON against the page')
    ..addFlag('runs', negatable: false, help: 'Group belts into collinear runs')
    ..addFlag('lanes', negatable: false, help: 'List lane-neighbour pairs')
    ..addFlag('validate', negatable: false, help: 'Report duplicate and missing keys')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args['help'] as bool || args['page'] == null) {
    stdout.writeln('Reports how a page\'s conveyors connect.\n');
    stdout.writeln(parser.usage);
    return;
  }

  final prefs = (args['prefs'] as String?) ?? _defaultPrefsPath();
  if (prefs == null || !File(prefs).existsSync()) {
    stderr.writeln('preferences file not found: ${prefs ?? '(no default for this platform)'}');
    exitCode = 2;
    return;
  }

  final assets = loadAssets(prefs, args['page'] as String);
  final belts = beltsOf(assets);
  const tol = Tol();

  stdout.writeln('page ${args['page']}  ${assets.length} assets, ${belts.length} conveyors\n');

  if (args['score'] != null) {
    printScore(assets, args['score'] as String);
    return;
  }
  if (args['chain'] != null) {
    printChain(belts, int.parse(args['chain'] as String), tol);
    return;
  }
  if (args['runs'] as bool) {
    printRuns(belts, tol);
    return;
  }
  if (args['lanes'] as bool) {
    printLanes(belts, tol);
    return;
  }
  if (args['validate'] as bool) {
    printValidation(belts);
    return;
  }
  printInventory(belts);
}
