part of '../flutter_live2d.dart';

/// Controls a single [Live2DView]: loads / unloads models, plays motions and
/// expressions, mutates parameters, and tracks the live state of the view.
///
/// Pass the same instance to a [Live2DView] widget. Wait for the view to
/// attach via [whenAttached], then issue commands:
///
/// ```dart
/// final controller = Live2DViewController();
/// await controller.whenAttached;
/// await controller.loadModel(
///   modelDir: 'assets/models/ren/',
///   modelFileName: 'ren.model3.json',
/// );
/// await controller.startMotion(group: 'Idle');
/// ```
///
/// The controller is itself a `ValueListenable<Live2DViewState>` — pass it
/// to a [ValueListenableBuilder] to drive UI off of its state.
///
/// Always call [dispose] when the controller is no longer needed (typically
/// in your widget's `dispose`). After disposal, every method throws a
/// [Live2DException] with code `CONTROLLER_DISPOSED`.
class Live2DViewController extends ValueNotifier<Live2DViewState> {
  /// Creates a controller in [Live2DLifecycle.detached] state.
  Live2DViewController() : super(const Live2DViewState());

  /// Native view id assigned by the platform after the [Live2DView] mounts.
  /// `null` when [Live2DLifecycle.detached].
  int? _viewId;

  /// `true` after [dispose] has been called. Subsequent calls fail fast.
  bool _isDisposed = false;

  /// Pending awaiters for the next [Live2DLifecycle.attached] transition.
  /// Recreated on demand so callers waiting after a detach can subscribe to
  /// the next attach.
  Completer<void>? _attachedCompleter;

  /// Future that completes the next time the view enters
  /// [Live2DLifecycle.attached].
  ///
  /// * If the view is already attached, returns a completed future.
  /// * If the controller is disposed, returns a future that errors with
  ///   [Live2DException] code `CONTROLLER_DISPOSED`.
  /// * Otherwise resolves once the [Live2DView] mounts and reports its
  ///   native id.
  ///
  /// Safe to await multiple times; each call either completes immediately
  /// (when already attached) or shares the same pending completer.
  Future<void> get whenAttached {
    if (_isDisposed) {
      return Future.error(
        Live2DException(
          'CONTROLLER_DISPOSED',
          'Controller has been disposed.',
        ),
      );
    }
    if (value.isAttached) return Future.value();
    return (_attachedCompleter ??= Completer<void>()).future;
  }

  // -------------------------------------------------------------------------
  // Internal lifecycle hooks (called from Live2DView's State).
  // -------------------------------------------------------------------------

