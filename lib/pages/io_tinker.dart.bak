import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/core/state_man.dart';
import '../widgets/beckhoff.dart';
import '../providers/state_man.dart';
import '../widgets/base_scaffold.dart';
import 'loading.dart';

class IoTinkerPage extends ConsumerStatefulWidget {
  final logger = Logger();

  IoTinkerPage({super.key});

  @override
  ConsumerState<IoTinkerPage> createState() => _IoTinkerPageState();
}

class _IoTinkerPageState extends ConsumerState<IoTinkerPage>
    with TickerProviderStateMixin {
  String? selectedKey;
  late Animation<int> animation;
  late AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    animation = IntTween(begin: 80, end: 255).animate(controller)
      ..addStatusListener((status) async {
        if (!mounted) return;
        if (status == AnimationStatus.completed) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!mounted) return;
          controller.reverse();
        } else if (status == AnimationStatus.dismissed) {
          controller.forward();
        }
      });
    controller.forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(StateMan, Map<String, DynamicValue>)>(
      future: ref.watch(stateManProvider.future).then(
            (stateMan) async => (
              stateMan,
              await stateMan
                  .readMany(stateMan.keyMappings.nodes.entries
                      .where((entry) => entry.value.io == true)
                      .map((entry) => entry.key)
                      .toList())
                  .onError((error, stackTrace) {
                widget.logger.e('IoTinker Error: $error');
                return {};
              })
            ),
          ),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          widget.logger.e('IoTinker Error: ${snapshot.error}');
          return LoadingPage(title: 'IoTinker Error: ${snapshot.error}');
        }
        if (!snapshot.hasData) {
          return const LoadingPage(title: 'IoTinker');
        }
        final (stateMan, map) = snapshot.data!;

        return BaseScaffold(
          title: 'IoTinker',
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: map.keys.map((key) {
                // Todo, fix this
                final nodeId = stateMan.keyMappings.lookupNodeId(key);
                final value = map[key]!;
                return _buildUnit(key, nodeId!, value, animation);
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUnit(
      String key, NodeId nodeId, DynamicValue value, Animation<int> animation) {
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: ref
          .watch(stateManProvider.future)
          .asStream()
          .asyncExpand((stateMan) => CombineLatestStream(
                  [
                    stateMan
                        .subscribe(NodeId.fromString(
                                nodeId.namespace, "${nodeId.string}.raw_state")
                            .toString())
                        .asStream()
                        .switchMap((s) => s),
                    stateMan
                        .subscribe(NodeId.fromString(nodeId.namespace,
                                "${nodeId.string}.force_values")
                            .toString())
                        .asStream()
                        .switchMap((s) => s),
                  ],
                  (List<DynamicValue> values) => {
                        "raw_state": values[0],
                        "force_values": values[1],
                      })),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.hasError) {
          return ModuleWidget(
            ledStates: List.filled(8, IOState.low),
            disconnected: true,
            animation: animation,
            name: value.contains("on_filters")
                ? "EL1008"
                : "EL2008", // todo this is not great
          );
        }
        final data = snapshot.data!;
        List<IOState> ledStates = List.generate(8, (i) {
          final forceValue = data["force_values"]![i].asInt;
          if (forceValue == 1) return IOState.forcedLow;
          if (forceValue == 2) return IOState.forcedHigh;
          return (data["raw_state"]!.asInt & (1 << i)) != 0
              ? IOState.high
              : IOState.low;
        });
        return GestureDetector(
          onTap: () {
            setState(() {
              selectedKey = key;
            });
            showDialog(
              context: context,
              builder: (context) =>
                  _buildUnitDialog(key, nodeId, value, animation),
            ).then((_) {
              setState(() {
                selectedKey = null;
              });
            });
          },
          child: ModuleWidget(
            ledStates: ledStates,
            selected: selectedKey == key,
            animation: animation,
            name: value.contains("on_filters")
                ? "EL1008"
                : "EL2008", // todo this is not great,
          ),
        );
      },
    );
  }

  Widget _buildUnitDialog(
      String key, NodeId nodeId, DynamicValue value, Animation<int> animation) {
    return AlertDialog(
      title: Text('$key'),
      content: FutureBuilder<StateMan>(
        future: ref.watch(stateManProvider.future),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.hasError) {
            return const SizedBox.shrink();
          }
          final stateMan = snapshot.data!;
          return StreamBuilder<Map<String, DynamicValue>>(
            stream: CombineLatestStream([
              stateMan
                  .subscribe(NodeId.fromString(
                          nodeId.namespace, "${nodeId.string}.raw_state")
                      .toString())
                  .asStream()
                  .switchMap((s) => s),
              stateMan
                  .subscribe(NodeId.fromString(
                          nodeId.namespace, "${nodeId.string}.force_values")
                      .toString())
                  .asStream()
                  .switchMap((s) => s),
              if (value.contains("processed_state"))
                stateMan
                    .subscribe(NodeId.fromString(nodeId.namespace,
                            "${nodeId.string}.processed_state")
                        .toString())
                    .asStream()
                    .switchMap((s) => s),
              if (value.contains("on_filters"))
                stateMan
                    .subscribe(NodeId.fromString(
                            nodeId.namespace, "${nodeId.string}.on_filters")
                        .toString())
                    .asStream()
                    .switchMap((s) => s),
              if (value.contains("off_filters"))
                stateMan
                    .subscribe(NodeId.fromString(
                            nodeId.namespace, "${nodeId.string}.off_filters")
                        .toString())
                    .asStream()
                    .switchMap((s) => s),
            ], (List<DynamicValue> values) {
              return {
                "raw_state": values[0],
                "force_values": values[1],
                if (value.contains("processed_state"))
                  "processed_state": values[2],
                if (value.contains("on_filters")) "on_filters": values[3],
                if (value.contains("off_filters")) "off_filters": values[4],
              };
            }),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.hasError) {
                return const SizedBox.shrink();
              }
              final map = snapshot.data!;
              List<bool> rawStates = List.generate(
                  8, (i) => (map["raw_state"]!.asInt & (1 << i)) != 0);
              List<bool>? processedStates = map["processed_state"] != null
                  ? List.generate(
                      8, (i) => (map["processed_state"]!.asInt & (1 << i)) != 0)
                  : null;

              return Column(
                children: [
                  for (int i = 0; i < 8; i = i + 2)
                    Column(
                      children: [
                        RowIOView(
                          leftRaw: rawStates[i],
                          rightRaw: rawStates[i + 1],
                          leftProcessed: processedStates?[i],
                          rightProcessed: processedStates?[i + 1],
                          leftSelected: map["force_values"]![i].asInt,
                          rightSelected: map["force_values"]![i + 1].asInt,
                          animationValue: animation,
                          leftOnChanged: (value) async {
                            map["force_values"]![i].value = value;
                            await stateMan.write(
                                NodeId.fromString(nodeId.namespace,
                                        "${nodeId.string}.force_values")
                                    .toString(),
                                map["force_values"]!);
                          },
                          rightOnChanged: (value) async {
                            map["force_values"]![i + 1].value = value;
                            await stateMan.write(
                                NodeId.fromString(nodeId.namespace,
                                        "${nodeId.string}.force_values")
                                    .toString(),
                                map["force_values"]!);
                          },
                          leftDescription: value["descriptions"][i].asString,
                          rightDescription:
                              value["descriptions"][i + 1].asString,
                          leftFilterEdit: map.containsKey("on_filters") &&
                                  map.containsKey("off_filters")
                              ? FilterEdit(
                                  onFilter: map["on_filters"]![i].asInt,
                                  offFilter: map["off_filters"]![i].asInt,
                                  onChangedOnFilter: (value) async {
                                    map["on_filters"]![i].value = value;
                                    await stateMan.write(
                                        NodeId.fromString(nodeId.namespace,
                                                "${nodeId.string}.on_filters")
                                            .toString(),
                                        map["on_filters"]!);
                                  },
                                  onChangedOffFilter: (value) async {
                                    map["off_filters"]![i].value = value;
                                    await stateMan.write(
                                        NodeId.fromString(nodeId.namespace,
                                                "${nodeId.string}.off_filters")
                                            .toString(),
                                        map["off_filters"]!);
                                  },
                                )
                              : null,
                          rightFilterEdit: map.containsKey("on_filters") &&
                                  map.containsKey("off_filters")
                              ? FilterEdit(
                                  onFilter: map["on_filters"]![i + 1].asInt,
                                  offFilter: map["off_filters"]![i + 1].asInt,
                                  onChangedOnFilter: (value) async {
                                    map["on_filters"]![i + 1].value = value;
                                    await stateMan.write(
                                        NodeId.fromString(nodeId.namespace,
                                                "${nodeId.string}.on_filters")
                                            .toString(),
                                        map["on_filters"]!);
                                  },
                                  onChangedOffFilter: (value) async {
                                    map["off_filters"]![i + 1].value = value;
                                    await stateMan.write(
                                        NodeId.fromString(nodeId.namespace,
                                                "${nodeId.string}.off_filters")
                                            .toString(),
                                        map["off_filters"]!);
                                  },
                                )
                              : null,
                        ),
                        const SizedBox(height: 6),
                      ],
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class IOForceButton extends StatelessWidget {
  const IOForceButton(
      {super.key, required this.onChanged, required this.selected});
  final void Function(int) onChanged;
  final int selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: SegmentedButton(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: 0,
            label: Text('Auto'),
          ),
          ButtonSegment(
            value: 1,
            label: Text('Low '),
          ),
          ButtonSegment(
            value: 2,
            label: Text('High'),
          ),
        ],
        selected: {selected},
        onSelectionChanged: (value) {
          onChanged(value.first);
        },
      ),
    );
  }
}

class FilterEdit extends StatelessWidget {
  final int onFilter;
  final int offFilter;
  final void Function(int) onChangedOnFilter;
  final void Function(int) onChangedOffFilter;
  const FilterEdit(
      {super.key,
      required this.onFilter,
      required this.offFilter,
      required this.onChangedOnFilter,
      required this.onChangedOffFilter});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 100,
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: 'On filter',
                  suffixText: 'ms',
                ),
                initialValue: onFilter.toString(),
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    onChangedOnFilter(int.parse(value));
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 100,
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Off filter',
                  suffixText: 'ms',
                ),
                initialValue: offFilter.toString(),
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    onChangedOffFilter(int.parse(value));
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class RowControl extends StatelessWidget {
  final String? description;
  final int selected;
  final void Function(int) onChanged;
  final FilterEdit? filterEdit;
  const RowControl(
      {super.key,
      required this.description,
      required this.selected,
      required this.onChanged,
      this.filterEdit});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                description!.isNotEmpty
                    ? description![0].toUpperCase() + description!.substring(1)
                    : description!,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          IOForceButton(
            selected: selected,
            onChanged: onChanged,
          ),
          if (filterEdit != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: filterEdit!,
            ),
        ],
      ),
    );
  }
}

