import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';

// ---------------------------------------------------------------------------
// Model catalog
// ---------------------------------------------------------------------------

class _ModelDef {
  final String id;
  final String label;
  final String assetFolder;
  final String modelFile;
  final List<_Motion> motions;
  final int expressionCount;

  const _ModelDef({
    required this.id,
    required this.label,
    required this.assetFolder,
    required this.modelFile,
    required this.motions,
    required this.expressionCount,
  });
}

class _Motion {
  final String group;
  final int index;
  final String label;
  const _Motion(this.group, this.index, this.label);
}

const List<_ModelDef> _models = [
  _ModelDef(
    id: 'mao',
    label: 'Mao',
    assetFolder: 'assets/models/mao/',
    modelFile: 'mao_pro.model3.json',
    motions: [
      _Motion('Idle', 0, 'Idle'),
      _Motion('', 0, 'Motion 1'),
      _Motion('', 1, 'Motion 2'),
      _Motion('', 2, 'Motion 3'),
      _Motion('', 3, 'Special 1'),
      _Motion('', 4, 'Special 2'),
      _Motion('', 5, 'Special 3'),
    ],
    expressionCount: 8,
  ),
  _ModelDef(
    id: 'icegirl',
    label: 'IceGirl',
    assetFolder: 'assets/models/icegirl/',
    modelFile: 'IceGirl.model3.json',
    motions: [],
    expressionCount: 0,
  ),
  _ModelDef(
    id: 'ren',
    label: 'Ren',
    assetFolder: 'assets/models/ren/',
    modelFile: 'ren.model3.json',
    motions: [
      _Motion('Idle', 0, 'Idle'),
      _Motion('', 0, 'Motion 1'),
      _Motion('', 1, 'Motion 2'),
    ],
    expressionCount: 5,
  ),
];

// ---------------------------------------------------------------------------
// App entry
// ---------------------------------------------------------------------------

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Live2D Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(primary: Color(0xFF7B9FE3)),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0D0D0D)),
      ),
      home: const SafeArea(child: Live2DDemoPage()),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-slot data — controller + view-model selection only.
// All transient state (loading/loaded/error) lives on the controller.
// ---------------------------------------------------------------------------

class _Slot {
  _Slot(this.label) : controller = Live2DViewController();

  final String label;
  final Live2DViewController controller;

  _ModelDef selectedModel = _models.first;
  bool visible = true;
  double motionSpeed = 1.0;
}

// ---------------------------------------------------------------------------
// Demo page — two Live2D views side by side, independent controls
// ---------------------------------------------------------------------------

class Live2DDemoPage extends StatefulWidget {
  const Live2DDemoPage({super.key});

  @override
  State<Live2DDemoPage> createState() => _Live2DDemoPageState();
}

class _Live2DDemoPageState extends State<Live2DDemoPage> {
  late final List<_Slot> _slots = [_Slot('Slot 1'), _Slot('Slot 2')];
  int _activeSlot = 0;

