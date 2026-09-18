import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:rxdart/rxdart.dart';

import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show HmiStateColors;
import 'package:tfc/widgets/dynamic_value.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/tag_access_guard.dart';
import 'package:tfc_access/tfc_access.dart' show AccessDenied;
import 'package:tfc_dart/converter/dynamic_value_converter.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:open62541/open62541.dart' show DynamicValue;

part 'recipes.g.dart';
part 'recipes_dialog.dart';

@JsonSerializable(explicitToJson: true)
class RecipesConfig extends BaseAsset {
  @override
  String get displayName => 'Recipes';
  @override
  String get category => 'Application';

  /// Legacy single key: one node holding an ARRAY of line recipes.
  ///
  /// This is how the oldest PLC code published them -- one array covering
  /// every line, which is why the line pills were numbered by array position.
  /// Kept so existing pages keep working.
  String key;

  /// One key per line, in the order the lines appear.
  ///
  /// Current PLCs publish a separate recipe struct per station rather than one
  /// array, so a single key cannot reach them all. When this is non-empty it
  /// takes precedence over [key], and each line is read and written on its own
  /// node -- which also means sending a recipe to one line no longer rewrites
  /// the others, as writing the whole array back did.
  @JsonKey(defaultValue: <String>[])
  List<String> keys;

  /// What one line is called: "Line" unless the page says otherwise.
  String label;

  /// What more than one line is called. Empty means [label] plus "s".
  ///
  /// A field of its own because adding an "s" is English, and not always
  /// even that. The dialog's view switch reads `<groups> | <lines>`, so the
  /// plural is on screen every time the dialog opens.
  @JsonKey(defaultValue: '')
  String labelPlural;

  /// What one group of recipes is called. "Product" by default.
  ///
  /// A group is one recipe per line, sent together — for this plant, one
  /// product. Another machine groups by something else, so the word is the
  /// page's to choose rather than the code's.
  @JsonKey(defaultValue: 'Product')
  String groupLabel;

  /// What more than one group is called. Empty means [groupLabel] plus "s".
  @JsonKey(defaultValue: '')
  String groupLabelPlural;

  RecipesConfig({
    required this.key,
    required this.label,
    this.keys = const <String>[],
    this.labelPlural = '',
    this.groupLabel = 'Product',
    this.groupLabelPlural = '',
  });

  /// The keys actually in play, whichever way this asset is configured.
  List<String> get lineKeys =>
      keys.isNotEmpty ? keys : (key.isEmpty ? const <String>[] : <String>[key]);

  /// True when each line has its own node, so values are read and written
  /// per line instead of as one array.
  bool get perLineKeys => keys.isNotEmpty;

  /// Where saved recipes live. Stable across a switch from [key] to [keys] so
  /// presets defined before the move are not orphaned.
  String get recipesBucket =>
      key.isNotEmpty ? key : (keys.isEmpty ? '' : keys.first);

  /// The word for one line, never empty.
  String get lineNoun => label.trim().isEmpty ? 'Line' : label.trim();

  /// The word for several lines.
  String get lineNounPlural =>
      labelPlural.trim().isEmpty ? '${lineNoun}s' : labelPlural.trim();

  /// The word for one group, never empty.
  String get groupNoun =>
      groupLabel.trim().isEmpty ? 'Product' : groupLabel.trim();

  /// The word for several groups.
  String get groupNounPlural => groupLabelPlural.trim().isEmpty
      ? '${groupNoun}s'
      : groupLabelPlural.trim();

  factory RecipesConfig.fromJson(Map<String, dynamic> json) =>
      _$RecipesConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$RecipesConfigToJson(this);

  @override
  Widget build(BuildContext context) => Recipes(config: this);

  static const previewStr = 'Recipes preview';

  RecipesConfig.preview()
      : key = '',
        keys = const <String>[],
        label = 'Line',
        labelPlural = '',
        groupLabel = 'Product',
        groupLabelPlural = '';

  @override
  Widget configure(BuildContext context) => _RecipesConfigEditor(config: this);
}

// explicitToJson so `toJson` hands back plain JSON all the way down: anything
// that reads `toJson()` directly — a copy, a comparison, a test — gets maps,
// not objects, and `fromJson` takes them straight back.
@JsonSerializable(explicitToJson: true)
class Recipe {
  /// The operator's name for it.
  ///
  /// For a recipe in a group the dialog shows the GROUP's name instead — on
  /// the Lines view the line is already the tab, so "Standard" is the whole
  /// story. The name is still kept, and kept meaningful ("Line 2 -
  /// Standard"), because a station still on an older build reads this same
  /// list and knows nothing about groups.
  String name;

  @DynamicValueConverter()
  DynamicValue value;

  /// The line this recipe belongs to, by its KEY — never by its position.
  ///
  /// A position would be repointed by reordering the keys in the asset
  /// settings, silently sending a recipe to a different PLC. Null for every
  /// recipe saved before recipes knew their line: those are offered on every
  /// line, as they always were.
  String? line;

