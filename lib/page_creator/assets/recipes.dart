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

  /// One key per line, in the order the pills should appear.
  ///
  /// Current PLCs publish a separate recipe struct per station rather than one
  /// array, so a single key cannot reach them all. When this is non-empty it
  /// takes precedence over [key], and each line is read and written on its own
  /// node -- which also means sending a recipe to one line no longer rewrites
  /// the others, as writing the whole array back did.
  @JsonKey(defaultValue: <String>[])
  List<String> keys;

  String label;

  /// One recipe list for the whole plant, sent to every key in [keys] at once.
  ///
  /// Off (the default, and what every page saved before this field existed
  /// deserializes to) the dialog is per line: the pills pick a line, the
  /// comparison shows that one line, and Send writes that one line.
  ///
  /// On, the pills disappear, the table grows one column per line, and Send
  /// writes the chosen recipe to every line. **It is not a struct copy** --
  /// see [mergeRecipeInto]. Lines do not have to share a shape, and the write
  /// never adds a member, removes one, or changes an array's length on the
  /// target.
  ///
  /// Only meaningful with [perLineKeys]. With the legacy single key there is
  /// one node and nothing to unify, and [unified] reports false.
  @JsonKey(defaultValue: false)
  bool unifiedRecipe;

  RecipesConfig({
    required this.key,
    required this.label,
    this.keys = const <String>[],
    this.unifiedRecipe = false,
  });

  /// The keys actually in play, whichever way this asset is configured.
  List<String> get lineKeys => keys.isNotEmpty
      ? keys
      : (key.isEmpty ? const <String>[] : <String>[key]);

  /// True when each line has its own node, so values are read and written
  /// per line instead of as one array.
  bool get perLineKeys => keys.isNotEmpty;

  /// Whether the dialog runs in one-recipe-for-every-line mode.
  ///
  /// [unifiedRecipe] alone is not enough: the flag has no meaning without one
  /// node per line, so an asset still on the legacy single key ignores it.
  bool get unified => unifiedRecipe && perLineKeys;

  /// Where saved recipes live. Stable across a switch from [key] to [keys] so
  /// presets defined before the move are not orphaned.
  ///
  /// Unchanged by [unifiedRecipe] on purpose: the saved recipes were always
  /// one shared bucket, so turning the flag on shows the presets that are
  /// already there instead of orphaning them.
  String get recipesBucket =>
      key.isNotEmpty ? key : (keys.isEmpty ? '' : keys.first);

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
        unifiedRecipe = false,
        label = 'Line';

  @override
  Widget configure(BuildContext context) => _RecipesConfigEditor(config: this);
}

@JsonSerializable()
class Recipe {
  String name;
  @DynamicValueConverter()
  DynamicValue value;

