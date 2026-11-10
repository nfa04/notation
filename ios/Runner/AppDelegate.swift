import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // whether the network is paid by the amount (a mobile network, a phone's hotspot) or the person asked for low data use
  private let paths = NWPathMonitor()
  private var metered: Bool?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // reminders (flutter_local_notifications): lets a notification show while the app is open
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }
    answerDeviceBudget()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // the battery and the network, for a live session (lib/collab/device_budget.dart): a device that is low or metered does not take over
  // hosting
  private func answerDeviceBudget() {
    paths.pathUpdateHandler = { [weak self] path in
      let value = path.isExpensive || path.isConstrained
      DispatchQueue.main.async { self?.metered = value }
    }
    paths.start(queue: DispatchQueue.global(qos: .utility))
    guard let registrar = self.registrar(forPlugin: "NotationDevice") else { return }
    let channel = FlutterMethodChannel(name: "notation/device", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "budget" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      device.isBatteryMonitoringEnabled = true
      var answer: [String: Any] = [:]
      if device.batteryLevel >= 0 { answer["percent"] = Int((device.batteryLevel * 100).rounded()) }
      switch device.batteryState {
      case .charging, .full: answer["charging"] = true
      case .unplugged: answer["charging"] = false
      default: break
      }
      if let metered = self?.metered { answer["metered"] = metered }
      result(answer)
    }
  }
}