  /// The group this recipe is in, or null when it is in none.
  ///
  /// A group is at most one recipe per line. Each is captured from — and
  /// kept for — its own line, so it always fits that line: the lines on a
  /// plant do not share a struct shape, and a group never asks them to.
  String? group;

  Recipe({
    required this.name,
    required this.value,
    this.line,
    this.group,
  });

  factory Recipe.fromJson(Map<String, dynamic> json) => _$RecipeFromJson(json);
  Map<String, dynamic> toJson() => _$RecipeToJson(this);
}

/// The recipe list for [bucket], seeding an empty one when the station has
/// none.
///
/// **The seed goes through [systemWrites] and that is not a convenience.**
/// This runs on the *read* path: it fires whenever any session merely opens a
/// recipes asset, not once at startup. `<bucket>.recipes` is a `setpoints`
/// key, so on the guarded store an anonymous operator looking at a recipe
/// would be refused and shown a denial prompt for doing nothing but looking.
/// Writing an empty default because storage is empty is the app initialising
/// itself, not a person changing a recipe.
///
/// [writeRecipes] — the Save button — is deliberately not given the same
/// treatment. See it.
Future<List<Recipe>> readRecipes(
    Preferences prefs, Preferences systemWrites, String bucket) async {
  final prefKey = '$bucket.recipes';
  if (!(await prefs.containsKey(prefKey))) {
    await systemWrites.setString(prefKey, jsonEncode(<Recipe>[]));
  }
  final str = await prefs.getString(prefKey);
  final decoded = jsonDecode(str ?? '[]') as List<dynamic>;
  return decoded.map((item) => Recipe.fromJson(item)).toList();
}

/// [readRecipes] against the stores the app provides.
///
/// Here, beside [readRecipes], and not in the dialog: the seed's write goes
/// through the system store, and this file is the one
/// `kSystemWriteCallSites` names for it. The dialog asks for its recipes
/// through this and never touches that store itself.
Future<List<Recipe>> _loadRecipes(WidgetRef ref, String bucket) async =>
    readRecipes(
      await ref.read(preferencesProvider.future),
      await ref.read(systemPreferencesProvider.future),
      bucket,
    );

