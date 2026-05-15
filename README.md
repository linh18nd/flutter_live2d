# flutter_live2d

A Flutter plugin to render Live2D Cubism models on Android and iOS using
the Cubism Native SDK and OpenGL ES 2.

> **Status:** pre-1.0. The Dart API may still change between minor versions.
> See [CHANGELOG](CHANGELOG.md) for breaking changes.

## Features

- Embed any Live2D Cubism `.model3.json` directly inside a Flutter widget tree.
- Reactive controller built on `ValueNotifier<Live2DViewState>` — drives UI
  via `ValueListenableBuilder` with no boilerplate.
- Async-first lifecycle (`whenAttached`, `Future`-returning commands) — no
  callback soup.
- Multiple views side-by-side (Android shares one render thread + EGL
  context; iOS gives each view its own context).
- Built-in touch tracking (eyes / head follow finger via the Cubism
  drag input).
- Load models from `assets/` (extracted to cache on first use) or from any
  absolute filesystem path (e.g. downloaded models).
- Pause / resume the render loop to save battery when the view is
  offscreen.

## Platforms

| Platform | Minimum |
| --- | --- |
| Android | API 24 (Android 7.0) |
| iOS | 13.0 |

Bundled Cubism Core supports `.moc3` file versions **3.0 through 5.3**.

## Installation

```yaml
dependencies:
  flutter_live2d: <latest_version>
```

### Bundling models as assets

Place a model folder under `assets/` and declare it in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/models/your_model/
```

The folder must contain a `*.model3.json` plus every file it references —
`.moc3`, textures, motions, expressions, physics, pose. Asset directories
are extracted lazily into the app's cache the first time you `loadModel`
them, then reused on subsequent loads.

### Loading from the filesystem

Already have a model on disk (e.g. downloaded into the documents
directory)? Pass an absolute path:

```dart
final dir = await getApplicationDocumentsDirectory();
await controller.loadModel(
  modelDir: '${dir.path}/downloaded/ren/',
  modelFileName: 'ren.model3.json',
);
```

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
  final _controller = Live2DViewController();

  @override
  void initState() {
    super.initState();
    _autoLoad();
  }

  Future<void> _autoLoad() async {
    // The native GL surface is created asynchronously after the widget
    // mounts. `whenAttached` resolves once it's ready.
    await _controller.whenAttached;
    await _controller.loadModel(
      modelDir: 'assets/models/your_model/',
      modelFileName: 'your_model.model3.json',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Live2DView(controller: _controller),
    );
  }
}
```

### Reactive UI overlays

The controller is a `ValueListenable<Live2DViewState>`, so you can drive
status indicators, error banners or buttons off of it without manual
`setState` calls:

```dart
ValueListenableBuilder<Live2DViewState>(
  valueListenable: controller,
  builder: (_, state, _) {
    if (state.isLoadingModel) return const CircularProgressIndicator();
    if (state.lastError != null) return Text('error: ${state.lastError!.code}');
    if (state.isLoaded) return Text('loaded: ${state.loadedModel!.modelFileName}');
    return const SizedBox.shrink();
  },
)
```

### Triggering motions and expressions

```dart
await controller.startMotion(group: 'Idle');           // group from model
await controller.startMotion(group: '', index: 2);     // unnamed group
await controller.setExpression(0);                     // by index
await controller.setParameter('ParamAngleX', 30.0);    // raw parameter
```

### Multiple views

Place several `Live2DView`s on the same page; each gets its own controller
and runs independently. On Android they share a single render thread and
EGL context (so frame time scales linearly with view count); on iOS each
view has its own GL context.

```dart
Row(
  children: [
    Expanded(child: Live2DView(controller: c1)),
    Expanded(child: Live2DView(controller: c2)),
  ],
)
```

See [`example/`](example/) for a runnable demo with three sample models
and two side-by-side views.

## API reference

### `Live2DView`

Widget hosting the native GL surface.

| Property | Type | Description |
| --- | --- | --- |
| `controller` | `Live2DViewController?` | Controller bound to this view. |

### `Live2DViewController`

Extends `ValueNotifier<Live2DViewState>`. Listen to lifecycle and command
state via `addListener` / `ValueListenableBuilder`, or pull a snapshot
from `controller.value`.