  @override
  void dispose() {
    for (final s in _slots) {
      s.controller.dispose();
    }
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadModel(_Slot slot) async {
    final c = slot.controller;
    if (c.value.isLoadingModel) return;
    try {
      await c.whenAttached;
      await c.loadModel(
        modelDir: slot.selectedModel.assetFolder,
        modelFileName: slot.selectedModel.modelFile,
      );
    } on Live2DException catch (e) {
      _showMessage('${slot.label}: ${e.code}: ${e.message}');
    } catch (e) {
      _showMessage('${slot.label}: $e');
    }
  }

  Future<void> _loadAll() async {
    await Future.wait(_slots.map(_loadModel));
  }

  Future<void> _unload(_Slot slot) async {
    if (!slot.controller.value.isAttached) return;
    try {
      await slot.controller.unloadModel();
    } on Live2DException catch (e) {
      _showMessage('${slot.label}: ${e.code}: ${e.message}');
    }
  }

  void _toggleVisible(_Slot slot) {
    setState(() => slot.visible = !slot.visible);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Live2D'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Load all',
            icon: const Icon(Icons.download_for_offline),
            onPressed: _loadAll,
          ),
        ],
      ),
      body: Column(
        children: [
          // ---------- Top: two Live2D views side by side ----------
          Expanded(
            child: Row(
              children: [
                Expanded(child: _slotView(_slots[0])),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Colors.black,
                ),
                Expanded(child: _slotView(_slots[1])),
              ],
            ),
          ),

          // ---------- Bottom: control panel for the active slot ----------
          Container(
            color: const Color(0xFFF5F5F5),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _slotTabs(),
                const SizedBox(height: 8),
                _slotPanel(_slots[_activeSlot]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Live2D view + on-screen status overlay (driven entirely by controller).
  // -------------------------------------------------------------------------

  Widget _slotView(_Slot slot) {
    final idx = _slots.indexOf(slot);
    return GestureDetector(
      onTap: () => setState(() => _activeSlot = idx),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Flutter background — always visible through the transparent Live2D view.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A237E), Color(0xFF880E4F)],
              ),
            ),
          ),
          if (slot.visible)
            Live2DView(controller: slot.controller)
          else
            const Center(
              child: Text(
                'Hidden',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          Positioned(
            left: 8,
            top: 8,
            child: _badge(
              slot.label,
              color: _activeSlot == _slots.indexOf(slot)
                  ? const Color(0xFF7B9FE3)
                  : Colors.black54,
            ),
          ),
          // The status badge listens directly to the controller. Whenever the
          // controller's state changes, only this widget rebuilds.
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: ValueListenableBuilder<Live2DViewState>(
              valueListenable: slot.controller,
              builder: (_, state, widget) =>
                  _badge(_describe(state, slot), color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  String _describe(Live2DViewState s, _Slot slot) {
    if (!slot.visible) return 'Hidden — toggle to mount.';
    switch (s.lifecycle) {
      case Live2DLifecycle.detached:
        return 'Waiting for GL surface…';
      case Live2DLifecycle.attached:
        if (s.isLoadingModel) return 'Loading ${slot.selectedModel.label}…';
        if (s.lastError != null) {
          return '[${s.lastError!.code}] ${s.lastError!.message}';
        }
        if (s.isLoaded) {
          return '${s.loadedModel!.modelFileName}'
              '${s.isRenderingPaused ? ' (paused)' : ''}';
        }
        return 'GL surface ready.';
    }
  }

  Widget _badge(String text, {required Color color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 11),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
  );

  // -------------------------------------------------------------------------
  // Slot tabs (slot picker)
  // -------------------------------------------------------------------------

  Widget _slotTabs() {
    return Row(
      children: [
        for (int i = 0; i < _slots.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _activeSlot = i),
              child: Container(
                margin: EdgeInsets.only(right: i == _slots.length - 1 ? 0 : 6),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _activeSlot == i
                      ? const Color(0xFF7B9FE3)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFCCCCCC)),
                ),
                child: Text(
                  _slots[i].label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _activeSlot == i ? Colors.white : Colors.black87,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Slot control panel — model picker, load, motions, expressions
  // -------------------------------------------------------------------------

  Widget _slotPanel(_Slot slot) {
    return ValueListenableBuilder<Live2DViewState>(
      valueListenable: slot.controller,
      builder: (_, state, widget) {
        final isAttached = state.isAttached;
        final isLoading = state.isLoadingModel;
        final isLoaded = state.isLoaded;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Visibility toggle + model picker + load + unload
            Row(
              children: [
                IconButton(
                  tooltip: slot.visible ? 'Hide view (dispose)' : 'Show view',
                  onPressed: () => _toggleVisible(slot),
                  icon: Icon(
                    slot.visible ? Icons.visibility_off : Icons.visibility,
                    size: 22,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final m in _models)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(m.label),
                              selected: slot.selectedModel.id == m.id,
                              onSelected: (_) => setState(() {
                                slot.selectedModel = m;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (isAttached && !isLoading)
                      ? () => _loadModel(slot)
                      : null,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(isLoading ? 'Loading…' : 'Load'),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Unload',
                  onPressed: isLoaded ? () => _unload(slot) : null,
                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                ),
              ],
            ),

            // Speed slider — only when a model is loaded
            if (isLoaded) ...[
              const SizedBox(height: 6),
              _sectionLabel('MOTION SPEED'),
              Row(
                children: [
                  const Icon(
                    Icons.slow_motion_video,
                    size: 16,
                    color: Color(0xFF888888),
                  ),
                  Expanded(
                    child: Slider(
                      value: slot.motionSpeed,
                      min: 0.0,
                      max: 3.0,
                      divisions: 30,
                      label: '${slot.motionSpeed.toStringAsFixed(1)}×',
                      onChanged: (v) {
                        setState(() => slot.motionSpeed = v);
                        slot.controller.setMotionSpeed(v);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${slot.motionSpeed.toStringAsFixed(1)}×',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF555555),
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Reset button
                  GestureDetector(
                    onTap: () {
                      setState(() => slot.motionSpeed = 1.0);
                      slot.controller.setMotionSpeed(1.0);
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.refresh,
                        size: 16,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // Motions / expressions — only when a model is loaded
            if (isLoaded) ...[
              if (slot.selectedModel.motions.isNotEmpty) ...[
                const SizedBox(height: 8),
                _sectionLabel('MOTIONS'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final m in slot.selectedModel.motions)
                      _motionBtn(slot, m.label, m.group, m.index),
                  ],
                ),
              ],
              if (slot.selectedModel.expressionCount > 0) ...[
                const SizedBox(height: 6),
                _sectionLabel('EXPRESSIONS'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    for (int i = 0; i < slot.selectedModel.expressionCount; i++)
                      _exprBtn(slot, 'Exp ${i + 1}', i),
                  ],
                ),
              ],
              if (slot.selectedModel.motions.isEmpty &&
                  slot.selectedModel.expressionCount == 0) ...[
                const SizedBox(height: 6),
                const Text(
                  'No motions/expressions for this model.',
                  style: TextStyle(color: Color(0xFF555555), fontSize: 11),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: const TextStyle(
      color: Color(0xFF555555),
      fontSize: 11,
      letterSpacing: 1.2,
    ),
  );

  Widget _motionBtn(_Slot slot, String label, String group, int index) =>
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          side: const BorderSide(color: Color(0xFF333333)),
        ),
        onPressed: () =>
            slot.controller.startMotion(group: group, index: index),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );

  Widget _exprBtn(_Slot slot, String label, int index) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      side: const BorderSide(color: Color(0xFF333366)),
      foregroundColor: const Color(0xFF7B9FE3),
    ),
    onPressed: () => slot.controller.setExpression(index),
    child: Text(label, style: const TextStyle(fontSize: 11)),
  );
}