/// Saves [recipes] for [bucket], **through the guarded store**.
///
/// A person changed a recipe. `<bucket>.recipes` is a `setpoints` key and this
/// is the write the Shift Leader requirement is about: it must be checked and
/// it must land in the audit trail with a name against it. It shares a key
/// with [readRecipes]' seed and must never share its path.
Future<void> writeRecipes(
    Preferences prefs, String bucket, List<Recipe> recipes) async {
  await prefs.setString('$bucket.recipes', jsonEncode(recipes));
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

/// The groups, in the order the operator arranged them: a group sits where
/// its first recipe sits in the list.
List<String> recipeGroups(List<Recipe> recipes) {
  final seen = <String>[];
  for (final recipe in recipes) {
    final group = recipe.group;
    if (group != null && !seen.contains(group)) seen.add(group);
  }
  return seen;
}

/// The recipe [group] holds for [lineId], or null when it has none.
Recipe? recipeInGroup(List<Recipe> recipes, String group, String lineId) {
  for (final recipe in recipes) {
    if (recipe.group == group && recipe.line == lineId) return recipe;
  }
  return null;
}

/// The recipes offered on [lineId]: the ones kept for it, and the ones saved
/// before recipes knew their line, which have always been offered
/// everywhere.
List<Recipe> recipesOnLine(List<Recipe> recipes, String lineId) => [
      for (final recipe in recipes)
        if (recipe.line == null || recipe.line == lineId) recipe
    ];

/// Whether [recipe] may join [group] without the group then holding two
/// recipes for one line.
///
/// One per line is what makes a group sendable in one press: with two, which
/// one Line 2 gets would be a guess.
bool canJoinGroup(List<Recipe> recipes, Recipe recipe, String group) {
  final line = recipe.line;
  if (line == null) return false;
  final holder = recipeInGroup(recipes, group, line);
  return holder == null || identical(holder, recipe);
}

/// Moves every recipe of [group] so the group sits at [newIndex] among the
/// groups, keeping each recipe's place relative to the others.
///
/// Groups have no order of their own — a group sits where its first recipe
/// sits — so reordering groups means reordering the recipes, as one block.
void moveRecipeGroup(List<Recipe> recipes, String group, int newIndex) {
  final groups = recipeGroups(recipes)..remove(group);
  final target = newIndex.clamp(0, groups.length);
  final members = [
    for (final r in recipes)
      if (r.group == group) r
  ];
  recipes.removeWhere((r) => r.group == group);
  if (target >= groups.length) {
    // Behind the last group: straight after that group's last recipe, so the
    // ungrouped recipes keep their places.
    final lastGroup = groups.isEmpty ? null : groups.last;
    final after = lastGroup == null
        ? -1
        : recipes.lastIndexWhere((r) => r.group == lastGroup);
    recipes.insertAll(after + 1, members);
    return;
  }
  final before = recipes.indexWhere((r) => r.group == groups[target]);
  recipes.insertAll(before, members);
}

/// One recipe the first-open grouping would file, and where.
@immutable
class RecipeGrouping {
  const RecipeGrouping(this.recipe, this.line, this.group);

  final Recipe recipe;

  /// The line id its name points at.
  final String line;

  /// The group its name puts it in.
  final String group;
}

/// Reads "Line 2 - Standard" back into a line number and a group name.
///
/// Stations accumulated exactly this naming habit, because until now one list
/// served every line and the name was the only place to say which line a
/// preset was for. [lineNoun] is the asset's own word for a line, so an asset
/// that calls them something else is read in its own terms.
({int number, String group})? parseLineRecipeName(
    String name, String lineNoun) {
  final noun = lineNoun.trim();
  if (noun.isEmpty) return null;
  final match = RegExp(
    '^\\s*${RegExp.escape(noun)}\\s*(\\d+)(?!\\d)\\s*[-–—:.]?\\s*(.*\\S)\\s*\$',
    caseSensitive: false,
  ).firstMatch(name);
  if (match == null) return null;
  return (number: int.parse(match.group(1)!), group: match.group(2)!);
}

/// What the first-open grouping proposes: every recipe that names a line in
/// its name and has not been filed yet, grouped by the rest of its name.
///
/// Never applied by itself. A name is the operator's own words, so this is
/// shown, and applied by one press, and nothing is sent to a line either way —
/// only the list is rearranged. A second recipe for a line already taken in
/// the same group is left alone rather than guessed between.
List<RecipeGrouping> proposeRecipeGrouping(
    List<Recipe> recipes, String lineNoun, List<String> lineIds) {
  final found = <RecipeGrouping>[];
  final taken = <(String, String)>{
    for (final r in recipes)
      if (r.group != null && r.line != null) (r.group!, r.line!),
  };
  // Groups compared without case, and spelled the way they were first seen:
  // "standard" and "Standard" are one product, not two.
  final spelling = <String, String>{
    for (final g in recipeGroups(recipes)) g.toLowerCase(): g,
  };
  for (final recipe in recipes) {
    if (recipe.group != null || recipe.line != null) continue;
    final parsed = parseLineRecipeName(recipe.name, lineNoun);
    if (parsed == null) continue;
    if (parsed.number < 1 || parsed.number > lineIds.length) continue;
    final line = lineIds[parsed.number - 1];
    if (line.isEmpty) continue;
    final group =
        spelling.putIfAbsent(parsed.group.toLowerCase(), () => parsed.group);
    if (!taken.add((group, line))) continue;
    found.add(RecipeGrouping(recipe, line, group));
  }
  return found;
}

/// Files every recipe in [proposal] into its line and group.
void applyRecipeGrouping(List<RecipeGrouping> proposal) {
  for (final item in proposal) {
    item.recipe
      ..line = item.line
      ..group = item.group;
  }
}

/// How many values sending [recipeValue] to [lineValue] would change — zero
/// when the line is already running it (see [recipeIsActiveOn]).
int recipeChangeCount(DynamicValue recipeValue, DynamicValue lineValue) {
  final result = mergeRecipeInto(lineValue, recipeValue);
  return _countChangedLeaves(result.merged, lineValue);
}

int _countChangedLeaves(DynamicValue a, DynamicValue b) {
  if (a.isObject && b.isObject) {
    var total = 0;
    for (final entry in a.asObject.entries) {
      final other = b.asObject[entry.key];
      total += other == null ? 1 : _countChangedLeaves(entry.value, other);
    }
    return total;
  }
  if (a.isArray && b.isArray) {
    var total = 0;
    final left = a.asArray;
    final right = b.asArray;
    for (var i = 0; i < left.length; i++) {
      total += i < right.length ? _countChangedLeaves(left[i], right[i]) : 1;
    }
    return total;
  }
  if (a.isObject || a.isArray || b.isObject || b.isArray) return 1;
  return a.value == b.value ? 0 : 1;
}

/// Where one line stands against the recipe a group holds for it.
enum LineRecipeState {
  /// The group has no recipe for this line.
  noRecipe,

  /// The line has not reported a value yet.
  waiting,

  /// Sending would change nothing: the line is running this recipe.
  running,

  /// Sending would change [LineRecipeStatus.changes] values.
  differs,

  /// None of the recipe lands on this line. Captured from the line, a recipe
  /// always fits it — so this is a line whose PLC type changed since.
  doesNotFit,
}

/// One line's standing, and how many values a send would change.
typedef LineRecipeStatus = ({LineRecipeState state, int changes});

/// Where [live] stands against [recipe] — the facts every line card is built
/// from, derived fresh from the live value every time. A remembered "last
/// sent" would go on claiming a line was running a recipe long after someone
/// turned a setpoint by hand on the panel.
LineRecipeStatus lineRecipeStatus(Recipe? recipe, DynamicValue? live) {
  if (recipe == null) return (state: LineRecipeState.noRecipe, changes: 0);
  if (live == null) return (state: LineRecipeState.waiting, changes: 0);
  final fit = recipeFitFor(recipe.value, live);
  if (fit.none) return (state: LineRecipeState.doesNotFit, changes: 0);
  final changes = recipeChangeCount(recipe.value, live);
  return changes == 0
      ? (state: LineRecipeState.running, changes: 0)
      : (state: LineRecipeState.differs, changes: changes);
}

// ---------------------------------------------------------------------------
// Merging a recipe into a line
// ---------------------------------------------------------------------------

/// Why one leaf of a recipe did not reach the line it was sent to.
enum RecipeSkipReason {
  /// The target has no member (or no array element) at that path at all.
  ///
  /// Lines are allowed to differ: a two-conveyor line simply has no third
  /// conveyor, and a recipe captured on a three-conveyor line must not grow
  /// one.
  notPresent,

  /// The path exists on both sides but is a different kind of thing — a
  /// struct where the recipe holds a number, a string where it holds a
  /// boolean. Writing across that is a guess, so it is not written.
  shapeDiffers,

  /// The recipe itself has no value there, so there is nothing to send.
  noValue,
}

/// One leaf of the recipe that was not written, and why.
@immutable
class RecipeSkip {
  const RecipeSkip(this.path, this.reason);

  /// Dotted/indexed path, as [recipePathLabel] renders it.
  final String path;
  final RecipeSkipReason reason;

  @override
  String toString() => '$path (${reason.name})';

  @override
  bool operator ==(Object other) =>
      other is RecipeSkip && other.path == path && other.reason == reason;

  @override
  int get hashCode => Object.hash(path, reason);
}

/// What merging a recipe into one line produced.
@immutable
class RecipeMergeResult {
  const RecipeMergeResult({
    required this.merged,
    required this.written,
    required this.skipped,
    required this.untouched,
  });

  /// The value to write: the **target's** shape, with the recipe's values in
  /// the members both sides have.
  final DynamicValue merged;

  /// Paths of the recipe leaves whose values landed in [merged].
  final List<String> written;

  /// Recipe leaves that did not land, with the reason each one did not.
  final List<RecipeSkip> skipped;

  /// Topmost paths the target has and the recipe does not — left exactly as
  /// they were. A recipe captured on a shorter line leaves the extra conveyor
  /// of a longer one alone, and the operator is told so rather than left to
  /// assume the whole line was set.
  final List<String> untouched;

  /// Leaves the recipe offered, written or not.
  int get offered => written.length + skipped.length;
}

/// Merges [recipe] into [target] member by member, **never changing the
/// target's shape**.
///
/// The lines on a plant are not obliged to be identical, and in practice they
/// are not: one may drive two conveyors where its neighbours drive three. A
/// whole-struct copy is therefore not available. Writing a three-conveyor
/// recipe onto a two-conveyor line either fails outright or, worse, is
/// accepted with a silently different meaning.
///
/// So this walks the recipe and copies only what the target already has:
///
///  * a member the target does not have is skipped, never added;
///  * an array is visited only as far as the **target's** length, never
///    lengthened and never shortened;
///  * a leaf is written only when both sides are the same kind of value, and
///    then coerced to the target's own type, so a preset that round-tripped
///    through JSON as an integer still lands in a REAL member as a real;
///  * a member the target has and the recipe does not is left untouched.
///
/// The result is always safe to write back: it is [target] with some values
/// replaced, and nothing else.
RecipeMergeResult mergeRecipeInto(DynamicValue target, DynamicValue recipe) {
  final merged = DynamicValue.from(target);
  final written = <String>[];
  final skipped = <RecipeSkip>[];
  final untouched = <String>[];
  _mergeNode(merged, recipe, const <Object>[], written, skipped, untouched);
  return RecipeMergeResult(
    merged: merged,
    written: written,
    skipped: skipped,
    untouched: untouched,
  );
}

/// Depth cap, so a pathological value cannot take the UI down with it.
const int _maxRecipeDepth = 16;

void _mergeNode(
  DynamicValue target,
  DynamicValue source,
  List<Object> path,
  List<String> written,
  List<RecipeSkip> skipped,
  List<String> untouched,
) {
  if (path.length >= _maxRecipeDepth) {
    _skipSubtree(source, path, skipped, RecipeSkipReason.shapeDiffers);
    return;
  }

  if (source.isObject) {
    if (!target.isObject) {
      _skipSubtree(source, path, skipped, RecipeSkipReason.shapeDiffers);
      return;
    }
    for (final entry in source.asObject.entries) {
      final childPath = <Object>[...path, entry.key];
      if (!target.contains(entry.key)) {
        _skipSubtree(
            entry.value, childPath, skipped, RecipeSkipReason.notPresent);
        continue;
      }
      _mergeNode(target[entry.key], entry.value, childPath, written, skipped,
          untouched);
    }
    for (final name in target.asObject.keys) {
      if (!source.contains(name)) {
        untouched.add(recipePathLabel(<Object>[...path, name]));
      }
    }
    return;
  }

  if (source.isArray) {
    if (!target.isArray) {
      _skipSubtree(source, path, skipped, RecipeSkipReason.shapeDiffers);
      return;
    }
    final sourceItems = source.asArray;
    final targetLength = target.asArray.length;
    for (var i = 0; i < sourceItems.length; i++) {
      final childPath = <Object>[...path, i];
      if (i >= targetLength) {
        _skipSubtree(
            sourceItems[i], childPath, skipped, RecipeSkipReason.notPresent);
        continue;
      }
      _mergeNode(
          target[i], sourceItems[i], childPath, written, skipped, untouched);
    }
    for (var i = sourceItems.length; i < targetLength; i++) {
      untouched.add(recipePathLabel(<Object>[...path, i]));
    }
    return;
  }

  // A leaf on the recipe side.
  final label = recipePathLabel(path);
  if (source.isNull) {
    skipped.add(RecipeSkip(label, RecipeSkipReason.noValue));
    return;
  }
  if (target.isObject || target.isArray) {
    skipped.add(RecipeSkip(label, RecipeSkipReason.shapeDiffers));
    return;
  }
  if (!_assignLeaf(target, source)) {
    skipped.add(RecipeSkip(label, RecipeSkipReason.shapeDiffers));
    return;
  }
  written.add(label);
}

/// Copies [source]'s value into [target], coerced to the type [target]
/// already is. False when the two are not the same kind of value.
bool _assignLeaf(DynamicValue target, DynamicValue source) {
  if (target.isNull) {
    // The line has the member but has never carried a value in it. There is
    // no target type to honour, so take the recipe's as it stands.
    target.value = source.value;
    return true;
  }
  if (target.isBoolean) {
    if (!source.isBoolean) return false;
    target.value = source.asBool;
    return true;
  }
  if (target.isString) {
    if (!source.isString) return false;
    target.value = source.asString;
    return true;
  }
  if (target.isInteger) {
    if (!source.isInteger && !source.isDouble) return false;
    target.value = source.asInt;
    return true;
  }
  if (target.isDouble) {
    if (!source.isInteger && !source.isDouble) return false;
    target.value = source.asDouble;
    return true;
  }
  return false;
}

void _skipSubtree(DynamicValue source, List<Object> path,
    List<RecipeSkip> skipped, RecipeSkipReason reason) {
  if (path.length >= _maxRecipeDepth || !(source.isObject || source.isArray)) {
    skipped.add(RecipeSkip(recipePathLabel(path), reason));
    return;
  }
  if (source.isObject) {
    for (final entry in source.asObject.entries) {
      _skipSubtree(entry.value, <Object>[...path, entry.key], skipped, reason);
    }
    return;
  }
  final items = source.asArray;
  for (var i = 0; i < items.length; i++) {
    _skipSubtree(items[i], <Object>[...path, i], skipped, reason);
  }
}

/// `conveyors[1].driveDistance` — how a path is named to an operator.
String recipePathLabel(List<Object> path) {
  final buffer = StringBuffer();
  for (final part in path) {
    if (part is int) {
      buffer.write('[$part]');
    } else {
      if (buffer.isNotEmpty) buffer.write('.');
      buffer.write(part);
    }
  }
  return buffer.isEmpty ? 'value' : buffer.toString();
}

/// One line's half of a send, in the words the dialog shows.
///
/// Every line is its own controller, so a send is several independent writes
/// and there is no transaction across them. The wording says so: each line
/// reports what happened to it, and a line that failed says so beside lines
/// that succeeded.
@immutable
class LineSendOutcome {
  const LineSendOutcome({
    required this.label,
    required this.ok,
    required this.message,
  });

  final String label;
  final bool ok;
  final String message;
}

/// The sentence one line's [RecipeMergeResult] earns.
String describeMerge(RecipeMergeResult result) {
  final offered = result.offered;
  if (offered == 0) return 'the recipe has no values to send';
  final written = result.written.length;
  final parts = <String>[
    written == offered
        ? 'all $written values written'
        : '$written of $offered values written',
  ];

  final absent = result.skipped
      .where((s) => s.reason == RecipeSkipReason.notPresent)
      .map((s) => s.path)
      .toList();
  if (absent.isNotEmpty) {
    parts.add('${_summarisePaths(absent)} not present');
  }

  final differs = result.skipped
      .where((s) => s.reason == RecipeSkipReason.shapeDiffers)
      .map((s) => s.path)
      .toList();
  if (differs.isNotEmpty) {
    parts.add('${_summarisePaths(differs)} a different type here');
  }

  final empty = result.skipped
      .where((s) => s.reason == RecipeSkipReason.noValue)
      .map((s) => s.path)
      .toList();
  if (empty.isNotEmpty) {
    parts.add('${_summarisePaths(empty)} empty in the recipe');
  }

  if (result.untouched.isNotEmpty) {
    parts.add('${_summarisePaths(result.untouched)} left unchanged');
  }

  return parts.join(', ');
}

/// Names the first few paths and counts the rest, so one odd line does not
/// push a paragraph into the dialog.
String _summarisePaths(List<String> paths) {
  const shown = 3;
  if (paths.length <= shown) return paths.join(', ');
  final rest = paths.length - shown;
  return '${paths.take(shown).join(', ')} and $rest more';
}

// ---------------------------------------------------------------------------
// Whether a recipe applies to a line at all
// ---------------------------------------------------------------------------

/// How much of a recipe a line can actually take.
///
/// Computed by the same [mergeRecipeInto] the send performs, so what the
/// dialog promises and what the write does cannot drift apart.
@immutable
class RecipeFit {
  const RecipeFit({
    required this.applies,
    required this.skipped,
    required this.known,
  });

  /// The line has not reported yet, so nothing can be said about it.
  const RecipeFit.unknown()
      : applies = 0,
        skipped = const <RecipeSkip>[],
        known = false;

  /// Recipe leaves this line would take.
  final int applies;

  /// Recipe leaves this line has no home for.
  final List<RecipeSkip> skipped;

  /// False while the line has not reported a value.
  final bool known;

  int get offered => applies + skipped.length;

  /// Every leaf lands: the recipe is simply this line's recipe.
  bool get whole => known && skipped.isEmpty && applies > 0;

  /// Some land and some do not.
  bool get partial => known && skipped.isNotEmpty && applies > 0;

  /// Nothing lands — the recipe is not about this line at all.
  bool get none => known && applies == 0;
}

/// Whether [lineValue] already holds what [recipeValue] would write.
///
/// "Active" is not a flag the PLC publishes and there is nowhere to store one
/// that would stay true — an operator can turn a setpoint by hand a second
/// after a recipe is sent. So it is derived: a recipe is active on a line
/// when sending it would change nothing. That is honest about what is known,
/// and it goes stale the moment the line stops matching, which is exactly
/// when it should.
///
/// A recipe with nothing to write to this line is never active on it, however
/// equal the empty comparison would be.
bool recipeIsActiveOn(DynamicValue recipeValue, DynamicValue? lineValue) {
  if (lineValue == null) return false;
  final result = mergeRecipeInto(lineValue, recipeValue);
  if (result.written.isEmpty) return false;
  return _sameValues(result.merged, lineValue);
}

bool _sameValues(DynamicValue a, DynamicValue b) {
  if (a.isObject || b.isObject) {
    if (!a.isObject || !b.isObject) return false;
    final left = a.asObject;
    final right = b.asObject;
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      final other = right[entry.key];
      if (other == null || !_sameValues(entry.value, other)) return false;
    }
    return true;
  }
  if (a.isArray || b.isArray) {
    if (!a.isArray || !b.isArray) return false;
    final left = a.asArray;
    final right = b.asArray;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_sameValues(left[i], right[i])) return false;
    }
    return true;
  }
  return a.value == b.value;
}

