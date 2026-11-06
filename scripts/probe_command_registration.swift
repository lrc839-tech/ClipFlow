import AppKit
import Carbon

@main struct CommandRegistrationProbe {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let service = HotKeyService()
        let model = HotKeyTakeover(settings:.init(),register:{ service.register(scheme:$0) },release:{ service.unregister() })
        func probe() -> Int32 {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(18,UInt32(cmdKey),EventHotKeyID(signature:0x434C5052,id:101),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&ref)
            if let ref { UnregisterEventHotKey(ref) }
            return status
        }
        model.activate("local.clipflow.registration-fixture")
        let registered = model.registrations.map { ["slot": $0.slot,"status": $0.status] }
        let held = probe()
        var settings = model.settings; settings.enabled = false; model.update(settings)
        let released = probe()
        settings.enabled = true; model.update(settings)
        settings.excludedBundleIDs = ["local.clipflow.registration-fixture"]; model.update(settings)
        let excluded = probe()
        model.stop()
        let data = try JSONSerialization.data(withJSONObject:["measurement":"isolated Carbon registration; no input events posted or front-app priority verified", "registrations":registered,"heldCommand1Probe":held,"afterReleaseCommand1Probe":released,"afterExclusionCommand1Probe":excluded],options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
