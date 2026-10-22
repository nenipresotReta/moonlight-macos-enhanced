import Foundation

// Minimal UI/host/session doubles. The production ViewModel is compiled unchanged.
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
  var wrappedValue: Value
  init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
struct Host { let id: String }
enum SettingsModel { static let globalHostId = "global" }
final class TemporaryHost: NSObject {
  let uuid = "paired"
  let activeAddress: String? = "test.invalid"
  let serverCert: Data? = Data([1])
  let addressStates: [String: NSNumber]? = ["test.invalid": 1]
}
final class DataManager { func getHosts() -> Any? { [TemporaryHost()] } }
enum ConnectionEndpointStore { static func allEndpoints(for host: TemporaryHost) -> [String] { [] } }
enum IdManager { static func getUniqueId() -> String { "test" } }
final class HttpManager: @unchecked Sendable {
  static let gate = DispatchSemaphore(value: 0)
  init?(host: String, uniqueId: String, serverCert: Data) {}
  func fetchSunshineUSBForwardingCapability() -> [String: Any]? {
    precondition(Self.gate.wait(timeout: .now() + 3) == .success)
    return ["enabled": true as NSNumber, "available": true as NSNumber,
            "port": 1 as NSNumber, "token": "test"]
  }
}
final class MLRemoteUSBDevice { let busID = "1-1"; let product = "Test device" }
final class MLRemoteUSBForwardingSession {
  static let instance = MLRemoteUSBForwardingSession()
  static func shared() -> MLRemoteUSBForwardingSession { instance }
  var refreshes: [([MLRemoteUSBDevice], Error?) -> Void] = []
  var starts: [(Error?) -> Void] = []
  func refreshDevices(completion: @escaping ([MLRemoteUSBDevice], Error?) -> Void) { refreshes.append(completion) }
  func startForwarding(for device: MLRemoteUSBDevice, host: String, port: UInt16, token: String,
                       serverCert: Data, completion: @escaping (Error?) -> Void) { starts.append(completion) }
  func stop() {}
}
@main struct USBViewModelTests {
  @MainActor static func pump(_ seconds: Double, until condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && deadline.timeIntervalSinceNow > 0 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }
  @MainActor static func main() {
    let model = RemoteUSBForwardingViewModel()
    let session = MLRemoteUSBForwardingSession.shared()
    model.refresh(host: Host(id: "paired"))
    model.stop()
    HttpManager.gate.signal()
    pump(0.1)
    precondition(session.refreshes.isEmpty, "late capability response must not restart enumeration after Stop")

    model.refresh(host: Host(id: "paired"))
    HttpManager.gate.signal()
    pump(1, until: { session.refreshes.count == 1 })
    precondition(session.refreshes.count == 1)
    model.stop()
    session.refreshes[0]([MLRemoteUSBDevice()], nil)
    precondition(model.devices.isEmpty && !model.capabilityAvailable, "cancelled enumeration must not update UI")

    model.refresh(host: Host(id: "paired"))
    HttpManager.gate.signal()
    pump(1, until: { session.refreshes.count == 2 })
    precondition(session.refreshes.count == 2)
    let device = MLRemoteUSBDevice()
    session.refreshes[1]([device], nil)
    precondition(model.capabilityAvailable && model.status == "Ready")
    model.refresh(host: Host(id: "paired"))
    precondition(!model.capabilityAvailable && model.devices.isEmpty,
                 "refresh must disable devices and discard the previous host capability")
    model.start(device: device)
    precondition(session.starts.isEmpty, "Start during refresh must not reuse a stale token/address pair")
    HttpManager.gate.signal()
    pump(1, until: { session.refreshes.count == 3 })
    precondition(session.refreshes.count == 3)
    session.refreshes[2]([device], nil)
    precondition(model.capabilityAvailable && model.status == "Ready")
    model.start(device: device)
    model.stop()
    session.starts[0](nil)
    precondition(model.status == "Ready" && model.selectedBusID == nil, "late READY must not restore Forwarding")

    model.start(device: device)
    model.start(device: device)
    session.starts[1](NSError(domain: "old", code: 1))
    precondition(model.status == "Connecting USB/IP…" && model.selectedBusID != nil)
    session.starts[2](nil)
    precondition(model.status == "Forwarding Test device")
    model.stop()
    print("PASS: production ViewModel rejects capability/enumeration/forwarding callbacks after Stop or replacement")
  }
}