/// What [recipeValue] would do to [lineValue].
RecipeFit recipeFitFor(DynamicValue recipeValue, DynamicValue? lineValue) {
  if (lineValue == null) return const RecipeFit.unknown();
  final result = mergeRecipeInto(lineValue, recipeValue);
  return RecipeFit(
    applies: result.written.length,
    skipped: result.skipped,
    known: true,
  );
}

String _joinLabels(List<String> labels) {
  if (labels.length == 1) return labels.single;
  return '${labels.take(labels.length - 1).join(', ')} and ${labels.last}';
}

// ---------------------------------------------------------------------------
// Flattening a nested struct into comparable rows
// ---------------------------------------------------------------------------

/// What a [RecipeRow] stands for.
enum RecipeRowKind { leaf, object, array }

/// One row of the comparison table: a member of the struct, at a depth, with
/// the path each column looks its own value up by.
@immutable
class RecipeRow {
  const RecipeRow({
    required this.path,
    required this.label,
    required this.depth,
    required this.kind,
  });

  final List<Object> path;
  final String label;
  final int depth;
  final RecipeRowKind kind;

  bool get isLeaf => kind == RecipeRowKind.leaf;
}

/// Flattens every source into one indented row list, so a member's recipe
/// value and each line's live value land on the same row.
///
/// The rows are the **union** of the sources, in the order the first source
/// that has them declares them. That is what makes a shape difference visible
/// instead of confusing: a conveyor only two of three lines have still gets a
/// row, and the lines without it say so in their own cell rather than
/// rendering a blank or a zero that reads as "off".
List<RecipeRow> flattenRecipeShape(List<DynamicValue?> sources) {
  final rows = <RecipeRow>[];
  _flattenInto(rows, sources, const <Object>[], 0);
  return rows;
}

