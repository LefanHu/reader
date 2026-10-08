import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Native Settings requests share the Flutter route with the library gear.
  private var settingsChannel: FlutterMethodChannel?

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

    super.awakeFromNib()
  }
}
