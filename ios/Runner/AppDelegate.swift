import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReaderDictionary") {
      ReaderDictionaryPlugin.register(with: registrar)
    }
  }
}

/// Engine-owned local dictionary boundary; the current Flutter view is resolved
/// per request, because the implicit engine can outlive its attached controller.
private final class ReaderDictionaryPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private let channel: FlutterMethodChannel
  // Weak ownership survives user dismissal without retaining a UIKit controller.
  // Cleanup requests during presentation/dismissal join the same transition.
  private weak var dictionaryController: UIReferenceLibraryViewController?
  private var isPresentingDictionary = false
  private var isDismissingDictionary = false
  private var pendingDismissResults: [FlutterResult] = []

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    channel = FlutterMethodChannel(
      name: "reader/dictionary", binaryMessenger: registrar.messenger())
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = ReaderDictionaryPlugin(registrar: registrar)
    registrar.publish(plugin)
    plugin.channel.setMethodCallHandler { [weak plugin] call, result in
      guard let plugin = plugin else {
        result(FlutterError(
          code: "dictionary_unavailable", message: "The Flutter engine detached.", details: nil))
        return
      }
      switch call.method {
      case "lookUp":
        plugin.lookUp(call, result: result)
      case "dismiss":
        plugin.pendingDismissResults.append(result)
        plugin.dismissOwnedDictionary()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    channel.setMethodCallHandler(nil)
    self.registrar = nil
    completeDictionaryDismissal(error: FlutterError(
      code: "dictionary_unavailable", message: "The Flutter engine detached.", details: nil))
  }

  /// Logical Flutter coordinates are already UIKit points. Do not apply device
  /// pixel ratio or safe-area offsets: the source view is the Flutter view itself.
  private func lookUp(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !isPresentingDictionary, !isDismissingDictionary else {
      result(FlutterError(
        code: "dictionary_presentation_busy",
        message: "The system dictionary is changing presentation state.", details: nil))
      return
    }
    guard let arguments = call.arguments as? [String: Any],
      let text = arguments["text"] as? String, !text.isEmpty,
      let x = arguments["x"] as? Double, x.isFinite,
      let y = arguments["y"] as? Double, y.isFinite,
      let width = arguments["width"] as? Double, width.isFinite, width > 0,
      let height = arguments["height"] as? Double, height.isFinite, height > 0
    else {
      result(FlutterError(
        code: "dictionary_invalid_arguments",
        message: "Look Up requires text and a finite visible word rectangle.", details: nil))
      return
    }
    guard let controller = registrar?.viewController,
      let view = controller.viewIfLoaded,
      let window = view.window,
      window.windowScene?.activationState == .foregroundActive
    else {
      result(FlutterError(
        code: "dictionary_unavailable", message: "No active Flutter view.", details: nil))
      return
    }
    guard controller.presentedViewController == nil,
      !controller.isBeingPresented, !controller.isBeingDismissed
    else {
      result(FlutterError(
        code: "dictionary_presentation_busy",
        message: "The Flutter view is already presenting a native controller.", details: nil))
      return
    }
    let anchor = CGRect(x: x, y: y, width: width, height: height).intersection(view.bounds)
    guard !anchor.isNull, !anchor.isEmpty else {
      result(FlutterError(
        code: "dictionary_invalid_anchor", message: "The word is outside the Flutter view.", details: nil))
      return
    }

    let dictionary = UIReferenceLibraryViewController(term: text)
    dictionary.modalPresentationStyle = .popover
    if let popover = dictionary.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = anchor
      popover.permittedArrowDirections = [.up, .down]
    }
    dictionaryController = dictionary
    isPresentingDictionary = true
    controller.present(dictionary, animated: true) { [weak self, weak dictionary] in
      self?.isPresentingDictionary = false
      if dictionary?.presentingViewController != nil {
        result(nil)
      } else {
        result(FlutterError(
          code: "dictionary_presentation_failed",
          message: "The system dictionary was not presented.", details: nil))
      }
      // UIKit cannot reliably dismiss a controller while it is being presented.
      // Drain selection-owner cleanup only after the presentation transition.
      self?.dismissOwnedDictionary()
    }
  }

  /// Never dismiss via the Flutter root blindly: another feature may now own its
  /// native presentation. Only the exact dictionary we presented is eligible.
  private func dismissOwnedDictionary() {
    guard !pendingDismissResults.isEmpty,
      !isPresentingDictionary, !isDismissingDictionary else { return }
    guard let dictionary = dictionaryController,
      let presenter = dictionary.presentingViewController
    else {
      dictionaryController = nil
      completeDictionaryDismissal(error: nil)
      return
    }
    guard presenter.presentedViewController === dictionary else {
      completeDictionaryDismissal(error: FlutterError(
        code: "dictionary_dismissal_failed",
        message: "The dictionary no longer owns this native presentation.", details: nil))
      return
    }
    // A user-initiated interactive dismissal may still be finishing (or cancel).
    // Join it rather than issuing a second UIKit dismissal during the transition.
    if dictionary.isBeingDismissed, let transition = dictionary.transitionCoordinator {
      isDismissingDictionary = true
      let joined = transition.animate(alongsideTransition: nil) { [weak self] _ in
        self?.isDismissingDictionary = false
        self?.dismissOwnedDictionary()
      }
      if joined { return }
      isDismissingDictionary = false
    }
    isDismissingDictionary = true
    presenter.dismiss(animated: false) { [weak self, weak dictionary] in
      guard let self = self else { return }
      self.isDismissingDictionary = false
      guard dictionary?.presentingViewController == nil else {
        self.completeDictionaryDismissal(error: FlutterError(
          code: "dictionary_dismissal_failed",
          message: "The system dictionary was not dismissed.", details: nil))
        return
      }
      self.dictionaryController = nil
      self.completeDictionaryDismissal(error: nil)
    }
  }

  /// Drain before callbacks so any reentrant request owns a fresh result queue.
  private func completeDictionaryDismissal(error: FlutterError?) {
    let results = pendingDismissResults
    pendingDismissResults.removeAll()
    for result in results {
      result(error)
    }
  }
}