  Recipe({required this.name, required this.value});

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
  late TextEditingController _labelController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.config.label);
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Keys, one per line',
              style: Theme.of(context).textTheme.titleMedium),
          const Text(
            "Each key is one line's recipe node. The pills appear in this "
            "order. Leave empty to use the single key below, which expects "
            "one node holding an array of every line.",
            style: TextStyle(fontSize: 12),
          ),
          for (var i = 0; i < widget.config.keys.length; i++)
            Row(
              children: [
                Expanded(
                  child: KeyField(
                    initialValue: widget.config.keys[i],
                    onChanged: (val) =>
                        setState(() => widget.config.keys[i] = val),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Remove this line',
                  onPressed: () =>
                      setState(() => widget.config.keys.removeAt(i)),
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
                widget.config.keys = [...widget.config.keys, ''];
              }),
            ),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: widget.config.unifiedRecipe,
            onChanged: (val) =>
                setState(() => widget.config.unifiedRecipe = val ?? false),
            title: const Text('One recipe for every line'),
            subtitle: Text(
              widget.config.perLineKeys
                  ? 'Send writes the chosen recipe to every key above, member '
                      'by member, skipping anything a line does not have. '
                      'Lines are written one at a time and each reports on '
                      'itself.'
                  : 'Has no effect until there is more than one key above.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          Text('Single key (legacy array)',
              style: Theme.of(context).textTheme.titleMedium),
          KeyField(
            initialValue: widget.config.key,
            onChanged: (val) => setState(() => widget.config.key = val),
          ),
          const SizedBox(height: 16),
          Text('Label', style: Theme.of(context).textTheme.titleMedium),
          TextField(
            controller: _labelController,
            onChanged: (val) => setState(() => widget.config.label = val),
          ),
          const SizedBox(height: 10),
          SizeField(
              initialValue: widget.config.size,
              onChanged: (size) => setState(() => widget.config.size = size)),
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

  const PillText({
    super.key,
    required this.text,
    required this.selected,
    this.selectedStyle,
    this.unselectedStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.selectedColor,
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
// The asset and its dialog
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
      subtitle: widget.config.label,
      icon: Icons.receipt_long,
      size: const Size(1120, 720),
      // The body fills the window itself. Left at the default, the whole
      // dialog sat in a scroll view it does not need — one of four the
      // content had to fight — and an `Expanded` cannot lay out against a
      // scroll view's unbounded height, so the table could not own the space
      // the window gives it.
      scrollable: false,
      // A widget of its own, and a stateful one, because the floating dialog
      // builds its body ONCE and carries it as a captured child. Selection
      // state that lived in [_RecipesState] and was mutated through a
      // `StatefulBuilder` could never re-point the tag subscription above it:
      // tapping Line 2 changed the pill and nothing else, and "Current
      // values" went on showing Line 1's node. Here the subscriptions are
      // built from this widget's own state, so a selection change rebuilds
      // them along with everything else.
      builder: (_) => _RecipesDialogBody(config: widget.config),
    );
  }
}

class _RecipesDialogBody extends ConsumerStatefulWidget {
  const _RecipesDialogBody({required this.config});

  final RecipesConfig config;

  @override
  ConsumerState<_RecipesDialogBody> createState() => _RecipesDialogBodyState();
}

class _RecipesDialogBodyState extends ConsumerState<_RecipesDialogBody> {
  int _selectedLine = 0;
  int? _selectedRecipeIndex;
  bool _sending = false;
  List<LineSendOutcome>? _report;

  final _newRecipeNameController = TextEditingController();

  /// The recipe list the open dialog works on. Fetched once per opening, not
  /// once per rebuild: the FutureBuilder used to take a fresh future on every
  /// rebuild, which re-read the preferences and rebuilt the content -- and
  /// with it the text fields -- for every keystroke-triggered rebuild. This
  /// state object lives exactly as long as one opening of the dialog, so
  /// memoising it here is once per opening.
  ///
  /// Started from `build` rather than `initState`, and only once there is
  /// something to show: a read that nothing is going to listen to is an
  /// unhandled error waiting to happen, and an unconfigured button — the
  /// palette preview is one — would take the preference store down with it
  /// for no reason.
  Future<List<Recipe>>? _recipesFuture;

  /// The combined per-key stream, cached the way `conveyor.dart` caches its
  /// own. A new stream object means cancel every subscription and open them
  /// again, and a dialog rebuilds on every tick and every keystroke.
  Stream<List<DynamicValue?>>? _cachedValues;
  int? _cachedSignature;

  @override
  void dispose() {
    _newRecipeNameController.dispose();
    super.dispose();
  }

  Future<List<Recipe>> _getRecipes() async {
    return readRecipes(
      await ref.read(preferencesProvider.future),
      await ref.read(systemPreferencesProvider.future),
      widget.config.recipesBucket,
    );
  }