void _flattenInto(List<RecipeRow> rows, List<DynamicValue?> nodes,
    List<Object> path, int depth) {
  if (depth >= _maxRecipeDepth) return;
  final present = nodes.whereType<DynamicValue>().toList();

  if (present.any((n) => n.isObject)) {
    final names = <String>[];
    for (final node in present) {
      if (!node.isObject) continue;
      for (final name in node.asObject.keys) {
        if (!names.contains(name)) names.add(name);
      }
    }
    for (final name in names) {
      final childPath = <Object>[...path, name];
      final children = <DynamicValue?>[
        for (final node in nodes)
          (node != null && node.contains(name)) ? node[name] : null,
      ];
      rows.add(RecipeRow(
        path: childPath,
        label: prettifyMemberName(name),
        depth: depth,
        kind: _kindOf(children),
      ));
      if (_kindOf(children) != RecipeRowKind.leaf) {
        _flattenInto(rows, children, childPath, depth + 1);
      }
    }
    return;
  }

  if (present.any((n) => n.isArray)) {
    var longest = 0;
    for (final node in present) {
      if (node.isArray && node.asArray.length > longest) {
        longest = node.asArray.length;
      }
    }
    for (var i = 0; i < longest; i++) {
      final childPath = <Object>[...path, i];
      final children = <DynamicValue?>[
        for (final node in nodes)
          (node != null && node.contains(i)) ? node[i] : null,
      ];
      rows.add(RecipeRow(
        path: childPath,
        label: 'Item ${i + 1}',
        depth: depth,
        kind: _kindOf(children),
      ));
      if (_kindOf(children) != RecipeRowKind.leaf) {
        _flattenInto(rows, children, childPath, depth + 1);
      }
    }
  }
}

