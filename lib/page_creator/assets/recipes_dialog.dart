part of 'recipes.dart';

// The recipes dialog: two views over one list.
//
//  * The GROUPS view (called whatever the asset calls a group — "Products"
//    by default) is where the dialog opens. A group is one recipe per line;
//    pick one and send it, whole or a line at a time.
//  * The LINES view is the advanced one: one line at a time, every value of
//    one recipe editable against what the line holds now.
//
// Both read the same recipe list and the same live values, so switching
// between them loses nothing.

enum _RecipesView { groups, lines }

/// What the right-hand pane of the groups view is showing, when it is not
/// the selected group.
enum _Panel { none, newGroup, grouping, rename, delete, pick }

/// One line as the dialog sees it.
@immutable
class _Line {
  const _Line({
    required this.id,
    required this.name,
    required this.key,
    this.index,
  });

  /// What [Recipe.line] stores for this line: its key, or for the legacy
  /// array shape, the key and the element it indexes.
  final String id;

  /// "Line 2" — what the operator reads.
  final String name;

  /// The node that is read and written.
  final String key;

  /// The element of the legacy array this line is, null for per-line keys.
  final int? index;
}

class _RecipesDialogBody extends ConsumerStatefulWidget {
  const _RecipesDialogBody({required this.config, required this.guard});

  final RecipesConfig config;
  final _CloseGuard guard;

  @override
  ConsumerState<_RecipesDialogBody> createState() => _RecipesDialogBodyState();
}

