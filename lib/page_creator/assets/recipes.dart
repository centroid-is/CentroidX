import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';

import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/widgets/dynamic_value.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/state_value_builder.dart';
import 'package:tfc/widgets/tag_access_guard.dart';
import 'package:tfc_dart/converter/dynamic_value_converter.dart';

import 'package:open62541/open62541_types.dart' show DynamicValue;

part 'recipes.g.dart';

@JsonSerializable(explicitToJson: true)
class RecipesConfig extends BaseAsset {
  @override
  String get displayName => 'Recipes';
  @override
  String get category => 'Application';

  /// Legacy single key: one node holding an ARRAY of line recipes.
  ///
  /// This is how the old `GVL_BatchLines.recipes` published them -- one array
  /// covering every line, which is why the line pills were numbered by array
  /// position. Kept so existing pages keep working.
  String key;

  /// One key per line, in the order the pills should appear.
  ///
  /// The current PLCs publish a separate `ST_LineRecipe` per station
  /// (`SPB01.recipe`, `SPB02.recipe`, `SPB03.recipe`) rather than one array,
  /// so a single key cannot reach them all. When this is non-empty it takes
  /// precedence over [key], and each line is read and written on its own node
  /// -- which also means sending a recipe to one line no longer rewrites the
  /// others, as writing the whole array back did.
  @JsonKey(defaultValue: <String>[])
  List<String> keys;

  String label;

  RecipesConfig({
    required this.key,
    required this.label,
    this.keys = const <String>[],
  });

  /// The keys actually in play, whichever way this asset is configured.
  List<String> get lineKeys => keys.isNotEmpty
      ? keys
      : (key.isEmpty ? const <String>[] : <String>[key]);

  /// True when each line has its own node, so values are read and written
  /// per line instead of as one array.
  bool get perLineKeys => keys.isNotEmpty;