RecipeRowKind _kindOf(List<DynamicValue?> nodes) {
  for (final node in nodes) {
    if (node == null) continue;
    if (node.isObject) return RecipeRowKind.object;
    if (node.isArray) return RecipeRowKind.array;
  }
  return RecipeRowKind.leaf;
}

/// The value at [path], or null when this source does not have one there.
DynamicValue? valueAtPath(DynamicValue? root, List<Object> path) {
  var node = root;
  for (final part in path) {
    if (node == null || !node.contains(part)) return null;
    node = node[part];
  }
  return node;
}

/// A copy of [root] with the value at [path] replaced.
///
/// Used only for the recipe being edited, never for a line: the recipe is the
/// operator's own document and may take any shape they give it.
DynamicValue setAtPath(
    DynamicValue root, List<Object> path, DynamicValue leaf) {
  if (path.isEmpty) return DynamicValue.from(leaf);
  final copy = DynamicValue.from(root);
  var node = copy;
  for (var i = 0; i < path.length - 1; i++) {
    if (!node.contains(path[i])) return copy;
    node = node[path[i]];
  }
  if (!node.contains(path.last)) return copy;
  node[path.last] = leaf;
  return copy;
}

/// snake_case and camelCase member names, as an operator should read them.
String prettifyMemberName(String label) {
  String withSpaces = label.replaceAllMapped(
    RegExp(r'(_)|([A-Z])'),
    (match) {
      if (match.group(1) != null) return ' ';
      if (match.group(2) != null) return ' ${match.group(2)}';
      return '';
    },
  );
  withSpaces = withSpaces.trimLeft();
  if (withSpaces.isEmpty) return '';
  return withSpaces[0].toUpperCase() + withSpaces.substring(1);
}