  /// Saves, and says so when it could not.
  ///
  /// Called from inside `setState` callbacks, so it cannot be awaited there
  /// — but a shared write can be refused (offline, a lost compare-and-swap,
  /// a denial), and a refusal that lands nowhere leaves a recipe on screen
  /// that reopening the dialog shows was never stored. The messenger is
  /// resolved before the first await for the reason every other write surface
  /// gives: the dialog may be gone by the time the refusal comes back.
  Future<void> _saveRecipes(List<Recipe> recipes) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await writeRecipes(
        await ref.read(preferencesProvider.future),
        widget.config.recipesBucket,
        recipes,
      );
    } on AccessDenied {
      // Already prompted and recorded by the guard.
      rethrow;
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Recipes not saved: $error'),
      ));
    }
  }

  // -- keys and live values ------------------------------------------------

  /// The node this dialog reads and writes for the selected line.
  ///
  /// One key per line: the selected line's own node. Legacy single key: the
  /// one array node, with [_selectedLine] indexing inside the value instead.
  String get _activeKey {
    final config = widget.config;
    if (!config.perLineKeys) return config.key;
    final keys = config.lineKeys;
    if (keys.isEmpty) return '';
    return keys[_selectedLine.clamp(0, keys.length - 1)];
  }

  /// One entry per value column of the table.
  ///
  /// A blank entry in the key list — the editor's "Add line" leaves one until
  /// it is filled in — is dropped here rather than filtered later, so the
  /// headings and the cells are built from the same list and can never come
  /// out different lengths. The remaining lines keep their configured
  /// numbers, so a line is not renamed by its neighbour being unfinished.
  List<({String label, String key})> get _columnBindings {
    final config = widget.config;
    if (config.unified) {
      final keys = config.lineKeys;
      return [
        for (var i = 0; i < keys.length; i++)
          if (keys[i].isNotEmpty)
            (label: '${config.label} ${i + 1}', key: keys[i]),
      ];
    }
    final key = _activeKey;
    if (key.isEmpty) return const [];
    return [(label: 'Current', key: key)];
  }

  /// The keys actually subscribed to right now.
  List<String> get _subscribedKeys => [for (final b in _columnBindings) b.key];

  /// The values behind [_subscribedKeys], one slot per key, null while a key
  /// has not reported.
  ///
  /// Straight from `conveyor.dart`'s multi-key pattern, including the trap
  /// documented there: `CombineLatestStream` emits nothing at all until EVERY
  /// input has produced a value, so one silent line would blank the whole
  /// table. Each source is seeded with a null and has its errors swallowed to
  /// null, so a dead line costs its own column and nothing else.
  Stream<List<DynamicValue?>> _valuesStream(List<Stream<DynamicValue>> sources) {
    final signature =
        Object.hashAll([for (final s in sources) identityHashCode(s)]);
    final cached = _cachedValues;
    if (cached != null && signature == _cachedSignature) return cached;

    final combined = sources.isEmpty
        ? Stream<List<DynamicValue?>>.value(const <DynamicValue?>[])
        : CombineLatestStream<DynamicValue?, List<DynamicValue?>>(
            [for (final s in sources) _tolerant(s)],
            (values) => List<DynamicValue?>.from(values),
          ).shareReplay(maxSize: 1);

    _cachedSignature = signature;
    _cachedValues = combined;
    return combined;
  }

  Stream<DynamicValue?> _tolerant(Stream<DynamicValue> source) => source
      .map<DynamicValue?>((value) => value)
      .transform(
        StreamTransformer<DynamicValue?, DynamicValue?>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.add(null),
        ),
      )
      .startWith(null);

  /// The raw stream values turned into one value per displayed column.
  ///
  /// Per-line keys hand back what they read. The legacy single key reads one
  /// array covering every line, so the column shows the selected element of
  /// it.
  List<DynamicValue?> _displayValues(List<DynamicValue?> raw) {
    if (widget.config.perLineKeys) return raw;
    final whole = raw.isEmpty ? null : raw.first;
    if (whole == null || !whole.isArray) return const <DynamicValue?>[null];
    final items = whole.asArray;
    final index = _selectedLine;
    return [index >= 0 && index < items.length ? items[index] : null];
  }

  int _lineCount(List<DynamicValue?> raw) {
    if (widget.config.perLineKeys) return widget.config.lineKeys.length;
    final whole = raw.isEmpty ? null : raw.first;
    if (whole == null || !whole.isArray) return 0;
    return whole.asArray.length;
  }

  // -- sending -------------------------------------------------------------

  /// Sends the selected recipe, one line at a time.
  ///
  /// **Every write goes through [writeTag]**, so each key is access-checked
  /// and audited on its own — a session allowed to set one line and not
  /// another is refused only on the one it may not touch.
  ///
  /// **No member is named** in the access question, and that is the honest
  /// answer rather than a shortcut: a recipe sets many members of a line at
  /// once, so the question is about the key as a whole, which is what a
  /// template's `*` row answers.
  Future<void> _send(List<Recipe> recipes) async {
    final index = _selectedRecipeIndex;
    if (index == null || index >= recipes.length) return;
    final recipe = recipes[index].value;
    final config = widget.config;

    setState(() {
      _sending = true;
      _report = null;
    });

    final outcomes = <LineSendOutcome>[];
    try {
      final stateMan = await ref.read(stateManProvider.future);

      if (config.perLineKeys) {
        final keys = config.unified
            ? config.lineKeys
            : <String>[_activeKey];
        final labels = config.unified
            ? [for (var i = 0; i < keys.length; i++) '${config.label} ${i + 1}']
            : <String>['${config.label} ${_selectedLine + 1}'];
        for (var i = 0; i < keys.length; i++) {
          outcomes.add(await _sendOne(stateMan, labels[i], keys[i], recipe));
        }
      } else {
        outcomes.add(await _sendLegacyArray(stateMan, recipe));
      }
    } catch (error) {
      // Not one line's failure — there was no connection to send through, so
      // nothing was attempted at all.
      outcomes.add(LineSendOutcome(
        label: 'Nothing sent',
        ok: false,
        message: 'no connection to the controllers ($error)',
      ));
    }

    if (!mounted) return;
    setState(() {
      _sending = false;
      _report = outcomes;
    });
  }

  /// Reads one line, merges the recipe into what it reads, writes it back.
  ///
  /// The read is not a formality. Merging needs the target's own shape, and
  /// without it the only thing left to write is the recipe as it stands —
  /// which is the blind struct copy this whole path exists to avoid. So a
  /// line whose current value cannot be obtained is reported and **not
  /// written**.
  Future<LineSendOutcome> _sendOne(
    StateMan stateMan,
    String label,
    String key,
    DynamicValue recipe,
  ) async {
    if (key.isEmpty) {
      return LineSendOutcome(
          label: label, ok: false, message: 'no key configured');
    }
    DynamicValue current;
    try {
      current = await stateMan.read(key);
    } catch (error) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'could not be read, so nothing was written ($error)',
      );
    }
    final result = mergeRecipeInto(current, recipe);
    if (result.written.isEmpty) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'nothing written — ${describeMerge(result)}',
      );
    }
    try {
      final issued = await writeTag(ref, stateMan, key, result.merged);
      if (!issued) {
        return LineSendOutcome(
          label: label,
          ok: false,
          message: 'not permitted, so nothing was written',
        );
      }
    } on AccessDenied {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'not permitted, so nothing was written',
      );
    } catch (error) {
      return LineSendOutcome(label: label, ok: false, message: 'failed: $error');
    }
    return LineSendOutcome(
        label: label, ok: true, message: describeMerge(result));
  }

  /// The legacy single-key shape: one array node holding every line.
  ///
  /// The whole array has to go back, because that is the node. The merge still
  /// applies to the selected element, so the element keeps its own shape, and
  /// the other elements are written back exactly as they were read.
  Future<LineSendOutcome> _sendLegacyArray(
      StateMan stateMan, DynamicValue recipe) async {
    final config = widget.config;
    final label = '${config.label} ${_selectedLine + 1}';
    if (config.key.isEmpty) {
      return LineSendOutcome(
          label: label, ok: false, message: 'no key configured');
    }
    DynamicValue whole;
    try {
      whole = DynamicValue.from(await stateMan.read(config.key));
    } catch (error) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'could not be read, so nothing was written ($error)',
      );
    }
    if (!whole.isArray || _selectedLine >= whole.asArray.length) {
      return LineSendOutcome(
          label: label, ok: false, message: 'this line is not in the array');
    }
    final result = mergeRecipeInto(whole[_selectedLine], recipe);
    if (result.written.isEmpty) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'nothing written — ${describeMerge(result)}',
      );
    }
    whole[_selectedLine] = result.merged;
    try {
      final issued = await writeTag(ref, stateMan, config.key, whole);
      if (!issued) {
        return LineSendOutcome(
          label: label,
          ok: false,
          message: 'not permitted, so nothing was written',
        );
      }
    } on AccessDenied {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'not permitted, so nothing was written',
      );
    } catch (error) {
      return LineSendOutcome(label: label, ok: false, message: 'failed: $error');
    }
    return LineSendOutcome(
        label: label, ok: true, message: describeMerge(result));
  }

  // -- recipe list ---------------------------------------------------------

  void _addRecipe(String name, List<Recipe> recipes, DynamicValue? seed) {
    if (name.trim().isEmpty || seed == null) return;
    setState(() {
      recipes.add(Recipe(name: name.trim(), value: DynamicValue.from(seed)));
      _selectedRecipeIndex = recipes.length - 1;
      _newRecipeNameController.clear();
      _saveRecipes(recipes);
    });
  }

  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.config.lineKeys.isEmpty) {
      return const Center(
        child: Text('This recipes button has no keys configured yet.'),
      );
    }
    // May be empty when the line that is selected is the one whose key has
    // not been filled in. The rails still render in that case — a dialog that
    // replaced itself with a message would leave no pill to tap to get back
    // to a line that does work.
    final keys = _subscribedKeys;

    // One shared stream per key, held by [keyStreamProvider] rather than by
    // this widget: watching keeps them alive across a rebuild, and two assets
    // pointed at the same node read the same subscription.
    //
    // Watched HERE, in `build` itself, and not inside the builders below: a
    // `ref.watch` from a nested builder's callback runs in that builder's
    // element, not this one's, and is not a dependency this widget would be
    // rebuilt for.
    final sources = [for (final key in keys) ref.watch(keyStreamProvider(key))];

    return FutureBuilder<List<Recipe>>(
      future: _recipesFuture ??= _getRecipes(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error loading recipes: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _liveContent(context, snapshot.data!, sources);
      },
    );
  }

  Widget _liveContent(BuildContext context, List<Recipe> recipes,
      List<Stream<DynamicValue>> sources) {
    return StreamBuilder<List<DynamicValue?>>(
      stream: _valuesStream(sources),
      builder: (context, snapshot) {
        final raw = snapshot.data ??
            List<DynamicValue?>.filled(sources.length, null, growable: false);
        final config = widget.config;
        final first = raw.isEmpty ? null : raw.first;
        if (!config.perLineKeys && first != null && !first.isArray) {
          return Center(
            child: Text(
                'Unsupported type: ${first.type}, needs to be an array'),
          );
        }
        return _content(context, recipes, raw);
      },
    );
  }

  Widget _content(
      BuildContext context, List<Recipe> recipes, List<DynamicValue?> raw) {
    final config = widget.config;
    final values = _displayValues(raw);
    final lineCount = _lineCount(raw);
    final showLinePills = !config.unified && lineCount > 1;
    final selectedRecipe =
        (_selectedRecipeIndex != null && _selectedRecipeIndex! < recipes.length)
            ? recipes[_selectedRecipeIndex!]
            : null;

    // The rails are sized from what the window actually gives them rather
    // than pinned: the floating dialog can be dragged down to 320 px wide,
    // and two fixed rails wider than that overflow the row rather than
    // shrinking. They give way first, because the table is the content.
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;
      final pillWidth = (available * 0.12).clamp(70.0, 110.0);
      final railWidth = (available * 0.22).clamp(150.0, 210.0);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showLinePills) ...[
            SizedBox(
              width: pillWidth,
              child: _linePills(context, lineCount),
            ),
            const VerticalDivider(),
          ],
          SizedBox(
            width: railWidth,
            child: _recipeRail(context, recipes, values),
          ),
          const VerticalDivider(),
          Expanded(
            child: _valuesPanel(context, recipes, selectedRecipe, values),
          ),
        ],
      );
    });
  }

  Widget _linePills(BuildContext context, int lineCount) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.config.label,
            style: Theme.of(context).textTheme.titleMedium),
        const Divider(),
        Expanded(
          child: ListView.builder(
            primary: false,
            itemCount: lineCount,
            itemBuilder: (context, i) => InkWell(
              onTap: () => setState(() {
                _selectedLine = i;
                _report = null;
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: PillText(
                  text: '${widget.config.label} ${i + 1}',
                  selected: i == _selectedLine,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _recipeRail(
      BuildContext context, List<Recipe> recipes, List<DynamicValue?> values) {
    final scheme = Theme.of(context).colorScheme;
    final seed = values.firstWhere((v) => v != null, orElse: () => null);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recipes', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          // The rail's own short scroll, and the only one besides the values
          // table: the list is as long as the operator has made it.
          Expanded(
            child: recipes.isEmpty
                ? Center(
                    child: Text(
                      'No saved recipes yet.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  )
                : ListView.builder(
                    primary: false,
                    itemCount: recipes.length,
                    itemBuilder: (context, r) {
                      final recipe = recipes[r];
                      return Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete ${recipe.name}',
                            onPressed: () => setState(() {
                              recipes.removeAt(r);
                              _selectedRecipeIndex = null;
                              _report = null;
                              _saveRecipes(recipes);
                            }),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() {
                                _selectedRecipeIndex = r;
                                _report = null;
                              }),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6.0),
                                child: PillText(
                                  text: recipe.name,
                                  selected: r == _selectedRecipeIndex,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: TextField(
              controller: _newRecipeNameController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'New recipe',
                isDense: true,
              ),
              onSubmitted: (v) => _addRecipe(v, recipes, seed),
            ),
          ),
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add recipe'),
              // With nothing live to copy there is no recipe to make: a
              // preset seeded from a line that has not reported would be an
              // empty struct that later looks like a real one.
              onPressed: seed == null
                  ? null
                  : () =>
                      _addRecipe(_newRecipeNameController.text, recipes, seed),
            ),
          ),
        ],
      ),
    );
  }

  Widget _valuesPanel(BuildContext context, List<Recipe> recipes,
      Recipe? selectedRecipe, List<DynamicValue?> values) {
    final bindings = _columnBindings;
    final shapeSources = <DynamicValue?>[
      if (selectedRecipe != null) selectedRecipe.value,
      ...values,
    ];
    final rows = flattenRecipeShape(shapeSources);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The send button rides in the header rather than at the foot of the
          // column: a recipe struct is as tall as the PLC type makes it, and
          // below a Spacer() the button was pushed out of view and had to be
          // scrolled to.
          Row(
            children: [
              Expanded(
                child: Text(
                  selectedRecipe == null
                      ? 'Values'
                      : 'Values — ${selectedRecipe.name}',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                // Every branch below dereferences the selection, so with
                // nothing selected the button can only throw. Disabled
                // instead.
                onPressed: selectedRecipe == null || _sending
                    ? null
                    : () => _send(recipes),
                child: Text(_sending
                    ? 'Sending...'
                    : widget.config.unified
                        ? 'Send to every ${widget.config.label.toLowerCase()}'
                        : 'Send values'),
              ),
            ],
          ),
          if (_report != null) _reportBlock(context, _report!),
          const Divider(),
          if (bindings.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  'This ${widget.config.label.toLowerCase()} has no key '
                  'configured yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else if (rows.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  selectedRecipe == null
                      ? 'Waiting for values...'
                      : 'This recipe has no values in it.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else
            Expanded(
              child: _comparisonTable(
                  context, rows, bindings, selectedRecipe, values, recipes),
            ),
        ],
      ),
    );
  }

  Widget _reportBlock(BuildContext context, List<LineSendOutcome> outcomes) {
    final states = Theme.of(context).extension<HmiStateColors>() ??
        HmiStateColors.solarizedLight;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final outcome in outcomes)
            Padding(
              padding: const EdgeInsets.only(bottom: 2.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    outcome.ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: outcome.ok ? states.green : states.red,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${outcome.label}: ${outcome.message}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (outcomes.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 2.0),
              child: Text(
                'Each line is a controller of its own and was written '
                'separately — some may have changed while others did not.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  /// The one member-aligned table: the recipe's value and every line's live
  /// value for a member sit on the same row.
  ///
  /// It replaces two side-by-side trees that scrolled independently, so a
  /// member's saved value and its live value could not be brought level with
  /// each other on screen at all.
  Widget _comparisonTable(
    BuildContext context,
    List<RecipeRow> rows,
    List<({String label, String key})> bindings,
    Recipe? selectedRecipe,
    List<DynamicValue?> values,
    List<Recipe> recipes,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final widths = <int, TableColumnWidth>{
      0: const FlexColumnWidth(2.0),
      if (selectedRecipe != null) 1: const FlexColumnWidth(1.5),
    };
    final firstValueColumn = selectedRecipe != null ? 2 : 1;
    for (var i = 0; i < bindings.length; i++) {
      widths[firstValueColumn + i] = const FlexColumnWidth(1.2);
    }

    final headerStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(color: scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Table(
          columnWidths: widths,
          children: [
            TableRow(children: [
              _cell(Text('Member', style: headerStyle)),
              if (selectedRecipe != null) _cell(Text('Recipe', style: headerStyle)),
              for (final binding in bindings)
                _cell(Text(binding.label,
                    style: headerStyle, overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ),
        const Divider(height: 1),
        // THE scroll region. Everything else in this dialog sizes itself to
        // the window.
        Expanded(
          child: SingleChildScrollView(
            primary: false,
            child: Table(
              columnWidths: widths,
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                for (final row in rows)
                  TableRow(
                    decoration: row.isLeaf
                        ? null
                        : BoxDecoration(
                            color: scheme.onSurface.withValues(alpha: 0.04),
                          ),
                    children: [
                      _cell(_memberLabel(context, row)),
                      if (selectedRecipe != null)
                        _cell(_recipeCell(
                            context, row, selectedRecipe, recipes)),
                      for (final value in values)
                        _cell(_liveCell(context, row, value)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static Widget _cell(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: child,
      );

  Widget _memberLabel(BuildContext context, RecipeRow row) {
    final scheme = Theme.of(context).colorScheme;
    final style = row.isLeaf
        ? Theme.of(context).textTheme.bodyMedium
        : Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(fontWeight: FontWeight.bold, color: scheme.onSurface);
    return Padding(
      padding: EdgeInsets.only(left: 14.0 * row.depth),
      child: Text(row.label,
          style: style, softWrap: false, overflow: TextOverflow.ellipsis),
    );
  }

  /// The recipe's own cell — the one editable column.
  ///
  /// [DynamicValueWidget] is handed a single LEAF rather than the whole tree,
  /// which is what lets the editors it already owns (the switch, the enum
  /// dropdown, the controller-keeping text field) be reused a row at a time
  /// instead of being reimplemented for the table.
  Widget _recipeCell(BuildContext context, RecipeRow row, Recipe recipe,
      List<Recipe> recipes) {
    final value = valueAtPath(recipe.value, row.path);
    if (value == null) {
      return _absent(context);
    }
    if (!row.isLeaf) {
      return Text(formatRecipeValue(value),
          style: Theme.of(context).textTheme.bodySmall);
    }
    // The label and description are already the Member column's job; leaving
    // them on the leaf would print each one twice per row.
    final leaf = DynamicValue.from(value)
      ..displayName = null
      ..description = null;
    // Dense, because a row of this table is a row and not a form field. At
    // the default density one editor is 64 px tall and a nine-member recipe
    // does not fit a window twice its height — which is the complaint this
    // whole rebuild started from.
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        visualDensity: VisualDensity.compact,
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
      ),
      child: DynamicValueWidget(
        value: leaf,
        onSubmitted: (newValue) => setState(() {
          recipe.value = setAtPath(recipe.value, row.path, newValue);
          _saveRecipes(recipes);
        }),
      ),
    );
  }

  Widget _liveCell(BuildContext context, RecipeRow row, DynamicValue? source) {
    if (source == null) return _quiet(context, 'waiting');
    final value = valueAtPath(source, row.path);
    if (value == null) return _absent(context);
    return Text(formatRecipeValue(value),
        style: Theme.of(context).textTheme.bodyMedium,
        softWrap: false,
        overflow: TextOverflow.ellipsis);
  }

  /// A member this column's line does not have.
  ///
  /// Spelled out, never left blank and never shown as a zero: a blank reads as
  /// "nothing set" and a zero reads as a setpoint, and both are wrong about a
  /// line that simply has no such member.
  Widget _absent(BuildContext context) => _quiet(context, 'not present');

  /// A cell that says something about itself rather than carrying a value.
  ///
  /// One line and clipped, never wrapped: a wrapped "waiting" grows the row
  /// it is in and takes every other line's value with it.
  Widget _quiet(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
}