  /// Where saved recipes live. Stable across a switch from [key] to [keys] so
  /// presets defined before the move are not orphaned.
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
          SizedBox(height: 16),
          Text('Single key (legacy array)',
              style: Theme.of(context).textTheme.titleMedium),
          KeyField(
            initialValue: widget.config.key,
            onChanged: (val) => setState(() => widget.config.key = val),
          ),
          SizedBox(height: 16),
          Text('Label', style: Theme.of(context).textTheme.titleMedium),
          TextField(
            controller: _labelController,
            onChanged: (val) => setState(() => widget.config.label = val),
          ),
          SizedBox(height: 10),
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
    return Container(
      decoration: selected
          ? BoxDecoration(
              color: selectedColor,
              borderRadius: BorderRadius.circular(30),
            )
          : null,
      padding: padding,
      child: Text(
        text,
        style: selected
            ? selectedStyle ??
                Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)
            : unselectedStyle ?? Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

class Recipes extends ConsumerStatefulWidget {
  final RecipesConfig config;
  const Recipes({super.key, required this.config});

  @override
  ConsumerState<Recipes> createState() => _RecipesState();
}

class _RecipesState extends ConsumerState<Recipes> {
  int selectedLine = 0;

  /// The node the dialog is reading and writing right now.
  ///
  /// One key per line: the selected line's own node. Legacy single key: the
  /// one array node, with [selectedLine] indexing inside the value instead.
  String get _activeKey {
    final keys = widget.config.lineKeys;
    if (!widget.config.perLineKeys) return widget.config.key;
    if (keys.isEmpty) return '';
    return keys[selectedLine.clamp(0, keys.length - 1)];
  }

  /// The value for the selected line, whichever shape the config uses.
  DynamicValue _lineValue(DynamicValue data) =>
      widget.config.perLineKeys ? data : data[selectedLine];

  /// How many line pills to draw.
  int _lineCount(DynamicValue data) => widget.config.perLineKeys
      ? widget.config.lineKeys.length
      : data.asArray.length;
  int? selectedRecipeIndex;
  final _newRecipeNameController = TextEditingController();

  Future<List<Recipe>> _getRecipes() async {
    return readRecipes(
      await ref.read(preferencesProvider.future),
      await ref.read(systemPreferencesProvider.future),
      widget.config.recipesBucket,
    );
  }

  Future<void> _saveRecipes(List<Recipe> recipes) async {
    await writeRecipes(
      await ref.read(preferencesProvider.future),
      widget.config.recipesBucket,
      recipes,
    );
  }

  void _addRecipe(String name, List<Recipe> recipes, DynamicValue data,
      void Function(VoidCallback) setState) {
    final initial = <String, dynamic>{};
    data.asObject.forEach((k, v) => initial[k] = v.value);
    setState(() {
      recipes.add(Recipe(name: name, value: data));
      _newRecipeNameController.clear();
      _saveRecipes(recipes);
    });
  }

  @override
  Widget build(BuildContext context) {
    return UtilityButton(
      label: 'Recipes',
      onTap: () => _showRecipesDialog(context),
    );
  }

  Widget _dialogContent(
      StateMan stateMan, DynamicValue data, List<Recipe> recipes) {
    return StatefulBuilder(builder: (dialogContext, dialogSetState) {
      return SizedBox(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1000, maxHeight: 700),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Lines
              Container(
                width: 100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(_lineCount(data), (i) {
                    final selected = i == selectedLine;
                    return InkWell(
                      onTap: () => dialogSetState(() {
                        selectedLine = i;
                        selectedRecipeIndex = null;
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: PillText(
                          text: '${widget.config.label} ${i + 1}',
                          selected: selected,
                        ),
                      ),
                    );
                  }),
                ),
              ),
              VerticalDivider(),
              // Recipes list
              Container(
                width: 200,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double listMaxHeight = constraints.maxHeight * 0.6;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Recipes',
                              style: Theme.of(context).textTheme.titleMedium),
                          Divider(),
                          ConstrainedBox(
                            constraints:
                                BoxConstraints(maxHeight: listMaxHeight),
                            child: ListView(
                              shrinkWrap: true,
                              children: List.generate(recipes.length, (r) {
                                final recipe = recipes[r];
                                final selected = r == selectedRecipeIndex;
                                return Row(
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.delete),
                                      onPressed: () => dialogSetState(() {
                                        recipes.removeAt(r);
                                        selectedRecipeIndex = null;
                                        _saveRecipes(recipes);
                                      }),
                                    ),
                                    Expanded(
                                      child: InkWell(
                                        onTap: () => dialogSetState(() {
                                          selectedRecipeIndex = r;
                                        }),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 8.0),
                                          child: PillText(
                                            text: recipe.name,
                                            selected: selected,
                                            selectedStyle: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black),
                                            unselectedStyle: const TextStyle(
                                                color: Colors.grey),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: TextField(
                              controller: _newRecipeNameController,
                              decoration: InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: 'New recipe',
                              ),
                              onSubmitted: (v) => _addRecipe(v, recipes,
                                  _lineValue(data), dialogSetState),
                            ),
                          ),
                          Center(
                            child: ElevatedButton.icon(
                              icon: Icon(Icons.add),
                              label: Text('Add recipe'),
                              onPressed: () => _addRecipe(
                                  _newRecipeNameController.text,
                                  recipes,
                                  _lineValue(data),
                                  dialogSetState),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              VerticalDivider(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The send button rides in the header rather than at
                      // the foot of the column: a recipe struct is as tall as
                      // the PLC type makes it, and below a Spacer() the button
                      // was pushed out of view and had to be scrolled to.
                      Row(
                        children: [
                          Text('Recipe values',
                              style: Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          ElevatedButton(
                            // Every branch below dereferences
                            // selectedRecipeIndex!, so with nothing selected
                            // the button can only throw. Disabled instead.
                            onPressed: selectedRecipeIndex == null
                                ? null
                                : () async {
                                    // Per-line keys write only the line that
                                    // was chosen. The legacy array shape has
                                    // to send the whole array back, which
                                    // rewrites every other line with whatever
                                    // this dialog last read -- one reason
                                    // per-line keys are preferable.
                                    //
                                    // **Neither branch names a member, and
                                    // that is the honest answer rather than a
                                    // shortcut.** Sending a recipe replaces
                                    // every member of the line at once, and
                                    // the legacy branch replaces every line of
                                    // the array; there is no one member being
                                    // set. So the question asked is about the
                                    // key as a whole, which is what a
                                    // template's `*` row answers.
                                    final chosen = DynamicValue.from(
                                        recipes[selectedRecipeIndex!].value);
                                    if (widget.config.perLineKeys) {
                                      await writeTag(
                                          ref, stateMan, _activeKey, chosen);
                                    } else {
                                      final newValue = DynamicValue.from(data);
                                      newValue[selectedLine] = chosen;
                                      await writeTag(
                                          ref, stateMan, _activeKey, newValue);
                                    }
                                  },
                            child: Text('Send values ->'),
                          ),
                        ],
                      ),
                      Divider(),
                      if (selectedRecipeIndex != null)
                        Expanded(
                          child: SingleChildScrollView(
                            child: DynamicValueWidget(
                              value: recipes[selectedRecipeIndex!].value,
                              onSubmitted: (v) => dialogSetState(() {
                                recipes[selectedRecipeIndex!].value = v;
                                _saveRecipes(recipes);
                              }),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              VerticalDivider(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Current values',
                          style: Theme.of(context).textTheme.titleMedium),
                      Divider(),
                      // Same reason as the column to the left: the struct is
                      // whatever height the PLC type dictates.
                      Expanded(
                        child: SingleChildScrollView(
                          child: DynamicValueWidget(
                            value: _lineValue(data),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  String get _dialogId => 'recipes:${identityHashCode(widget.config)}';

  /// The recipe list the open dialog works on. Fetched once per opening,
  /// not once per rebuild: the FutureBuilder used to take a fresh future on
  /// every rebuild, which re-read the preferences and rebuilt the content --
  /// and with it the text fields -- for every keystroke-triggered rebuild.
  Future<List<Recipe>>? _recipesFuture;

  void _showRecipesDialog(BuildContext context) {
    _recipesFuture = null;
    showFloatingDialog(
      context: context,
      id: _dialogId,
      title: 'Recipes',
      subtitle: widget.config.label,
      icon: Icons.receipt_long,
      size: const Size(1040, 700),
      // One subscription for the life of the dialog (StateManValueBuilder):
      // the inline stream re-subscribed on every rebuild, and a rebuild
      // rebuilt the fields under the cursor -- the cursor jumped and
      // backspace ate the wrong character.
      builder: (_) => StateManValueBuilder(
        keyName: _activeKey,
        error: (_, error) => Text('Error loading recipes: $error'),
        waiting: (_) => const Center(child: CircularProgressIndicator()),
        builder: (context, stateMan, data) {
          // With one key per line the node IS the line's recipe, so an array
          // is neither expected nor required. Only the legacy single-key
          // shape carries every line in one value.
          if (!widget.config.perLineKeys && !data.isArray) {
            return Center(
                child: Text(
                    'Unsupported type: ${data.type}, needs to be an array'));
          }

          return FutureBuilder<List<Recipe>>(
            future: _recipesFuture ??= _getRecipes(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text('Error loading recipes: ${snapshot.error}');
              }
              if (!snapshot.hasData) {
                return Center(child: CircularProgressIndicator());
              }
              final recipes = snapshot.data!;
              return _dialogContent(stateMan, data, recipes);
            },
          );
        },
      ),
    );
  }
}
