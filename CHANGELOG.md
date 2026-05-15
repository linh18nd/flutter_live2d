# Changelog

## 1.0.2 - 2026-05-15

### Changed
- Remove `path_provider` dependency; temp directory is now resolved via a native platform channel call.

## 1.0.1 - 2026-05-15

### Fixed
- Use clean BSD-3-Clause LICENSE file for OSI license detection on pub.dev.
- Move Cubism SDK third-party notices to a separate NOTICES file.

## 1.0.0 - 2026-05-15

### Added
- Initial release.
- Render Live2D Cubism models on Android and iOS via OpenGL ES 2.
- `Live2DView` Flutter widget with `Live2DViewController` for full lifecycle control.
- Load models from Flutter assets or the device filesystem.
- Start motions by group/index with priority, set expressions, and set parameter values.
- Motion playback speed control (`setMotionSpeed`).
- Transparent background by default — stack any Flutter widget behind or in front of the model.
- Support for multiple simultaneous Live2D views.
- Physics simulation with per-instance frame timing for smooth multi-view rendering.