/// The text a read-only cell shows for [value].
String formatRecipeValue(DynamicValue value) {
  if (value.isNull) return 'empty';
  final enums = value.enumFields;
  if (enums != null) {
    final field = enums[value.value];
    if (field != null) return field.displayName.value;
  }
  if (value.isBoolean) return value.asBool ? 'Yes' : 'No';
  if (value.isArray) {
    final length = value.asArray.length;
    return length == 1 ? '1 item' : '$length items';
  }
  if (value.isObject) return '';
  return value.asString;
}

// ---------------------------------------------------------------------------
// Configuration editor
// ---------------------------------------------------------------------------

class _RecipesConfigEditor extends StatefulWidget {
  final RecipesConfig config;
  const _RecipesConfigEditor({required this.config});

  @override
  State<_RecipesConfigEditor> createState() => _RecipesConfigEditorState();
}

class _RecipesConfigEditorState extends State<_RecipesConfigEditor> {
  late final _label = TextEditingController(text: widget.config.label);
  late final _labelPlural =
      TextEditingController(text: widget.config.labelPlural);
  late final _groupLabel =
      TextEditingController(text: widget.config.groupLabel);
  late final _groupLabelPlural =
      TextEditingController(text: widget.config.groupLabelPlural);

  @override
  void dispose() {
    _label.dispose();
    _labelPlural.dispose();
    _groupLabel.dispose();
    _groupLabelPlural.dispose();
    super.dispose();
  }