| Method / property | Description |
| --- | --- |
| `whenAttached` | `Future<void>` that completes when the view enters `Live2DLifecycle.attached`. |
| `loadModel({modelDir, modelFileName})` | Load a model. `modelDir` accepts an asset path or absolute path. Returns `bool`. |
| `unloadModel()` | Free the loaded model and its native resources. |
| `setRenderingPaused(bool)` | Pause / resume the GL render loop. |
| `startMotion({group, index, priority})` | Play a motion. `priority`: 0=none, 1=idle, 2=normal, 3=force. |
| `setExpression(index)` | Switch expression by index. |
| `setParameter(id, value)` | Set a model parameter (e.g. `ParamAngleX`). |
| `dispose()` | Free the controller's listeners. **Always call this** in your widget's `dispose`. |

### `Live2DViewState`

Immutable snapshot exposed as `controller.value`.

| Field | Type | Description |
| --- | --- | --- |
| `lifecycle` | `Live2DLifecycle` | `detached` (no view) or `attached` (live). |
| `isLoadingModel` | `bool` | True while a `loadModel` call is in flight. |
| `loadedModel` | `Live2DLoadedModel?` | Currently loaded model, or null. |
| `isRenderingPaused` | `bool` | Current render-loop paused flag. |
| `lastError` | `Live2DException?` | Last error, cleared on the next success. |
| `isAttached` | `bool` | `lifecycle == Live2DLifecycle.attached`. |
| `isLoaded` | `bool` | `loadedModel != null`. |

### `Live2DException`

Thrown by all controller methods on native errors.

| `code` | Meaning |
| --- | --- |
| `VIEW_NOT_ATTACHED` | Called before the view attached. Await `whenAttached`. |
| `VIEW_NOT_FOUND` | Native view already disposed. |
| `INVALID_ARGS` | Missing or invalid argument. |
| `LOAD_FAILED` | Native side rejected the model. |
| `CONTROLLER_DISPOSED` | Method called on a disposed controller. |
| `NATIVE_ERROR` | Generic native failure with a more specific `message`. |

## How it works

- **Asset extraction.** When you pass an asset directory to `loadModel`,
  the plugin copies every file under it into the app's temporary
  directory on first use and tells the native side to load from there.
  A `.ready` marker file lets subsequent app launches skip the copy if
  the cache already exists.
- **Touch tracking.** Touches inside `Live2DView` are forwarded to the
  Cubism `SetDragging` API automatically, so the model's eyes and head
  follow the user's finger without extra wiring.
- **Render thread (Android).** All views share a single
  `Live2D-RenderHub` thread running on one EGL context. Disposal is
  serialized through this thread so widget removal can never race
  in-flight rendering.
- **Render thread (iOS).** Each view drives its own `CADisplayLink` on
  the main runloop with its own GL context.
- **Cubism framework refcount.** The Cubism framework is initialized once
  on first model load and torn down after the last view goes away,
  reference-counted on both platforms.

## Lifecycle & background behavior

- The render loop keeps running while the app is foregrounded, even when
  the view is offscreen (e.g. behind a route). Call
  `controller.setRenderingPaused(true)` to suspend it manually when you
  know the view won't be visible.
- When a `Live2DView` is removed from the widget tree, the native view is
  destroyed and the controller transitions to `Live2DLifecycle.detached`.
  Re-adding the widget with the same controller re-attaches and
  `whenAttached` resolves again.

## Troubleshooting

- **`Live2DException(VIEW_NOT_ATTACHED)`** — you called a command before
  the native view finished initializing. Wrap your first call with
  `await controller.whenAttached;`.
- **`Live2DException(LOAD_FAILED)`** — the native side parsed the
  `.model3.json` but couldn't load it. Common causes: wrong `modelDir`,
  missing texture / motion / physics file referenced by the json, or a
  `.moc3` newer than the bundled Cubism Core. Check `lastError.message`.
- **`Live2DException(INVALID_ARGS)`: "No assets found under ..."** —
  the asset directory wasn't declared under `flutter.assets` in
  `pubspec.yaml`, or the path is misspelled.
- **Hot reload doesn't show native changes.** Hot reload only patches
  Dart. Edits in Kotlin / Swift / C++ require `flutter run` or a hot
  restart that triggers a rebuild.
- **`group: ''`** is valid in `startMotion` and refers to the default /
  unnamed group in the model's `.model3.json`.

## Example

See [`example/`](example/) for a full demo featuring:

- Three bundled sample models (Ren, Mao, IceGirl).
- Two side-by-side `Live2DView`s, each with its own controller.
- Independent load / unload, motion and expression triggers per slot.
- A toggle to mount / unmount a view at runtime — exercise the disposal
  path.

## License

The plugin source is under the project license (BSD 3-Clause; see
[LICENSE](LICENSE)). The bundled Cubism Native SDK and Cubism Core
belong to Live2D Inc. and are subject to Live2D's [Free Material
License](https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html)
or [Proprietary Software License](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html);
review their terms before shipping.