  /// Called by [Live2DView] once the native view is created. Transitions
  /// the lifecycle to [Live2DLifecycle.attached] and unblocks any pending
  /// [whenAttached] awaiters.
  void _attach(int viewId) {
    if (_isDisposed) return;
    if (_viewId == viewId && value.isAttached) return;
    _viewId = viewId;
    value = value.copyWith(
      lifecycle: Live2DLifecycle.attached,
      lastError: null,
    );
    final completer = _attachedCompleter;
    _attachedCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Called by [Live2DView] when its widget is removed from the tree.
  /// Resets transient state and transitions back to
  /// [Live2DLifecycle.detached]. [Live2DViewState.lastError] is preserved
  /// so the UI can still surface the last failure.
  void _detach() {
    if (_viewId == null) return;
    _viewId = null;
    value = value.copyWith(
      lifecycle: Live2DLifecycle.detached,
      isLoadingModel: false,
      loadedModel: null,
      isRenderingPaused: false,
    );
  }

  /// Returns the native view id or throws the appropriate
  /// [Live2DException] when the controller is detached / disposed. Used to
  /// guard every command method.
  int get _id {
    if (_isDisposed) {
      throw Live2DException(
        'CONTROLLER_DISPOSED',
        'Controller has been disposed.',
      );
    }
    final id = _viewId;
    if (id == null) {
      throw Live2DException(
        'VIEW_NOT_ATTACHED',
        'Live2DViewController is not attached to a Live2DView yet. '
            'Await `controller.whenAttached` or wait for the view to mount.',
      );
    }
    return id;
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  /// Loads a Live2D model into the view.
  ///
  /// [modelDir] accepts either:
  ///   * an absolute filesystem directory (e.g. one returned from
  ///     `getApplicationDocumentsDirectory()`), or
  ///   * an asset directory declared in `pubspec.yaml` (e.g.
  ///     `assets/models/ren/`).
  ///
  /// Asset directories are extracted lazily into the app's cache on first
  /// load and reused on subsequent calls within the same app launch. The
  /// resolved on-disk path becomes [Live2DLoadedModel.modelDir].
  ///
  /// [modelFileName] is the `.model3.json` file name inside [modelDir].
  ///
  /// Returns `true` when the model is loaded successfully; `false` when
  /// the native side rejected the model (in which case
  /// [Live2DViewState.lastError] is populated with code `LOAD_FAILED`).
  ///
  /// Throws [Live2DException] when the call cannot be dispatched at all
  /// (controller disposed, view not attached, missing assets, …).
  Future<bool> loadModel({
    required String modelDir,
    required String modelFileName,
  }) async {
    value = value.copyWith(isLoadingModel: true, lastError: null);
    try {
      final resolvedDir = await _resolveModelDir(modelDir);
      final ok = await _wrap(
        () => FlutterLive2dPlatform.instance.loadModel(
          viewId: _id,
          modelDir: resolvedDir,
          modelFileName: modelFileName,
        ),
      );
      value = value.copyWith(
        isLoadingModel: false,
        loadedModel: ok
            ? Live2DLoadedModel(
                modelDir: resolvedDir,
                modelFileName: modelFileName,
              )
            : null,
        lastError: ok
            ? null
            : Live2DException(
                'LOAD_FAILED',
                'Native loadModel returned false for $modelFileName.',
              ),
      );
      return ok;
    } catch (_) {
      value = value.copyWith(isLoadingModel: false);
      rethrow;
    }
  }

  /// Unloads the currently loaded model and frees its native resources
  /// (textures, motion data, expression data).
  ///
  /// Safe to call when no model is loaded — it is a no-op on the native
  /// side. After completion [Live2DViewState.loadedModel] is `null`.
  Future<void> unloadModel() async {
    await _wrap(
      () => FlutterLive2dPlatform.instance.unloadModel(viewId: _id),
    );
    value = value.copyWith(loadedModel: null, lastError: null);
  }

  /// Pauses or resumes the GL render loop for this view.
  ///
  /// Useful to save battery when the view is offscreen but you don't want
  /// to tear it down entirely. The native model state is preserved while
  /// paused.
  Future<void> setRenderingPaused(bool paused) async {
    await _wrap(
      () => FlutterLive2dPlatform.instance.setRenderingPaused(
        viewId: _id,
        paused: paused,
      ),
    );
    if (value.isRenderingPaused != paused) {
      value = value.copyWith(isRenderingPaused: paused);
    }
  }

  /// Starts a motion.
  ///
  /// [group] is the motion group name from the model definition. Pass an
  /// empty string for the default / unnamed group.
  ///
  /// [index] picks a specific motion within that group.
  ///
  /// [priority] follows Live2D Cubism conventions:
  /// `0=none`, `1=idle`, `2=normal`, `3=force`. Higher priority preempts
  /// lower priority motions; `force` always plays.
  Future<void> startMotion({
    required String group,
    int index = 0,
    int priority = 2,
  }) =>
      _wrap(
        () => FlutterLive2dPlatform.instance.startMotion(
          viewId: _id,
          group: group,
          index: index,
          priority: priority,
        ),
      );

  /// Switches the active expression by [index] (0-based, into the model's
  /// expression list).
  Future<void> setExpression(int index) => _wrap(
        () => FlutterLive2dPlatform.instance.setExpression(
          viewId: _id,
          index: index,
        ),
      );

  /// Sets a single model parameter to [value].
  ///
  /// [parameterId] follows Cubism convention, e.g. `"ParamAngleX"`,
  /// `"ParamMouthOpenY"`. The valid range is defined by the model.
  Future<void> setParameter(String parameterId, double value) => _wrap(
        () => FlutterLive2dPlatform.instance.setParameter(
          viewId: _id,
          parameterId: parameterId,
          value: value,
        ),
      );

  /// Sets the motion playback speed multiplier.
  ///
  /// `1.0` = normal speed (default), `2.0` = double speed, `0.5` = half
  /// speed. `0.0` effectively freezes the motion (physics and eye-blink
  /// keep running at normal rate).
  ///
  /// The speed is applied to the current and all future motions until
  /// changed again.
  Future<void> setMotionSpeed(double speed) => _wrap(
        () => FlutterLive2dPlatform.instance.setMotionSpeed(
          viewId: _id,
          speed: speed,
        ),
      );

  // -------------------------------------------------------------------------
  // Disposal
  // -------------------------------------------------------------------------

  /// Disposes the controller's listeners and rejects any in-flight
  /// [whenAttached] awaiters with code `CONTROLLER_DISPOSED`.
  ///
  /// Always call this when the controller is no longer needed. After
  /// disposal every command method throws [Live2DException] with code
  /// `CONTROLLER_DISPOSED`.
  ///
  /// This does **not** tear down the native view: the [Live2DView] widget
  /// is responsible for that, and it does so when removed from the widget
  /// tree.
  @override
  void dispose() {
    _isDisposed = true;
    final completer = _attachedCompleter;
    _attachedCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        Live2DException(
          'CONTROLLER_DISPOSED',
          'Controller was disposed before attaching.',
        ),
      );
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Wraps a platform-channel call so every error path is normalized into a
  /// [Live2DException] and recorded in [Live2DViewState.lastError]. On
  /// success, clears [Live2DViewState.lastError] from the previous failed
  /// call.
  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      final result = await body();
      if (value.lastError != null) {
        value = value.copyWith(lastError: null);
      }
      return result;
    } on Live2DException catch (e) {
      value = value.copyWith(lastError: e);
      rethrow;
    } on PlatformException catch (e) {
      final mapped = Live2DException(
        e.code,
        e.message ?? 'Native error',
        details: e.details,
      );
      value = value.copyWith(lastError: mapped);
      throw mapped;
    } catch (e) {
      final mapped = Live2DException('UNKNOWN', e.toString());
      value = value.copyWith(lastError: mapped);
      throw mapped;
    }
  }
}