  Widget _nameField(TextEditingController controller, String hint,
          ValueChanged<String> onChanged) =>
      TextField(
        controller: controller,
        decoration: InputDecoration(hintText: hint, isDense: true),
        onChanged: (val) => setState(() => onChanged(val)),
      );

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final heading = Theme.of(context).textTheme.titleMedium;
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Keys, one per line', style: heading),
          const Text(
            "Each key is one line's recipe node, in the order the lines "
            "appear. Leave empty to use the single key below, which expects "
            "one node holding an array of every line.",
            style: TextStyle(fontSize: 12),
          ),
          for (var i = 0; i < config.keys.length; i++)
            Row(
              children: [
                Expanded(
                  child: KeyField(
                    initialValue: config.keys[i],
                    onChanged: (val) => setState(() => config.keys[i] = val),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Remove this line',
                  onPressed: () => setState(() => config.keys.removeAt(i)),
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add line'),
              onPressed: () => setState(() {
                // A growable copy: the generated fromJson can hand back a
                // fixed-length list, which would throw on add.
                config.keys = [...config.keys, ''];
              }),
            ),
          ),
          const SizedBox(height: 16),
          // The two words the dialog is written in. Both are the page's to
          // choose — "Product" is right for one plant and wrong for the next
          // — and both have a plural of their own, because "add an s" is not
          // a rule most languages keep.
          Text('Names', style: heading),
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(children: [
                const SizedBox.shrink(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text('One is called', style: small),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text('More than one', style: small),
                ),
              ]),
              TableRow(children: [
                const Text('Line'),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _nameField(_label, 'Line', (v) => config.label = v),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _nameField(_labelPlural, '${config.lineNoun}s',
                      (v) => config.labelPlural = v),
                ),
              ]),
              TableRow(children: [
                const Text('Group'),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _nameField(
                      _groupLabel, 'Product', (v) => config.groupLabel = v),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _nameField(_groupLabelPlural, '${config.groupNoun}s',
                      (v) => config.groupLabelPlural = v),
                ),
              ]),
            ],
          ),
          Text('Leave "More than one" empty to add an "s".', style: small),
          const SizedBox(height: 8),
          Text(
            'The dialog will read: ${config.groupNounPlural} | '
            '${config.lineNounPlural} · New ${config.groupNoun.toLowerCase()}',
            style: small,
          ),
          const SizedBox(height: 16),
          Text('Single key (legacy array)', style: heading),
          KeyField(
            initialValue: config.key,
            onChanged: (val) => setState(() => config.key = val),
          ),
          const SizedBox(height: 10),
          SizeField(
              initialValue: config.size,
              onChanged: (size) => setState(() => config.size = size)),
        ],
      ),
    );
  }
}

class PillText extends StatelessWidget {
  final String text;
  final bool selected;
  final TextStyle? selectedStyle;
  final TextStyle? unselectedStyle;
  final EdgeInsetsGeometry padding;
  final Color? selectedColor;

  /// How many lines the label may take before it is clipped.
  ///
  /// One by default, which is what a line pill wants. A recipe's name is the
  /// operator's own words — "Line 2 - Standard" — and clipping that to
  /// "Line 2 - Sta…" loses exactly the part that tells two presets apart, so
  /// the rail allows a second line.
  final int maxLines;

  const PillText({
    super.key,
    required this.text,
    required this.selected,
    this.selectedStyle,
    this.unselectedStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.selectedColor,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: selected
          ? BoxDecoration(
              color: selectedColor ?? scheme.primary.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(30),
            )
          : null,
      padding: padding,
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        maxLines: maxLines,
        softWrap: maxLines > 1,
        style: selected
            ? selectedStyle ??
                Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    )
            : unselectedStyle ??
                Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The asset
// ---------------------------------------------------------------------------

class Recipes extends ConsumerStatefulWidget {
  final RecipesConfig config;
  const Recipes({super.key, required this.config});

  @override
  ConsumerState<Recipes> createState() => _RecipesState();
}

class _RecipesState extends ConsumerState<Recipes> {
  @override
  Widget build(BuildContext context) {
    return UtilityButton(
      label: 'Recipes',
      onTap: () => _showRecipesDialog(context),
    );
  }

  String get _dialogId => 'recipes:${identityHashCode(widget.config)}';

  void _showRecipesDialog(BuildContext context) {
    showFloatingDialog(
      context: context,
      id: _dialogId,
      title: 'Recipes',
      subtitle: '${widget.config.lineKeys.length} '
              '${widget.config.lineKeys.length == 1 ? widget.config.lineNoun : widget.config.lineNounPlural}'
          .toLowerCase(),
      icon: Icons.receipt_long,
      size: const Size(1180, 760),
      // The body fills the window itself. Left at the default, the whole
      // dialog sat in a scroll view it does not need, and an `Expanded`
      // cannot lay out against a scroll view's unbounded height, so the
      // content could not own the space the window gives it — which is why
      // dragging the window bigger used to move nothing.
      scrollable: false,
      // A widget of its own, and a stateful one, because the floating dialog
      // builds its body ONCE and carries it as a captured child. Selection
      // state held anywhere above it could never re-point what the body
      // subscribes to.
      builder: (_) => _RecipesDialogBody(config: widget.config),
    );
  }
}
