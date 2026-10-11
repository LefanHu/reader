import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Native Settings requests share the Flutter route with the library gear.
  private var settingsChannel: FlutterMethodChannel?
  // Window-owned local dictionary service; callbacks never retain the window
  // or its Flutter controller, and presentation never mutates Flutter routes.
  private var dictionaryChannel: FlutterMethodChannel?

  @objc func openSettings(_ sender: Any?) {
    settingsChannel?.invokeMethod("openSettings", arguments: nil)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    settingsChannel = FlutterMethodChannel(
      name: "reader/settings", binaryMessenger: flutterViewController.engine.binaryMessenger)
    dictionaryChannel = FlutterMethodChannel(
      name: "reader/dictionary", binaryMessenger: flutterViewController.engine.binaryMessenger)
    dictionaryChannel?.setMethodCallHandler { [weak self, weak flutterViewController] call, result in
      guard call.method == "lookUp" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = self, let controller = flutterViewController,
        window.contentViewController === controller,
        controller.view.window === window, window.isVisible, NSApp.isActive
      else {
        result(FlutterError(
          code: "dictionary_unavailable", message: "No active Flutter view.", details: nil))
        return
      }
      window.lookUp(call.arguments, in: controller.view, result: result)
    }

    super.awakeFromNib()
  }

  deinit {
    dictionaryChannel?.setMethodCallHandler(nil)
  }

  /// AppKit uses logical points too, but an unflipped view starts at the bottom
  /// left. Resolve the actual Flutter view's bounds/flipping at each invocation;
  /// neither backingScaleFactor nor the window's title-bar height belongs here.
  private func lookUp(_ arguments: Any?, in view: NSView, result: FlutterResult) {
    guard let arguments = arguments as? [String: Any],
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
    let bounds = view.bounds
    let anchor = NSRect(
      x: bounds.minX + x,
      y: view.isFlipped ? bounds.minY + y : bounds.maxY - y - height,
      width: width, height: height
    ).intersection(bounds)
    guard !anchor.isNull, !anchor.isEmpty else {
      result(FlutterError(
        code: "dictionary_invalid_anchor", message: "The word is outside the Flutter view.", details: nil))
      return
    }

    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let word = NSAttributedString(string: text, attributes: [.font: font])
    // The contract supplies a word rectangle rather than a typographic baseline.
    // Place the native overlay's baseline just inside its visual lower-left edge.
    let baseline = NSPoint(
      x: anchor.minX,
      y: view.isFlipped ? anchor.maxY + font.descender : anchor.minY - font.descender)
    // Force an in-place system overlay, regardless of Dictionary.app preferences.
    // AppKit exposes no completion/error callback; success reports this real API
    // invocation, never the presence of a definition or dismissal of its UI.
    view.showDefinition(
      for: word,
      range: NSRange(location: 0, length: word.length),
      options: [.presentationType: NSView.DefinitionPresentationType.overlay],
      baselineOriginProvider: { _ in baseline })
    result(nil)
  }
}
