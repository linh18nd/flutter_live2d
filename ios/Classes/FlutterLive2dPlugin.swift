import Flutter
import UIKit

public class FlutterLive2dPlugin: NSObject, FlutterPlugin {

    private var viewRegistry: [Int64: Live2DFlutterView] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterLive2dPlugin()

        let channel = FlutterMethodChannel(
            name: "flutter_live2d",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)

        let factory = Live2DViewFactory(
            messenger: registrar.messenger(),
            onCreated: { [weak instance] viewId, view in
                instance?.viewRegistry[viewId] = view
            },
            onDisposed: { [weak instance] viewId, disposedId in
                // Defer so we never mutate `viewRegistry` synchronously from
                // `Live2DFlutterView.deinit` while `onCreated` is still inside
                // `viewRegistry[viewId] = ...` (Swift exclusivity fatal).
                DispatchQueue.main.async {
                    guard let inst = instance else { return }
                    if let current = inst.viewRegistry[viewId],
                       ObjectIdentifier(current) == disposedId {
                        inst.viewRegistry.removeValue(forKey: viewId)
                    }
                }
            })
        registrar.register(factory, withId: "live2d_view")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "getTempDirectory":
            result(NSTemporaryDirectory())

        case "loadModel":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            guard let modelDir = requireNonEmptyString(args, "modelDir", result) else { return }
            guard let fileName = requireNonEmptyString(args, "modelFileName", result) else { return }
            guard let view = view(for: viewId, result: result) else { return }
            view.loadModelAsync(modelDir: modelDir, fileName: fileName) { ok in
                result(ok)
            }

        case "unloadModel":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            guard let view = view(for: viewId, result: result) else { return }
            view.unloadModel()
            result(nil)

        case "setRenderingPaused":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            guard let paused = args?["paused"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'paused'", details: nil)); return
            }
            guard let view = view(for: viewId, result: result) else { return }
            view.setRenderingPaused(paused)
            result(nil)

        case "startMotion":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            guard let group = requireString(args, "group", result) else { return }
            let index    = (args?["index"]    as? NSNumber)?.int32Value ?? 0
            let priority = (args?["priority"] as? NSNumber)?.int32Value ?? 2
            guard let view = view(for: viewId, result: result) else { return }
            view.startMotion(group: group, index: index, priority: priority)
            result(nil)

        case "setExpression":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            let index = (args?["index"] as? NSNumber)?.int32Value ?? 0
            guard let view = view(for: viewId, result: result) else { return }
            view.setExpression(index: index)
            result(nil)

        case "setParameter":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            guard let pid = requireNonEmptyString(args, "parameterId", result) else { return }
            let value = (args?["value"] as? NSNumber)?.floatValue ?? 0
            guard let view = view(for: viewId, result: result) else { return }
            view.setParameter(parameterId: pid, value: value)
            result(nil)

        case "setMotionSpeed":
            guard let viewId = requireInt64(args, "viewId", result) else { return }
            let speed = (args?["speed"] as? NSNumber)?.floatValue ?? 1.0
            guard let view = view(for: viewId, result: result) else { return }
            view.setMotionSpeed(speed)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Helpers

    private func view(for viewId: Int64, result: @escaping FlutterResult) -> Live2DFlutterView? {
        if let v = viewRegistry[viewId] { return v }
        result(FlutterError(code: "VIEW_NOT_FOUND",
                            message: "No Live2D view registered for id \(viewId)",
                            details: nil))
        return nil
    }

    private func requireInt64(_ args: [String: Any]?,
                              _ name: String,
                              _ result: @escaping FlutterResult) -> Int64? {
        if let n = args?[name] as? NSNumber { return n.int64Value }
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing or invalid '\(name)'",
                            details: nil))
        return nil
    }

    private func requireString(_ args: [String: Any]?,
                               _ name: String,
                               _ result: @escaping FlutterResult) -> String? {
        if let s = args?[name] as? String { return s }
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing '\(name)'",
                            details: nil))
        return nil
    }

    private func requireNonEmptyString(_ args: [String: Any]?,
                                       _ name: String,
                                       _ result: @escaping FlutterResult) -> String? {
        if let s = args?[name] as? String, !s.isEmpty { return s }
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing or empty '\(name)'",
                            details: nil))
        return nil
    }
}