class RowIOView extends AnimatedWidget {
  const RowIOView({
    super.key,
    required this.leftRaw,
    required this.rightRaw,
    required this.leftProcessed,
    required this.rightProcessed,
    required this.leftSelected,
    required this.rightSelected,
    required this.leftOnChanged,
    required this.rightOnChanged,
    this.leftDescription,
    this.rightDescription,
    this.leftFilterEdit,
    this.rightFilterEdit,
    required Animation<int> animationValue,
  }) : super(listenable: animationValue);
  final int leftSelected;
  final int rightSelected;
  final bool leftRaw;
  final bool rightRaw;
  final bool? leftProcessed;
  final bool? rightProcessed;
  final void Function(int) leftOnChanged;
  final void Function(int) rightOnChanged;
  final String? leftDescription;
  final String? rightDescription;
  final FilterEdit? leftFilterEdit;
  final FilterEdit? rightFilterEdit;

  @override
  Widget build(BuildContext context) {
    final animation = listenable as Animation<int>;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // LEFT COLUMN: description + button
        RowControl(
          description: leftDescription,
          selected: leftSelected,
          onChanged: leftOnChanged,
          filterEdit: leftFilterEdit,
        ),
        const SizedBox(width: 16),
        // MIDDLE: the three boxes in a row
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            CustomPaint(
              size: const Size(120, 120),
              painter: TriangleBoxPainter(
                colorLeft: leftRaw ? Colors.green : Colors.grey,
                colorRight:
                    leftProcessed ?? leftRaw ? Colors.green : Colors.grey,
                animationValue: leftSelected == 0 ? 0 : animation.value,
              ),
            ),
            Container(
              width: 120,
              height: 120,
              color: Colors.grey,
            ),
            CustomPaint(
              size: const Size(120, 120),
              painter: TriangleBoxPainter(
                colorLeft: rightRaw ? Colors.green : Colors.grey,
                colorRight:
                    rightProcessed ?? rightRaw ? Colors.green : Colors.grey,
                animationValue: rightSelected == 0 ? 0 : animation.value,
              ),
            ),
          ],
        ),
        const SizedBox(width: 16),
        // RIGHT COLUMN: description + button
        RowControl(
          description: rightDescription,
          selected: rightSelected,
          onChanged: rightOnChanged,
          filterEdit: rightFilterEdit,
        ),
      ],
    );
  }
}

class TriangleBoxPainter extends CustomPainter {
  final Color colorLeft;
  final Color colorRight;
  final int animationValue;

  TriangleBoxPainter({
    required this.colorLeft,
    required this.colorRight,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLeft = Paint()
      ..color = colorLeft
      ..style = PaintingStyle.fill;
    final paintRight = Paint()
      ..color = colorRight
      ..style = PaintingStyle.fill;

    // Draw first triangle
    final path1 = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path1, paintLeft);

    // Draw second triangle
    final path2 = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path2, paintRight);

    const strokeWidth = 3.0;
    final rect = Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2,
        size.width - strokeWidth, size.height - strokeWidth);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = Colors.red.withAlpha(animationValue);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(TriangleBoxPainter oldDelegate) => true;
}
