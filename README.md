# flutter_live2d

A Flutter plugin to render Live2D Cubism models on Android and iOS using
the Cubism Native SDK and OpenGL ES 2.

![Demo](https://raw.githubusercontent.com/linh18nd/flutter_live2d/main/assets/demo/demo.gif)

## Features

- Embed any Live2D Cubism `.model3.json` directly inside a Flutter widget tree.
- **Transparent background by default** — use a plain `Stack` to place Flutter
  widgets behind or in front of the model; no extra configuration needed.
- Reactive controller (`ValueNotifier<Live2DViewState>`) — drive UI off state
  changes with `ValueListenableBuilder`, no manual `setState`.
- Async-first lifecycle: `whenAttached` + `Future`-returning commands.
- Multiple views side-by-side, each with its own independent controller.
- Built-in touch tracking — model eyes/head follow the user's finger.
- Load from `assets/` or any absolute filesystem path.
- Motion playback speed control at runtime.
- Pause / resume the render loop to save battery.

## Platforms

| Platform | Minimum |
| --- | --- |
| Android | API 24 (Android 7.0) |
| iOS | 13.0 |

Bundled Cubism Core supports `.moc3` versions **3.0 – 5.3**.

## Installation

```yaml
dependencies:
  flutter_live2d: ^1.0.0
```

Declare your model folder in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/models/your_model/
```

The folder must contain a `*.model3.json` and every file it references —
`.moc3`, textures, motions, expressions, physics, pose. Files are extracted
to cache on first use and reused on subsequent launches.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  final _ctrl = Live2DViewController();

  @override
  void initState() {
    super.initState();
    // Wait for the native GL surface, then load.
    _ctrl.whenAttached.then((_) => _ctrl.loadModel(
      modelDir: 'assets/models/your_model/',
      modelFileName: 'your_model.model3.json',
    ));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ① Flutter background — full control over color, image, gradient…
          Container(color: Colors.white),
          // ② Live2D renders transparently on top.
          Live2DView(controller: _ctrl),
          // ③ Any Flutter widget above the model.
          const Positioned(
            bottom: 24, left: 0, right: 0,
            child: Text('Hello Live2D', textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
```

## Usage examples

### Load from the filesystem

```dart
final dir = await getApplicationDocumentsDirectory();
await controller.loadModel(
  modelDir: '${dir.path}/downloaded/ren/',
  modelFileName: 'ren.model3.json',
);
```

### Motions, expressions and parameters

```dart
await controller.startMotion(group: 'Idle');          // named group
await controller.startMotion(group: '', index: 2);    // unnamed group
await controller.setExpression(0);
await controller.setParameter('ParamAngleX', 30.0);
```

### Motion playback speed

```dart
controller.setMotionSpeed(2.0);  // 2× speed
controller.setMotionSpeed(0.5);  // half speed
controller.setMotionSpeed(0.0);  // freeze motion (physics keeps running)
controller.setMotionSpeed(1.0);  // normal
```

### Reactive state overlay

```dart
ValueListenableBuilder<Live2DViewState>(
  valueListenable: controller,
  builder: (_, state, __) {
    if (state.isLoadingModel) return const CircularProgressIndicator();
    if (state.lastError != null) return Text(state.lastError!.code);
    if (state.isLoaded) return Text(state.loadedModel!.modelFileName);
    return const SizedBox.shrink();
  },
)
```

### Multiple views

```dart
Row(children: [
  Expanded(child: Live2DView(controller: c1)),
  Expanded(child: Live2DView(controller: c2)),
])
```

See [`example/`](example/) for a full demo: three models, two side-by-side
views, motion speed slider, and a Flutter gradient background.

## API reference

### `Live2DView`

| Property | Type | Description |
| --- | --- | --- |
| `controller` | `Live2DViewController?` | Controller bound to this view. |

### `Live2DViewController`

Extends `ValueNotifier<Live2DViewState>`.

| Method / property | Description |
| --- | --- |
| `whenAttached` | `Future<void>` — resolves when the native view is ready. |
| `loadModel({modelDir, modelFileName})` | Load a model; returns `bool`. |
| `unloadModel()` | Unload and free native resources. |
| `setRenderingPaused(bool)` | Pause / resume the GL render loop. |
| `startMotion({group, index, priority})` | Play a motion. Priority: 0 none · 1 idle · 2 normal · 3 force. |
| `setExpression(index)` | Switch expression by index. |
| `setParameter(id, value)` | Set a Cubism model parameter (e.g. `ParamAngleX`). |
| `setMotionSpeed(speed)` | Speed multiplier for motions. `1.0` = normal, `0.0` = paused. Physics unaffected. |
| `dispose()` | Release listeners. **Always call in `dispose()`**. |

### `Live2DViewState`

| Field | Type | Description |
| --- | --- | --- |
| `lifecycle` | `Live2DLifecycle` | `detached` or `attached`. |
| `isAttached` | `bool` | `lifecycle == attached`. |
| `isLoadingModel` | `bool` | `loadModel` in flight. |
| `isLoaded` | `bool` | `loadedModel != null`. |
| `loadedModel` | `Live2DLoadedModel?` | Currently loaded model. |
| `isRenderingPaused` | `bool` | Render loop paused. |
| `lastError` | `Live2DException?` | Last error; cleared on next success. |

### `Live2DException` error codes

| Code | Meaning |
| --- | --- |
| `VIEW_NOT_ATTACHED` | Command called before `whenAttached`. |
| `VIEW_NOT_FOUND` | Native view already disposed. |
| `INVALID_ARGS` | Missing or invalid argument. |
| `LOAD_FAILED` | Native side rejected the model. |
| `CONTROLLER_DISPOSED` | Controller already disposed. |
| `NATIVE_ERROR` | Generic native failure — check `message`. |

## How it works

- **Asset extraction.** Asset directories are copied to the app's temp folder on first load; a `.ready` marker skips the copy on subsequent launches.
- **Transparent rendering.** GL always clears to `(0,0,0,0)`. iOS uses `CAEAGLLayer.isOpaque = false`; Android uses `TextureView.isOpaque = false` + `EGL_ALPHA_SIZE = 8`.
- **Render thread — Android.** All views share one `Live2D-RenderHub` thread and one EGL context; disposal is serialized through the same thread.
- **Render thread — iOS.** All views share one serial dispatch queue and one `EAGLContext`. A `CADisplayLink` drives each view; frame pumps are dispatched to the queue, keeping GL calls fully serialized.
- **Framework refcount.** Cubism is initialized on first load and torn down after the last view is disposed.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `VIEW_NOT_ATTACHED` | Await `controller.whenAttached` before the first command. |
| `LOAD_FAILED` | Check `lastError.message` — wrong path, missing file, or `.moc3` too new for the bundled Core. |
| `INVALID_ARGS: No assets found` | Declare the folder under `flutter.assets` in `pubspec.yaml`. |
| Hot reload ignores native changes | Native code (Kotlin/Swift/C++) requires a full rebuild, not hot reload. |

## License

Plugin source code: **BSD 3-Clause** — see [LICENSE](LICENSE).

The bundled Live2D Cubism Native SDK and Cubism Core are © Live2D Inc.
and are governed by their own license terms — see [NOTICES](NOTICES).
Review Live2D's terms before shipping a product.