class _RecipesDialogBodyState extends ConsumerState<_RecipesDialogBody> {
  static final _log = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 2,
      lineLength: 80,
      colors: true,
      printEmojis: false,
    ),
  );

  /// Saves run one after another, never side by side. The shared store
  /// checks a row's revision on every write, so two saves in flight at once —
  /// two quick taps — carry the same revision, and the second is refused as
  /// though another station had changed the row. Each waits for the last.
  Future<void> _saveChain = Future<void>.value();

  /// The recipe being edited in the lines view, and its values while it is.
  ///
  /// Nothing reaches the database until Save. Values are read-only until
  /// Edit, so a stray tap on a panel changes nothing; while editing they
  /// change a draft, which Save stores, Cancel drops, and Send can try on the
  /// line without storing — trying a value on a machine and keeping it as
  /// the recipe are different decisions.
  Recipe? _editing;
  DynamicValue? _draft;

  /// What the operator asked to do while there were unsaved edits — pick
  /// another recipe, another line, the other view, close the window — held
  /// until they say whether to save first.
  VoidCallback? _pendingLeave;

  /// What the held action will do, for the banner's buttons: "continue", or
  /// "close" when it was the window's close button.
  String _pendingVerb = 'continue';

  /// The recipe whose delete is waiting to be confirmed.
  Recipe? _confirmDelete;
  _RecipesView _view = _RecipesView.groups;

  /// The group on screen in the groups view, by name.
  String? _selectedGroup;

  /// The line on screen in the lines view, by position among the lines.
  int _selectedLine = 0;

  /// The recipe on screen in the lines view — the recipe ITSELF, not its
  /// position, so nothing that reorders or files the list can quietly swap
  /// what the table shows and what Send would send.
  Recipe? _selectedRecipe;

  bool _sending = false;
  List<LineSendOutcome>? _report;

  final _newRecipeName = TextEditingController();

  /// A form open in the groups view's right-hand pane, and the group it is
  /// about.
  _Panel _panel = _Panel.none;
  String? _panelGroup;

  /// The line a panel is about — the pick panel's — by id.
  String? _panelLine;

  /// The name being typed in a panel.
  final _panelName = TextEditingController();

  /// The lines ticked in the new-group panel, by id.
  final Set<String> _ticked = {};

  /// The recipe whose name is being edited in the lines view's header, if
  /// any, and what is being typed for it.
  Recipe? _renaming;
  final _renameText = TextEditingController();

  /// The recipe list the open dialog works on. Fetched once per opening, not
  /// once per rebuild: a fresh future on every rebuild re-read the
  /// preferences and rebuilt the content — and with it the text fields —
  /// for every keystroke.
  ///
  /// Started from `build` rather than `initState`, and only once there is
  /// something to show: an unconfigured button — the palette preview is one
  /// — must not read the preference store for nothing.
  Future<List<Recipe>>? _recipesFuture;

  /// The combined per-key stream, cached the way `conveyor.dart` caches its
  /// own. A new stream object means cancel every subscription and open them
  /// again, and a dialog rebuilds on every tick and every keystroke.
  Stream<List<DynamicValue?>>? _cachedValues;
  int? _cachedSignature;

  RecipesConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    widget.guard.ask = _askClose;
  }

  @override
  void dispose() {
    if (widget.guard.ask == _askClose) widget.guard.ask = null;
    _newRecipeName.dispose();
    _panelName.dispose();
    _renameText.dispose();
    super.dispose();
  }

  // -- storage -------------------------------------------------------------

  Future<List<Recipe>> _getRecipes() =>
      _loadRecipes(ref, _config.recipesBucket);

  /// Saves, one save at a time, and says so — on screen AND in the log —
  /// when it could not.
  ///
  /// Called from inside `setState` callbacks, so it cannot be awaited there.
  /// The store and the messenger are taken now, while the dialog is certainly
  /// mounted: a queued save may run after it has closed.
  Future<void> _saveRecipes(List<Recipe> recipes) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final store = ref.read(preferencesProvider.future);
    final bucket = _config.recipesBucket;
    final run = _saveChain.then((_) async {
      try {
        await writeRecipes(await store, bucket, recipes);
      } on AccessDenied catch (error) {
        // The guard has prompted and recorded it already; logged too, so a
        // refused save is never only a message that went away.
        _log.w('recipes not saved for $bucket: not permitted ($error)');
      } catch (error, stack) {
        // A snackbar goes away. The log is where a save that did not land
        // can still be found afterwards.
        _log.e('recipes not saved for $bucket',
            error: error, stackTrace: stack);
        messenger?.showSnackBar(SnackBar(
          content: Text('Recipes not saved: $error'),
          duration: const Duration(seconds: 10),
        ));
      }
    });
    _saveChain = run;
    return run;
  }

  // -- editing -------------------------------------------------------------

  bool get _dirty {
    final recipe = _editing;
    final draft = _draft;
    return recipe != null && draft != null && !_sameValues(recipe.value, draft);
  }

  void _startEditing(Recipe recipe) => setState(() {
        _editing = recipe;
        _draft = DynamicValue.from(recipe.value);
        _pendingLeave = null;
        _report = null;
      });

  void _stopEditing() {
    _editing = null;
    _draft = null;
    _pendingLeave = null;
  }

  /// Lets a value still being typed land in the draft before it is read.
  ///
  /// A field commits when it loses focus, and focus changes are applied a
  /// microtask after `unfocus()` — read the draft any sooner and the last
  /// keystrokes are missing from it.
  Future<void> _settleFields() async {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> _saveEdit(List<Recipe> recipes) async {
    await _settleFields();
    if (!mounted) return;
    setState(() {
      final recipe = _editing;
      final draft = _draft;
      if (recipe != null && draft != null) {
        recipe.value = draft;
        _saveRecipes(recipes);
      }
      _stopEditing();
    });
  }

  void _cancelEdit() => setState(_stopEditing);

  /// Runs [action], or — with unsaved edits — asks first, in the pane.
  void _leaveThen(VoidCallback action) {
    if (!_dirty) {
      if (_editing != null) _stopEditing();
      action();
      return;
    }
    setState(() {
      _pendingLeave = action;
      _pendingVerb = 'continue';
    });
  }

  /// The window's close button: allowed, or held for the question.
  bool _askClose() {
    if (!_dirty) return true;
    setState(() {
      _view = _RecipesView.lines;
      _pendingLeave = () => closeFloatingDialog(widget.guard.dialogId);
      _pendingVerb = 'close';
    });
    return false;
  }

  Widget _unsavedBanner(BuildContext context, List<Recipe> recipes) {
    final theme = Theme.of(context);
    final states = _states(context);
    final then = _pendingLeave!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: states.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_note, color: states.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Unsaved changes to ${_editing?.name ?? 'this recipe'}. Save '
              'them first?',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _pendingLeave = null),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () {
              setState(_stopEditing);
              then();
            },
            // Named for what happens next, so they cannot be mistaken for
            // the header's own Save, which stays put.
            child: Text('Discard and $_pendingVerb'),
          ),
          FilledButton(
            onPressed: () async {
              await _saveEdit(recipes);
              then();
            },
            child: Text('Save and $_pendingVerb'),
          ),
        ],
      ),
    );
  }

  // -- lines and live values -----------------------------------------------

  /// Every node the dialog reads. Both views need every line — the groups
  /// view shows them side by side, and the lines view switches between them
  /// instantly — so all of them are subscribed for as long as it is open.
  List<String> get _subscribedKeys {
    if (_config.perLineKeys) {
      return [
        for (final key in _config.keys)
          if (key.isNotEmpty) key
      ];
    }
    return _config.key.isEmpty ? const [] : [_config.key];
  }

  /// The lines, in order.
  ///
  /// A blank entry in the key list — "Add line" leaves one until it is
  /// filled in — is skipped, and the lines that remain keep their configured
  /// numbers, so a line is not renamed by its neighbour being unfinished.
  List<_Line> _lines(List<DynamicValue?> raw) {
    final noun = _config.lineNoun;
    if (_config.perLineKeys) {
      return [
        for (var i = 0; i < _config.keys.length; i++)
          if (_config.keys[i].isNotEmpty)
            _Line(
                id: _config.keys[i],
                name: '$noun ${i + 1}',
                key: _config.keys[i]),
      ];
    }
    final whole = raw.isEmpty ? null : raw.first;
    if (whole == null || !whole.isArray) return const [];
    return [
      for (var i = 0; i < whole.asArray.length; i++)
        _Line(
          id: '${_config.key}[$i]',
          name: '$noun ${i + 1}',
          key: _config.key,
          index: i,
        ),
    ];
  }

  /// One live value per line, null while a line has not reported.
  List<DynamicValue?> _liveValues(List<_Line> lines, List<DynamicValue?> raw) {
    if (_config.perLineKeys) {
      return [
        for (var i = 0; i < lines.length; i++) i < raw.length ? raw[i] : null
      ];
    }
    final whole = raw.isEmpty ? null : raw.first;
    return [
      for (final line in lines)
        (whole != null && whole.isArray && line.index! < whole.asArray.length)
            ? whole.asArray[line.index!]
            : null,
    ];
  }

  /// The values behind [_subscribedKeys], one slot per key.
  ///
  /// Straight from `conveyor.dart`'s multi-key pattern, including the trap
  /// documented there: `CombineLatestStream` emits nothing at all until EVERY
  /// input has produced a value, so one silent line would blank the whole
  /// dialog. Each source is seeded with a null and has its errors swallowed
  /// to null, so a dead line costs its own card and nothing else.
  Stream<List<DynamicValue?>> _valuesStream(
      List<Stream<DynamicValue>> sources) {
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

  // -- sending -------------------------------------------------------------

  /// Sends each job's recipe to its line, one line at a time.
  ///
  /// **Every write goes through [writeTag]**, so each key is access-checked
  /// and audited on its own — a session allowed to set one line and not
  /// another is refused only on the one it may not touch. There is no
  /// transaction across lines, and nothing here pretends there is: each line
  /// reports on itself.
  ///
  /// [alreadyDecided] are the lines settled without a write — running the
  /// recipe already, or with no recipe in the group — reported beside the
  /// ones that were written so the operator sees every line accounted for.
  Future<void> _send(
    List<({_Line line, Recipe recipe})> jobs, {
    List<LineSendOutcome> alreadyDecided = const [],
  }) async {
    // A value typed but not entered is still in its field. Dropping focus
    // fires the commit, so Send sends what is on screen rather than what the
    // operator last pressed Enter on.
    FocusScope.of(context).unfocus();

    setState(() {
      _sending = true;
      _report = null;
    });

    final outcomes = <LineSendOutcome>[];
    try {
      final stateMan = await ref.read(stateManProvider.future);
      for (final job in jobs) {
        outcomes.add(job.line.index == null
            ? await _sendOne(
                stateMan, job.line.name, job.line.key, job.recipe.value)
            : await _sendLegacyArray(stateMan, job.line, job.recipe.value));
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
      _report = [...outcomes, ...alreadyDecided];
    });
  }

  /// Reads one line, merges the recipe into what it reads, writes it back.
  ///
  /// The read is not a formality. Merging needs the target's own shape, and
  /// without it the only thing left to write is the recipe as it stands —
  /// a blind struct copy. A recipe captured from its own line fits it, but a
  /// line's PLC type can change after the recipe was saved, and this is what
  /// keeps that from writing a guess. So a line whose current value cannot
  /// be obtained is reported and **not written**.
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
      return LineSendOutcome(
          label: label, ok: false, message: 'failed: $error');
    }
    return LineSendOutcome(
        label: label, ok: true, message: describeMerge(result));
  }

  /// The legacy single-key shape: one array node holding every line.
  ///
  /// The whole array has to go back, because that is the node. The merge
  /// applies to this line's element alone, and the other elements are
  /// written back exactly as they were read.
  Future<LineSendOutcome> _sendLegacyArray(
      StateMan stateMan, _Line line, DynamicValue recipe) async {
    final label = line.name;
    final index = line.index!;
    DynamicValue whole;
    try {
      whole = DynamicValue.from(await stateMan.read(line.key));
    } catch (error) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'could not be read, so nothing was written ($error)',
      );
    }
    if (!whole.isArray || index >= whole.asArray.length) {
      return LineSendOutcome(
          label: label, ok: false, message: 'this line is not in the array');
    }
    final result = mergeRecipeInto(whole[index], recipe);
    if (result.written.isEmpty) {
      return LineSendOutcome(
        label: label,
        ok: false,
        message: 'nothing written — ${describeMerge(result)}',
      );
    }
    whole[index] = result.merged;
    try {
      final issued = await writeTag(ref, stateMan, line.key, whole);
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
      return LineSendOutcome(
          label: label, ok: false, message: 'failed: $error');
    }
    return LineSendOutcome(
        label: label, ok: true, message: describeMerge(result));
  }

  /// Sends [group] to every line it has a recipe for.
  ///
  /// A line already running its recipe is not written — the dialog said it
  /// would be "left as it is", and a write that changes nothing is still a
  /// write to the PLC and a row in the audit trail. A line the group has no
  /// recipe for is left alone and says so.
  void _sendGroup(String group, List<_Line> lines, List<DynamicValue?> live,
      List<Recipe> recipes) {
    final jobs = <({_Line line, Recipe recipe})>[];
    final decided = <LineSendOutcome>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final recipe = recipeInGroup(recipes, group, line.id);
      final status = lineRecipeStatus(recipe, live[i]);
      switch (status.state) {
        case LineRecipeState.noRecipe:
          decided.add(LineSendOutcome(
            label: line.name,
            ok: true,
            message: 'no recipe in $group — left alone',
          ));
        case LineRecipeState.running:
          decided.add(LineSendOutcome(
            label: line.name,
            ok: true,
            message: 'already running it — left as it is',
          ));
        case LineRecipeState.waiting:
        case LineRecipeState.differs:
        case LineRecipeState.doesNotFit:
          jobs.add((line: line, recipe: recipe!));
      }
    }
    _send(jobs, alreadyDecided: decided);
  }

  // -- changing the list ---------------------------------------------------

  /// A recipe for [line], captured from what it runs now.
  ///
  /// Named after its product when it is made for one — the convention
  /// operators already keep by hand: "Standard" on every line, each line's
  /// own.
  Recipe _captured(_Line line, DynamicValue live,
          {String? group, String? name}) =>
      Recipe(
        name: name ?? group ?? 'Recipe',
        value: DynamicValue.from(live),
        line: line.id,
        group: group,
      );

  void _createGroup(String name, List<({_Line line, DynamicValue live})> from,
      List<Recipe> recipes) {
    setState(() {
      for (final item in from) {
        recipes.add(_captured(item.line, item.live, group: name));
      }
      _selectedGroup = name;
      _report = null;
      _saveRecipes(recipes);
    });
  }

  void _copyIntoGroup(
      String group, _Line line, DynamicValue live, List<Recipe> recipes) {
    setState(() {
      // Placed straight after the group's other recipes, so the group stays
      // one block in the list.
      final after = recipes.lastIndexWhere((r) => r.group == group);
      final copy = _captured(line, live, name: group);
      recipes.insert(after + 1, copy);
      // Through the same door as picking: a recipe the line already had in
      // this product is taken out of it and kept, never overwritten.
      useRecipeInGroup(recipes, group, line.id, copy);
      _panel = _Panel.none;
      _report = null;
      _saveRecipes(recipes);
    });
  }

  void _addLineRecipe(
      String name, _Line line, DynamicValue live, List<Recipe> recipes) {
    if (name.trim().isEmpty) return;
    setState(() {
      final added = _captured(line, live, name: name.trim());
      recipes.add(added);
      _selectedRecipe = added;
      _newRecipeName.clear();
      _report = null;
      _saveRecipes(recipes);
    });
  }

  void _setGroup(
      Recipe recipe, String? group, _Line line, List<Recipe> recipes) {
    setState(() {
      if (group == null) {
        recipe.group = null;
      } else {
        // A recipe saved before recipes knew their line is offered on every
        // line; filing it into a group makes it this line's.
        recipe.line ??= line.id;
        if (!canJoinGroup(recipes, recipe, group)) return;
        recipe.group = group;
      }
      _saveRecipes(recipes);
    });
  }

  void _deleteRecipe(Recipe recipe, List<Recipe> recipes) {
    setState(() {
      _confirmDelete = null;
      if (identical(recipe, _editing)) _stopEditing();
      recipes.remove(recipe);
      if (identical(recipe, _selectedRecipe)) _selectedRecipe = null;
      _report = null;
      _saveRecipes(recipes);
    });
  }

  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_config.lineKeys.isEmpty) {
      return const Center(
        child: Text('This recipes button has no keys configured yet.'),
      );
    }

    // One shared stream per key, held by [keyStreamProvider] rather than by
    // this widget: watching keeps them alive across a rebuild, and two assets
    // pointed at the same node read the same subscription.
    //
    // Watched HERE, in `build` itself, and not inside the builders below: a
    // `ref.watch` from a nested builder's callback runs in that builder's
    // element, not this one's, and is not a dependency this widget would be
    // rebuilt for.
    final sources = [
      for (final key in _subscribedKeys) ref.watch(keyStreamProvider(key))
    ];

    return FutureBuilder<List<Recipe>>(
      future: _recipesFuture ??= _getRecipes(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
              child: Text('Error loading recipes: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final recipes = snapshot.data!;
        return StreamBuilder<List<DynamicValue?>>(
          stream: _valuesStream(sources),
          builder: (context, values) {
            final raw =
                values.data ?? List<DynamicValue?>.filled(sources.length, null);
            final first = raw.isEmpty ? null : raw.first;
            if (!_config.perLineKeys && first != null && !first.isArray) {
              return Center(
                child: Text(
                    'Unsupported type: ${first.type}, needs to be an array'),
              );
            }
            final lines = _lines(raw);
            final live = _liveValues(lines, raw);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_pendingLeave != null) _unsavedBanner(context, recipes),
                _viewSwitch(context),
                const SizedBox(height: 8),
                Expanded(
                  child: _view == _RecipesView.groups
                      ? _groupsView(context, recipes, lines, live)
                      : _linesView(context, recipes, lines, live),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// "Products | Lines" — both words the asset's own.
  Widget _viewSwitch(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: SegmentedButton<_RecipesView>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: _RecipesView.groups,
            label: Text(_config.groupNounPlural),
          ),
          ButtonSegment(
            value: _RecipesView.lines,
            label: Text(_config.lineNounPlural),
          ),
        ],
        selected: {_view},
        onSelectionChanged: (selection) => _leaveThen(() => setState(() {
              _view = selection.first;
              _panel = _Panel.none;
              _report = null;
            })),
      ),
    );
  }

  /// The two-pane layout both views share: a rail, and what is picked in it.
  ///
  /// The rail is sized from what the window gives it rather than pinned, so
  /// dragging the window bigger grows the content with it and a narrow
  /// window shrinks the rail before it overflows.
  Widget _twoPane(Widget Function(double railWidth) rail, Widget detail) {
    return LayoutBuilder(builder: (context, constraints) {
      final railWidth = (constraints.maxWidth * 0.25).clamp(200.0, 300.0);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: railWidth, child: rail(railWidth)),
          const VerticalDivider(width: 17),
          Expanded(child: detail),
        ],
      );
    });
  }

  HmiStateColors _states(BuildContext context) =>
      Theme.of(context).extension<HmiStateColors>() ??
      HmiStateColors.solarizedLight;

  // =========================================================================
  // The groups view
  // =========================================================================

  Widget _groupsView(BuildContext context, List<Recipe> recipes,
      List<_Line> lines, List<DynamicValue?> live) {
    final groups = recipeGroups(recipes);
    final selected = (_selectedGroup != null && groups.contains(_selectedGroup))
        ? _selectedGroup
        : (groups.isEmpty ? null : groups.first);

    return _twoPane(
      (_) => _groupRail(context, recipes, groups, selected, lines, live),
      _panelOrDetail(context, recipes, groups, selected, lines, live),
    );
  }

  Widget _panelOrDetail(
    BuildContext context,
    List<Recipe> recipes,
    List<String> groups,
    String? selected,
    List<_Line> lines,
    List<DynamicValue?> live,
  ) {
    final about = _panelGroup;
    switch (_panel) {
      case _Panel.newGroup:
        return _newGroupPanel(context, recipes, lines, live);
      case _Panel.pick:
        final at = lines.indexWhere((l) => l.id == _panelLine);
        if (about != null && groups.contains(about) && at >= 0) {
          return _pickPanel(context, recipes, about, lines[at], live[at]);
        }
      case _Panel.grouping:
        final proposal = proposeRecipeGrouping(
            recipes, _config.lineNoun, [for (final l in lines) l.id]);
        if (proposal.isNotEmpty) {
          return _groupingPanel(context, recipes, lines, proposal);
        }
      case _Panel.rename:
        if (about != null && groups.contains(about)) {
          return _renamePanel(context, recipes, about);
        }
      case _Panel.delete:
        if (about != null && groups.contains(about)) {
          return _deletePanel(context, recipes, about);
        }
      case _Panel.none:
        break;
    }
    return selected == null
        ? _noGroups(context, recipes, lines)
        : _groupDetail(context, recipes, selected, lines, live);
  }

  Widget _groupRail(
    BuildContext context,
    List<Recipe> recipes,
    List<String> groups,
    String? selected,
    List<_Line> lines,
    List<DynamicValue?> live,
  ) {
    final theme = Theme.of(context);
    final proposal = proposeRecipeGrouping(
        recipes, _config.lineNoun, [for (final l in lines) l.id]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_config.groupNounPlural, style: theme.textTheme.titleMedium),
        const Divider(),
        if (proposal.isNotEmpty) _groupingOffer(context, proposal),
        Expanded(
          child: groups.isEmpty
              ? const SizedBox.shrink()
              : ReorderableListView.builder(
                  primary: false,
                  buildDefaultDragHandles: false,
                  itemCount: groups.length,
                  // Groups have no order of their own — a group sits where its
                  // first recipe sits — so the drag moves the group's
                  // recipes, as one block.
                  onReorderItem: (oldIndex, newIndex) => setState(() {
                    moveRecipeGroup(recipes, groups[oldIndex], newIndex);
                    _saveRecipes(recipes);
                  }),
                  itemBuilder: (context, i) => _groupCard(
                    context,
                    key: ValueKey('group:${groups[i]}'),
                    index: i,
                    group: groups[i],
                    selected: groups[i] == selected,
                    recipes: recipes,
                    lines: lines,
                    live: live,
                  ),
                ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text('New ${_config.groupNoun.toLowerCase()}'),
          onPressed: () => _openNewGroup(lines, live),
        ),
      ],
    );
  }

  Widget _groupCard(
    BuildContext context, {
    required Key key,
    required int index,
    required String group,
    required bool selected,
    required List<Recipe> recipes,
    required List<_Line> lines,
    required List<DynamicValue?> live,
  }) {
    final theme = Theme.of(context);
    final states = _states(context);
    final running = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final status =
          lineRecipeStatus(recipeInGroup(recipes, group, lines[i].id), live[i]);
      if (status.state == LineRecipeState.running) running.add(lines[i].name);
    }

    return Material(
      key: key,
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          _selectedGroup = group;
          _panel = _Panel.none;
          _report = null;
        }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
          child: Row(
            children: [
              // An explicit handle rather than long-press-anywhere: on a
              // touchscreen a long press is also how an operator steadies a
              // finger, and a drag started from that moves a group nobody
              // meant to move.
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Icon(Icons.drag_indicator, size: 18),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: group,
                      child: Text(
                        group,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      running.isEmpty
                          ? 'Not running'
                          : 'Running on ${_joinLabels(running)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: running.isEmpty
                            ? theme.colorScheme.onSurfaceVariant
                            : states.green,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final line in lines)
                          _lineChip(context, line,
                              recipeInGroup(recipes, group, line.id) != null),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A small marker per line: filled where the group has a recipe for it,
  /// dashed where it has none.
  Widget _lineChip(BuildContext context, _Line line, bool has) {
    final scheme = Theme.of(context).colorScheme;
    final number = line.name.split(' ').last;
    final short = '${_config.lineNoun.characters.first}$number';
    return Tooltip(
      message: has ? line.name : 'No recipe for ${line.name}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: has ? scheme.primary.withValues(alpha: 0.16) : null,
          border: has ? null : Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          short,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: has ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _noGroups(
      BuildContext context, List<Recipe> recipes, List<_Line> lines) {
    final theme = Theme.of(context);
    final loose = recipes.length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No ${_config.groupNounPlural.toLowerCase()} yet.',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'A ${_config.groupNoun.toLowerCase()} is one recipe for each '
              '${_config.lineNoun.toLowerCase()}, sent together. '
              '${loose == 0 ? '' : 'Recipes that are not in one are in the '
                  '${_config.lineNounPlural} view.'}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupDetail(BuildContext context, List<Recipe> recipes, String group,
      List<_Line> lines, List<DynamicValue?> live) {
    final theme = Theme.of(context);
    final statuses = [
      for (var i = 0; i < lines.length; i++)
        lineRecipeStatus(recipeInGroup(recipes, group, lines[i].id), live[i]),
    ];
    final covered =
        statuses.where((s) => s.state != LineRecipeState.noRecipe).length;
    final noun = _config.lineNoun.toLowerCase();
    final nouns = _config.lineNounPlural.toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(group, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    'One recipe for each $noun. Each $noun keeps its own '
                    'values — change them in the ${_config.lineNounPlural} '
                    'view.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            // Buttons, not a ⋮ menu: a menu is a route, and a route opened
            // from inside a floating window lands UNDER it — the ⋮ opened
            // nothing anyone could see.
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Rename ${_config.groupNoun.toLowerCase()}',
              onPressed: () => _openRename(group),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete ${_config.groupNoun.toLowerCase()}',
              onPressed: () => _openPanel(_Panel.delete, group: group),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.arrow_forward),
              label: Text(_sending
                  ? 'Sending...'
                  : covered == 1
                      ? 'Send to 1 $noun'
                      : 'Send to all $covered $nouns'),
              onPressed: (_sending || covered == 0)
                  ? null
                  : () => _sendGroup(group, lines, live, recipes),
            ),
          ],
        ),
        if (_report != null) _reportBlock(context, _report!),
        const SizedBox(height: 16),
        // The one scroll region in this view: the cards, however many lines
        // the asset has.
        Expanded(
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(builder: (context, constraints) {
                  const minCard = 240.0;
                  const gap = 12.0;
                  final perRow =
                      ((constraints.maxWidth + gap) / (minCard + gap))
                          .floor()
                          .clamp(1, lines.isEmpty ? 1 : lines.length);
                  // The usual case — every line on one row — gets cards of
                  // one height, buttons level along the bottom. A card that
                  // stops short of its neighbours reads as unfinished.
                  if (perRow >= lines.length) {
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < lines.length; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            Expanded(
                              child: _lineCard(
                                context,
                                position: i,
                                fill: true,
                                recipes: recipes,
                                group: group,
                                line: lines[i],
                                live: live[i],
                                status: statuses[i],
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }
                  final width =
                      (constraints.maxWidth - gap * (perRow - 1)) / perRow;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < lines.length; i++)
                        SizedBox(
                          width: width,
                          child: _lineCard(
                            context,
                            position: i,
                            recipes: recipes,
                            group: group,
                            line: lines[i],
                            live: live[i],
                            status: statuses[i],
                          ),
                        ),
                    ],
                  );
                }),
                const SizedBox(height: 16),
                _sendSummary(context, group, lines, statuses),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineCard(
    BuildContext context, {
    required int position,
    bool fill = false,
    required List<Recipe> recipes,
    required String group,
    required _Line line,
    required DynamicValue? live,
    required LineRecipeStatus status,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final states = _states(context);
    final recipe = recipeInGroup(recipes, group, line.id);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: status.state == LineRecipeState.differs
              ? states.orange.withValues(alpha: 0.6)
              : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(line.name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis),
              ),
              _statusChip(context, status),
            ],
          ),
          // Which recipe this product sends this line, by the recipe's own
          // name — the link between the product and the line's recipes has
          // to be visible to be trusted — and the way to change it.
          Row(
            children: [
              Expanded(
                child: Text(
                  recipe?.name ?? 'None picked',
                  style: recipe == null
                      ? theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant)
                      : theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _openPick(group, line),
                child: const Text('Change'),
              ),
            ],
          ),
          const Divider(height: 12),
          if (recipe == null) ...[
            Text('No recipe for ${line.name} in $group.',
                style: theme.textTheme.bodySmall),
            if (fill) const Spacer() else const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                // Copied from the line itself, so it fits that line exactly.
                onPressed: live == null
                    ? null
                    : () => _copyIntoGroup(group, line, live, recipes),
                child: Text('Copy from ${line.name} now'),
              ),
            ),
          ] else ...[
            ..._headlines(context, recipe, live),
            const SizedBox(height: 10),
            if (fill) const Spacer() else const SizedBox(height: 6),
            // A link above a full-width button, stacked on purpose rather than
            // side by side: the app's font is wide, a card is as narrow as the
            // window and the line count make it, and two buttons sharing a
            // row either overflowed or broke onto two lines at whatever width
            // they happened to stop fitting.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _view = _RecipesView.lines;
                  _selectedLine = position;
                  _selectedRecipe = recipe;
                  _report = null;
                }),
                child: const Text('All values'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _sending
                    ? null
                    : () => _send([(line: line, recipe: recipe)]),
                child: Text('Send to ${line.name}'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The first few values of a recipe, with the live value beside any that
  /// differ — enough to recognise it and to see what a send would change,
  /// without the whole table.
  List<Widget> _headlines(
      BuildContext context, Recipe recipe, DynamicValue? live) {
    final theme = Theme.of(context);
    final states = _states(context);
    final leaves =
        flattenRecipeShape([recipe.value]).where((row) => row.isLeaf).take(3);
    return [
      for (final row in leaves)
        () {
          final mine = valueAtPath(recipe.value, row.path)!;
          final now = live == null ? null : valueAtPath(live, row.path);
          final differs = now != null && now.value != mine.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Text(row.label,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 6),
                // The live value on a line of its own under the recipe's:
                // sharing one line, the pair was clipped to "now 20…" in a
                // narrow card — and the clipped half is the half that says
                // what a send would change.
                // A fixed share of the row, right-aligned, so the values of
                // every card form one column instead of starting wherever
                // their labels stopped.
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(formatRecipeValue(mine),
                          style: theme.textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (differs)
                        Text('now ${formatRecipeValue(now)}',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: states.orange),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          );
        }(),
    ];
  }

  Widget _statusChip(BuildContext context, LineRecipeStatus status) {
    final theme = Theme.of(context);
    final states = _states(context);
    final (text, color) = switch (status.state) {
      LineRecipeState.running => ('Running', states.green),
      LineRecipeState.differs => (
          status.changes == 1
              ? '1 value differs'
              : '${status.changes} values differ',
          states.orange
        ),
      LineRecipeState.waiting => (
          'Waiting',
          theme.colorScheme.onSurfaceVariant
        ),
      LineRecipeState.doesNotFit => ('Does not fit', states.orange),
      LineRecipeState.noRecipe => (
          'No recipe',
          theme.colorScheme.onSurfaceVariant
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child:
          Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
  }

  /// What "Send to all" will do, in one sentence, before it is pressed.
  Widget _sendSummary(BuildContext context, String group, List<_Line> lines,
      List<LineRecipeStatus> statuses) {
    final changing = <String>[];
    final running = <String>[];
    final missing = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final status = statuses[i];
      switch (status.state) {
        case LineRecipeState.differs:
          changing.add(
              '${lines[i].name} changes ${status.changes} value${status.changes == 1 ? '' : 's'}');
        case LineRecipeState.running:
          running.add(lines[i].name);
        case LineRecipeState.noRecipe:
          missing.add(lines[i].name);
        case LineRecipeState.waiting:
        case LineRecipeState.doesNotFit:
          break;
      }
    }
    final noun = _config.lineNoun.toLowerCase();
    final parts = <String>[
      'Sending writes each $noun its own $group recipe, one at a time.',
      if (changing.isNotEmpty) '${changing.join('; ')}.',
      if (running.isNotEmpty)
        running.length == 1
            ? '${running.single} already matches and is left as it is.'
            : '${_joinLabels(running)} already match and are left as they are.',
      if (missing.isNotEmpty)
        missing.length == 1
            ? '${missing.single} has no recipe here and is left alone.'
            : '${_joinLabels(missing)} have no recipe here and are left alone.',
    ];
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(parts.join(' '), style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  // -- panels ----------------------------------------------------------------
  //
  // Making a group, filing the old presets, renaming and deleting all happen
  // IN the right-hand pane rather than in a dialog of their own. A modal
  // opened from inside a floating window lands UNDER it: the floating window
  // is an entry at the top of the root overlay, and a pushed route is slotted
  // above the previous route — still below that entry. On a panel the form
  // would sit behind the recipes window, unreachable. A pane has no stacking
  // order to get wrong.

  void _openPanel(_Panel panel, {String? group}) => setState(() {
        _panel = panel;
        _panelGroup = group;
        _report = null;
      });

  void _closePanel() => setState(() {
        _panel = _Panel.none;
        _panelGroup = null;
      });

  Widget _groupingOffer(BuildContext context, List<RecipeGrouping> proposal) {
    final theme = Theme.of(context);
    final count = proposal.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1
                ? '1 saved recipe can go into a '
                    '${_config.groupNoun.toLowerCase()}.'
                : '$count saved recipes can be grouped into '
                    '${_config.groupNounPlural.toLowerCase()}.',
            style: theme.textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _openPanel(_Panel.grouping),
              child:
                  Text('Group into ${_config.groupNounPlural.toLowerCase()}'),
            ),
          ),
        ],
      ),
    );
  }

  /// The pane's frame for a panel: a title, what it is about, its body, and
  /// the buttons along the bottom.
  Widget _panelFrame(
    BuildContext context, {
    required String title,
    String? lead,
    required Widget body,
    required List<Widget> actions,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        if (lead != null) ...[
          const SizedBox(height: 4),
          Text(lead, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(primary: false, child: body),
        ),
        const Divider(height: 24),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 8,
          overflowSpacing: 4,
          children: actions,
        ),
      ],
    );
  }

  /// First open: files the recipes already named "Line 2 - Standard" into
  /// groups. Shown, never done silently — a name is the operator's own words
  /// — and nothing is sent to a line either way.
  Widget _groupingPanel(BuildContext context, List<Recipe> recipes,
      List<_Line> lines, List<RecipeGrouping> proposal) {
    final theme = Theme.of(context);
    final groups = <String>[];
    for (final item in proposal) {
      if (!groups.contains(item.group)) groups.add(item.group);
    }
    String? nameFor(String group, _Line line) {
      for (final item in proposal) {
        if (item.group == group && item.line == line.id) {
          return item.recipe.name;
        }
      }
      return null;
    }

    final untouched = [
      for (final r in recipes)
        if (r.group == null &&
            r.line == null &&
            !proposal.any((p) => identical(p.recipe, r)))
          r.name
    ];
    final lineWord = _config.lineNoun.toLowerCase();
    final groupWord = groups.length == 1
        ? _config.groupNoun.toLowerCase()
        : _config.groupNounPlural.toLowerCase();

    return _panelFrame(
      context,
      title:
          'Group your saved recipes into ${_config.groupNounPlural.toLowerCase()}',
      lead: 'These recipes share a name across '
          '${_config.lineNounPlural.toLowerCase()}, or have the $lineWord in '
          'their name. Grouped by that name, they make ${groups.length} '
          '$groupWord.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Table(
            border: TableBorder.all(color: theme.colorScheme.outlineVariant),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(children: [
                _panelCell(
                    Text(_config.groupNoun, style: theme.textTheme.labelLarge)),
                for (final line in lines)
                  _panelCell(
                      Text(line.name, style: theme.textTheme.labelLarge)),
              ]),
              for (final group in groups)
                TableRow(children: [
                  _panelCell(Text(group, style: theme.textTheme.titleSmall)),
                  for (final line in lines)
                    _panelCell(Text(
                      nameFor(group, line) ?? 'none',
                      style: nameFor(group, line) == null
                          ? theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant)
                          : theme.textTheme.bodySmall,
                    )),
                ]),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            [
              if (untouched.length == 1)
                '1 recipe has no $lineWord in its name — ${untouched.single} '
                    '— and stays where it is.'
              else if (untouched.isNotEmpty)
                '${untouched.length} recipes have no $lineWord in their names '
                    'and stay where they are.',
              'Nothing is sent to a $lineWord; only the list is rearranged.',
            ].join(' '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _closePanel, child: const Text('Not now')),
        FilledButton(
          onPressed: () => setState(() {
            applyRecipeGrouping(proposal);
            _selectedGroup = groups.first;
            _panel = _Panel.none;
            _saveRecipes(recipes);
          }),
          child: Text(groups.length == 1
              ? 'Group into 1 ${_config.groupNoun.toLowerCase()}'
              : 'Group into ${groups.length} '
                  '${_config.groupNounPlural.toLowerCase()}'),
        ),
      ],
    );
  }

  static Widget _panelCell(Widget child) =>
      Padding(padding: const EdgeInsets.all(8), child: child);

  void _openNewGroup(List<_Line> lines, List<DynamicValue?> live) {
    _panelName.clear();
    // Every line that has something to copy starts ticked.
    _ticked
      ..clear()
      ..addAll([
        for (var i = 0; i < lines.length; i++)
          if (live[i] != null) lines[i].id,
      ]);
    _openPanel(_Panel.newGroup);
  }

  Widget _newGroupPanel(BuildContext context, List<Recipe> recipes,
      List<_Line> lines, List<DynamicValue?> live) {
    final theme = Theme.of(context);
    final existing = recipeGroups(recipes).map((g) => g.toLowerCase()).toSet();
    final name = _panelName.text.trim();
    final clash = existing.contains(name.toLowerCase());
    final ready = name.isNotEmpty && !clash && _ticked.isNotEmpty;
    final groupWord = _config.groupNoun.toLowerCase();
    final lineWord = _config.lineNoun.toLowerCase();

    return _panelFrame(
      context,
      title: 'New $groupWord',
      lead: 'Each $lineWord starts from what it is running right now.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('recipes.newGroupName'),
            controller: _panelName,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Name',
              border: const OutlineInputBorder(),
              errorText: clash ? 'There is already one called that.' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text(_config.lineNounPlural, style: theme.textTheme.labelLarge),
          for (var i = 0; i < lines.length; i++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _ticked.contains(lines[i].id),
              // A line that has not reported has nothing to copy.
              onChanged: live[i] == null
                  ? null
                  : (on) => setState(() => on == true
                      ? _ticked.add(lines[i].id)
                      : _ticked.remove(lines[i].id)),
              title: Text(lines[i].name),
              subtitle:
                  live[i] == null ? const Text('waiting for a value') : null,
            ),
          Text(
            'Untick a $lineWord that does not make this $groupWord. You can '
            'add it later.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _closePanel, child: const Text('Cancel')),
        FilledButton(
          onPressed: ready
              ? () {
                  // Read now, not from this build — see _renameField.
                  final typed = _panelName.text.trim();
                  if (typed.isEmpty || existing.contains(typed.toLowerCase())) {
                    return;
                  }
                  _panel = _Panel.none;
                  _createGroup(
                      typed,
                      [
                        for (var i = 0; i < lines.length; i++)
                          if (_ticked.contains(lines[i].id) && live[i] != null)
                            (line: lines[i], live: live[i]!),
                      ],
                      recipes);
                }
              : null,
          child: Text('Create $groupWord'),
        ),
      ],
    );
  }

  void _openPick(String group, _Line line) => setState(() {
        _panel = _Panel.pick;
        _panelGroup = group;
        _panelLine = line.id;
        _report = null;
      });

  /// Which of a line's recipes a product sends it.
  ///
  /// The line's own recipes are offered — the ones kept for it and the ones
  /// saved before recipes knew their line — with how each stands against the
  /// line right now, so the choice is made knowing what a send would change.
  /// A recipe replaced here is kept in the line's list, never deleted.
  Widget _pickPanel(BuildContext context, List<Recipe> recipes, String group,
      _Line line, DynamicValue? live) {
    final theme = Theme.of(context);
    final states = _states(context);
    final current = recipeInGroup(recipes, group, line.id);
    final candidates = recipeCandidatesFor(recipes, group, line.id);

    Widget standing(Recipe recipe) {
      final status = lineRecipeStatus(recipe, live);
      final (text, color) = switch (status.state) {
        LineRecipeState.running => ('Running on ${line.name}', states.green),
        LineRecipeState.differs => (
            '${status.changes} value${status.changes == 1 ? '' : 's'} '
                'differ${status.changes == 1 ? 's' : ''} from ${line.name}',
            states.orange
          ),
        LineRecipeState.doesNotFit => (
            'Does not fit ${line.name}',
            states.orange
          ),
        _ => ('', theme.colorScheme.onSurfaceVariant),
      };
      return Text(text,
          style: theme.textTheme.labelSmall?.copyWith(color: color));
    }

    void use(Recipe recipe) => setState(() {
          useRecipeInGroup(recipes, group, line.id, recipe);
          _panel = _Panel.none;
          _saveRecipes(recipes);
        });

    return _panelFrame(
      context,
      title: "${line.name}'s recipe in $group",
      lead: 'The recipe $group sends to ${line.name}. One that is replaced '
          "stays in ${line.name}'s list, not in a "
          '${_config.groupNoun.toLowerCase()}.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (current != null)
            ListTile(
              leading: Icon(Icons.check_circle, color: states.green),
              title: Text(current.name),
              subtitle: standing(current),
              trailing: TextButton(
                onPressed: () => setState(() {
                  current.group = null;
                  _panel = _Panel.none;
                  _saveRecipes(recipes);
                }),
                child: Text('Take out of $group'),
              ),
            ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No other recipes on ${line.name} that are not in a '
                '${_config.groupNoun.toLowerCase()}.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final recipe in candidates)
            ListTile(
              key: ValueKey(recipe),
              leading: const Icon(Icons.radio_button_unchecked),
              title: Text(recipe.name),
              subtitle: standing(recipe),
              onTap: () => use(recipe),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text('Copy from ${line.name} now'),
            subtitle: const Text('A new recipe, from what the line runs'),
            enabled: live != null,
            onTap: live == null
                ? null
                : () => _copyIntoGroup(group, line, live, recipes),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _closePanel, child: const Text('Cancel')),
      ],
    );
  }

  void _openRename(String group) {
    _panelName.text = group;
    _openPanel(_Panel.rename, group: group);
  }

  Widget _renamePanel(
      BuildContext context, List<Recipe> recipes, String group) {
    final others = recipeGroups(recipes)
        .where((g) => g != group)
        .map((g) => g.toLowerCase())
        .toSet();
    final name = _panelName.text.trim();
    final clash = others.contains(name.toLowerCase());
    return _panelFrame(
      context,
      title: 'Rename $group',
      body: TextField(
        controller: _panelName,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Name',
          border: const OutlineInputBorder(),
          errorText: clash ? 'There is already one called that.' : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: _closePanel, child: const Text('Cancel')),
        FilledButton(
          onPressed: (name.isEmpty || clash || name == group)
              ? null
              : () {
                  // Read now, not from this build — see _renameField.
                  final typed = _panelName.text.trim();
                  if (typed.isEmpty || typed == group) return;
                  if (others.contains(typed.toLowerCase())) return;
                  setState(() {
                    _renameGroup(recipes, group, typed);
                    _panel = _Panel.none;
                    _saveRecipes(recipes);
                  });
                },
          child: const Text('Rename'),
        ),
      ],
    );
  }

  /// Renames [from] to [to] on every recipe in it.
  ///
  /// Also keeps the stored name in step when it still has the shape this
  /// dialog gave it (`Line 2 - <product>`): a station still on an older build
  /// knows nothing of products and shows that name, so it should say the new
  /// one too.
  void _renameGroup(List<Recipe> recipes, String from, String to) {
    for (final recipe in recipes) {
      if (recipe.group != from) continue;
      recipe.group = to;
      if (recipe.name == from) {
        recipe.name = to;
      } else if (recipe.name.endsWith(' - $from')) {
        recipe.name =
            '${recipe.name.substring(0, recipe.name.length - from.length)}$to';
      }
    }
    if (_selectedGroup == from) _selectedGroup = to;
  }

  Widget _deletePanel(
      BuildContext context, List<Recipe> recipes, String group) {
    final members = recipes.where((r) => r.group == group).length;
    final lineWord = _config.lineNoun.toLowerCase();
    return _panelFrame(
      context,
      title: 'Delete $group?',
      body: Text(
        'Its $members recipe${members == 1 ? '' : 's'} '
        '${members == 1 ? 'is' : 'are'} deleted. Nothing is sent to a '
        '$lineWord, and no $lineWord changes.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(onPressed: _closePanel, child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _states(context).red,
          ),
          onPressed: () => setState(() {
            recipes.removeWhere((r) => r.group == group);
            _selectedGroup = null;
            _panel = _Panel.none;
            _saveRecipes(recipes);
          }),
          child: const Text('Delete'),
        ),
      ],
    );
  }

  // =========================================================================
  // The lines view
  // =========================================================================

  Widget _linesView(BuildContext context, List<Recipe> recipes,
      List<_Line> lines, List<DynamicValue?> live) {
    if (lines.isEmpty) {
      return const Center(child: Text('Waiting for values...'));
    }
    final at = _selectedLine.clamp(0, lines.length - 1);
    final line = lines[at];
    final onLine = recipesOnLine(recipes, line.id);
    final selected =
        (_selectedRecipe != null && onLine.contains(_selectedRecipe))
            ? _selectedRecipe
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _lineTabs(context, lines, at),
        const SizedBox(height: 8),
        Expanded(
          child: _twoPane(
            (_) =>
                _lineRail(context, recipes, onLine, selected, line, live[at]),
            _lineDetail(context, recipes, selected, line, live[at]),
          ),
        ),
      ],
    );
  }

  Widget _lineTabs(BuildContext context, List<_Line> lines, int at) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      primary: false,
      child: Row(
        children: [
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _leaveThen(() => setState(() {
                      _selectedLine = i;
                      _selectedRecipe = null;
                      _renaming = null;
                      _report = null;
                    })),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: i == at
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Text(
                    lines[i].name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: i == at ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _lineRail(BuildContext context, List<Recipe> recipes,
      List<Recipe> onLine, Recipe? selected, _Line line, DynamicValue? live) {
    final theme = Theme.of(context);
    // A product's recipes come first, in the products' own order: that order
    // is set by dragging in the products view, and a drag here that moved a
    // product's recipe would quietly reshuffle that list too.
    final order = recipeGroups(recipes);
    final grouped = [
      for (final r in onLine)
        if (r.group != null) r
    ]..sort(
        (a, b) => order.indexOf(a.group!).compareTo(order.indexOf(b.group!)));
    final loose = [
      for (final r in onLine)
        if (r.group == null) r
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${line.name} recipes', style: theme.textTheme.titleMedium),
        const Divider(),
        Expanded(
          child: onLine.isEmpty
              ? Center(
                  child: Text('No recipes for ${line.name} yet.',
                      style: theme.textTheme.bodySmall),
                )
              // One scroll for both sections. The recipes that are not in a
              // product are this view's to arrange, so they alone drag.
              : CustomScrollView(
                  primary: false,
                  slivers: [
                    SliverList.list(children: [
                      for (final recipe in grouped)
                        _lineRecipeCard(
                            context, recipe, selected, line, live, recipes),
                    ]),
                    if (loose.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                          child: Text(
                            'Not in a ${_config.groupNoun.toLowerCase()}',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                      SliverReorderableList(
                        itemCount: loose.length,
                        // The move is made among this line's loose recipes and
                        // written back into the slots they already held, so a
                        // drag here cannot move another line's recipe or a
                        // product's.
                        onReorderItem: (oldIndex, newIndex) => setState(() {
                          reorderWithin(recipes, loose, oldIndex, newIndex);
                          _saveRecipes(recipes);
                        }),
                        itemBuilder: (context, i) => _lineRecipeCard(
                          context,
                          loose[i],
                          selected,
                          line,
                          live,
                          recipes,
                          key: ObjectKey(loose[i]),
                          dragIndex: i,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _newRecipeName,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'New recipe',
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (v) {
            if (live != null) _addLineRecipe(v, line, live, recipes);
          },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text('New from ${line.name} now'),
          // With nothing live to copy there is no recipe to make: a preset
          // seeded from a line that has not reported would be an empty struct
          // that later looks like a real one.
          onPressed: (live == null || _newRecipeName.text.trim().isEmpty)
              ? null
              : () => _addLineRecipe(_newRecipeName.text, line, live, recipes),
        ),
      ],
    );
  }

  Widget _lineRecipeCard(BuildContext context, Recipe recipe, Recipe? selected,
      _Line line, DynamicValue? live, List<Recipe> recipes,
      {Key? key, int? dragIndex}) {
    final theme = Theme.of(context);
    final states = _states(context);
    final isSelected = identical(recipe, selected);
    final status = lineRecipeStatus(recipe, live);
    final (note, color) = switch (status.state) {
      LineRecipeState.running => ('Running on ${line.name}', states.green),
      LineRecipeState.differs => (
          '${status.changes} value${status.changes == 1 ? '' : 's'} differ${status.changes == 1 ? 's' : ''} from ${line.name}',
          states.orange
        ),
      LineRecipeState.doesNotFit => (
          'Does not fit ${line.name}',
          states.orange
        ),
      _ => ('', theme.colorScheme.onSurfaceVariant),
    };
    final title = recipe.name;
    // The product, when the name alone does not already say it.
    final inGroup = recipe.group != null && recipe.group != recipe.name
        ? recipe.group
        : null;

    return Material(
      key: key,
      color: isSelected
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => identical(recipe, _selectedRecipe)
            ? null
            : _leaveThen(() => setState(() {
                  _selectedRecipe = recipe;
                  _renaming = null;
                  _report = null;
                })),
        child: Padding(
          padding: EdgeInsets.fromLTRB(dragIndex == null ? 10 : 2, 8, 0, 8),
          child: Row(
            children: [
              // An explicit handle, as on the products list: a long press is
              // also how an operator steadies a finger on a touchscreen.
              if (dragIndex != null)
                ReorderableDragStartListener(
                  index: dragIndex,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Icon(Icons.drag_indicator, size: 18),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: recipe.name,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (inGroup != null)
                      Text('in $inGroup',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    if (note.isNotEmpty)
                      Text(note,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: color)),
                  ],
                ),
              ),
              // One tap asks, the second deletes: a bin a finger can brush on
              // a touchscreen must not take a recipe with it.
              if (identical(_confirmDelete, recipe)) ...[
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: states.red,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36)),
                  onPressed: () => _deleteRecipe(recipe, recipes),
                  child: const Text('Delete'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Keep ${recipe.name}',
                  onPressed: () => setState(() => _confirmDelete = null),
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Delete ${recipe.name}',
                  onPressed: () => setState(() => _confirmDelete = recipe),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineDetail(BuildContext context, List<Recipe> recipes, Recipe? recipe,
      _Line line, DynamicValue? live) {
    final theme = Theme.of(context);
    final groups = recipeGroups(recipes);

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (recipe != null && identical(_renaming, recipe))
                _renameField(context, recipe, recipes)
              else
                Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: recipe == null ? line.name : recipe.name),
                          if (recipe != null)
                            TextSpan(
                              text: ' on ${line.name}',
                              style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.normal),
                            ),
                        ]),
                        style: theme.textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (recipe != null)
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        // Said plainly: in a product the title IS the
                        // product's name, so this renames it on every line —
                        // which a bare "Rename" beside one line's recipe
                        // would hide.
                        tooltip: 'Rename recipe',
                        onPressed: () => setState(() {
                          _renaming = recipe;
                          _renameText.text = recipe.name;
                        }),
                      ),
                  ],
                ),
              if (recipe != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(_config.groupNoun, style: theme.textTheme.bodySmall),
                    const SizedBox(width: 8),
                    // Chips, not a dropdown: a dropdown's menu is a route,
                    // and from inside a floating window it opens underneath.
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final group in groups)
                            ChoiceChip(
                              label: Text(group),
                              selected: recipe.group == group,
                              visualDensity: VisualDensity.compact,
                              // One recipe per line in a group: a group that
                              // already holds this line's recipe is shown,
                              // but cannot be picked here — Change on its
                              // card is where one is swapped for another.
                              onSelected: group == recipe.group ||
                                      recipeInGroup(recipes, group, line.id) ==
                                          null
                                  ? (_) =>
                                      _setGroup(recipe, group, line, recipes)
                                  : null,
                            ),
                          ChoiceChip(
                            label: Text('None'),
                            selected: recipe.group == null,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) =>
                                _setGroup(recipe, null, line, recipes),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (recipe.line == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Saved before recipes knew their '
                      '${_config.lineNoun.toLowerCase()}, so it is offered on '
                      'every ${_config.lineNoun.toLowerCase()}.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),
        ),
        ..._editButtons(context, recipe, line, recipes),
      ],
    );

    final rows = flattenRecipeShape([if (recipe != null) recipe.value, live]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (_report != null) _reportBlock(context, _report!),
        const Divider(height: 24),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    live == null
                        ? 'Waiting for ${line.name}...'
                        : 'This recipe has no values in it.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : _valuesTable(context, rows, recipe, line, live, recipes),
        ),
      ],
    );
  }

  /// The recipe's name, as a field: Enter or the tick keeps it, Escape or
  /// the cross puts it back.
  ///
  /// Renames this recipe and nothing else. Two recipes may share a name — one
  /// product kept on several lines usually does — so there is nothing to
  /// clash with. A product is renamed in the products view.
  Widget _renameField(
      BuildContext context, Recipe recipe, List<Recipe> recipes) {
    final name = _renameText.text.trim();
    final ready = name.isNotEmpty;

    void commit() {
      // The field's text NOW, not the `name` this build captured: a commit
      // can run from a callback built before the last keystroke landed, and
      // it then saved the old name while the field showed the new one.
      final typed = _renameText.text.trim();
      if (typed.isEmpty) return;
      setState(() {
        recipe.name = typed;
        _renaming = null;
        _saveRecipes(recipes);
      });
    }

    void cancel() => setState(() => _renaming = null);

    return Row(
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): cancel,
            },
            child: TextField(
              key: const ValueKey('recipes.renameField'),
              controller: _renameText,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Recipe name',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => commit(),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.check),
          tooltip: 'Keep this name',
          onPressed: ready ? commit : null,
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: cancel,
        ),
      ],
    );
  }

  /// The lines view's header buttons for [recipe]: Edit and Send, or while
  /// editing, Cancel, Save and Send — which then sends what is on screen
  /// without storing it.
  List<Widget> _editButtons(
      BuildContext context, Recipe? recipe, _Line line, List<Recipe> recipes) {
    final editing = recipe != null && identical(_editing, recipe);
    final dirty = editing && _dirty;
    Future<void> send() async {
      await _settleFields();
      if (!mounted || recipe == null) return;
      final draft = _draft;
      final sending = editing && draft != null
          ? Recipe(
              name: recipe.name,
              value: draft,
              line: recipe.line,
              group: recipe.group)
          : recipe;
      final unsaved = editing && _dirty;
      await _send(
        [(line: line, recipe: sending)],
        alreadyDecided: unsaved
            ? [
                LineSendOutcome(
                  label: recipe.name,
                  ok: true,
                  message: 'the values sent are not saved as the recipe — '
                      'Save keeps them',
                ),
              ]
            : const [],
      );
    }

    return [
      if (editing) ...[
        TextButton(onPressed: _cancelEdit, child: const Text('Cancel')),
        const SizedBox(width: 4),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save'),
          onPressed: dirty ? () => _saveEdit(recipes) : null,
        ),
      ] else
        OutlinedButton.icon(
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit'),
          onPressed: recipe == null ? null : () => _startEditing(recipe),
        ),
      const SizedBox(width: 8),
      FilledButton.icon(
        icon: const Icon(Icons.arrow_forward),
        label: Text(_sending
            ? 'Sending...'
            : dirty
                ? 'Send without saving'
                : 'Send to ${line.name}'),
        onPressed: (recipe == null || _sending) ? null : send,
      ),
    ];
  }

  // -- the values table ----------------------------------------------------

  /// `Member | Recipe | <line> now` — the recipe's value and the line's live
  /// value for a member on the same row, in the one scroll region this view
  /// has.
  Widget _valuesTable(BuildContext context, List<RecipeRow> rows,
      Recipe? recipe, _Line line, DynamicValue? live, List<Recipe> recipes) {
    final scheme = Theme.of(context).colorScheme;
    final states = _states(context);
    final widths = <int, TableColumnWidth>{
      0: const FlexColumnWidth(2.0),
      1: const FlexColumnWidth(1.5),
      if (recipe != null) 2: const FlexColumnWidth(1.2),
    };
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
              if (recipe != null) _cell(Text('Recipe', style: headerStyle)),
              _cell(Text('${line.name} now', style: headerStyle)),
            ]),
          ],
        ),
        const Divider(height: 1),
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
                      if (recipe != null)
                        _cell(_recipeCell(context, row, recipe, recipes)),
                      _liveCellFor(context, row, recipe, live, states),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The live cell, tinted where it differs from what the recipe would send —
  /// so the rows a send would change stand out before it is pressed.
  Widget _liveCellFor(BuildContext context, RecipeRow row, Recipe? recipe,
      DynamicValue? live, HmiStateColors states) {
    final child = _liveCell(context, row, live);
    if (recipe == null || live == null || !row.isLeaf) return _cell(child);
    final mine = valueAtPath(_shown(recipe), row.path);
    final now = valueAtPath(live, row.path);
    final differs = mine != null && now != null && mine.value != now.value;
    return Container(
      color: differs ? states.orange.withValues(alpha: 0.14) : null,
      child: _cell(child),
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

  /// The values the recipe column shows: the draft while editing, the
  /// stored recipe otherwise.
  DynamicValue _shown(Recipe recipe) =>
      identical(_editing, recipe) && _draft != null ? _draft! : recipe.value;

  /// The recipe's own cell — read-only until Edit, then editing the draft.
  ///
  /// [DynamicValueWidget] is handed a single LEAF rather than the whole tree,
  /// which is what lets the editors it already owns (the switch, the enum
  /// dropdown, the controller-keeping text field) be reused a row at a time
  /// instead of being reimplemented for the table.
  Widget _recipeCell(BuildContext context, RecipeRow row, Recipe recipe,
      List<Recipe> recipes) {
    final editing = identical(_editing, recipe) && _draft != null;
    final value = valueAtPath(_shown(recipe), row.path);
    if (value == null) return _absent(context);
    if (!row.isLeaf) {
      return Text(formatRecipeValue(value),
          style: Theme.of(context).textTheme.bodySmall);
    }
    if (!editing) {
      return Text(formatRecipeValue(value),
          style: Theme.of(context).textTheme.bodyMedium,
          softWrap: false,
          overflow: TextOverflow.ellipsis);
    }
    // The label and description are already the Member column's job; leaving
    // them on the leaf would print each one twice per row.
    final leaf = DynamicValue.from(value)
      ..displayName = null
      ..description = null;
    // Dense, because a row of this table is a row and not a form field.
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        visualDensity: VisualDensity.compact,
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
      ),
      child: DynamicValueWidget(
        value: leaf,
        // Leaving a field keeps what was typed — in the draft. Nothing is
        // stored until Save.
        commitOnFocusLoss: true,
        onSubmitted: (newValue) => setState(() {
          final draft = _draft;
          if (draft != null) _draft = setAtPath(draft, row.path, newValue);
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

  /// A member this line does not have.
  ///
  /// Spelled out, never left blank and never shown as a zero: a blank reads as
  /// "nothing set" and a zero reads as a setpoint, and both are wrong about a
  /// line that simply has no such member.
  Widget _absent(BuildContext context) => _quiet(context, 'not present');

  /// A cell that says something about itself rather than carrying a value.
  Widget _quiet(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );

  // -- the send report -----------------------------------------------------

  Widget _reportBlock(BuildContext context, List<LineSendOutcome> outcomes) {
    final states = _states(context);
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
                    outcome.ok
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: outcome.ok ? states.green : states.red,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '${outcome.label}: ',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: outcome.message),
                      ]),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
