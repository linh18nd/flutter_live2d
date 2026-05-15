/// Flutter plugin that renders Live2D Cubism models on Android and iOS using
/// the Cubism Native SDK and OpenGL ES 2.
///
/// Public API surface:
///
///  * [Live2DView] — widget that hosts the native GL surface.
///  * [Live2DViewController] — owns one view's runtime state. Acts as a
///    `ValueListenable<Live2DViewState>`; subscribe with
///    [ValueListenableBuilder] or `addListener`.
///  * [Live2DViewState] — immutable snapshot of one view's state, surfaced
///    through [Live2DViewController.value].
///  * [Live2DLifecycle], [Live2DLoadedModel], [Live2DException] — supporting
///    types referenced by [Live2DViewState].
///  * [Live2D] — static helpers not tied to a specific view.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'flutter_live2d_platform_interface.dart';

export 'flutter_live2d_platform_interface.dart';

// Source files are split under `lib/src/` and joined into this single
// library via `part` directives so private members (e.g. lifecycle hooks
// `_attach` / `_detach` on the controller) can be shared with the widget
// without leaking into the public API.
part 'src/exception.dart';
part 'src/view_state.dart';
part 'src/asset_cache.dart';
part 'src/view_controller.dart';
part 'src/view.dart';
