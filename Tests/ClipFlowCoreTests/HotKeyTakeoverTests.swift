import Foundation
import Testing
import Carbon
@testable import ClipFlowCore

@MainActor struct HotKeyTakeoverTests {
    func registrations(_ scheme: HotKeyScheme, status: Int32 = 0) -> [HotKeyRegistration] {
        HotKeyService.keyCodes.enumerated().map { .init(slot:$0.offset+1,label:"\(scheme.name)+\(HotKeyService.labels[$0.offset])",keyCode:$0.element,status:status) }
    }
    @Test func defaultIsCommandAndSettingsSurviveRelaunch() throws {
        let suite = "ClipFlow.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        #expect(HotKeySettings.load(from:defaults).scheme == .command)
        var value = HotKeySettings(); value.scheme = .option; value.enabled = false
        value.excludedBundleIDs = ["com.microsoft.edgemac"]
        value.save(to:defaults)
        #expect(HotKeySettings.load(from:defaults) == value)
        #expect(HotKeyScheme.command.carbonModifiers == UInt32(cmdKey))
        #expect(HotKeyScheme.option.carbonModifiers == UInt32(optionKey))
    }
    @Test func releaseAndExclusionUnregisterActualBindingsAndEligibleSwitchDoesNotRebind() {
        var calls: [HotKeyScheme] = [], releases = 0
        let model = HotKeyTakeover(settings:.init(),register:{ scheme in calls.append(scheme); return registrations(scheme) },release:{ releases += 1 })
        model.activate("test.editor")
        #expect(calls == [.command]); #expect(model.registrations.count == 12)
        let oldRevision = model.revision
        model.activate("test.browser")
        #expect(calls.count == 1); #expect(model.revision > oldRevision)
        var settings = model.settings; settings.excludedBundleIDs = ["test.browser"]
        model.update(settings)
        #expect(releases == 1); #expect(model.registrations.isEmpty); #expect(!model.shouldCapture)
        model.activate("test.editor")
        #expect(calls == [.command,.command])
        settings.enabled = false; model.update(settings)
        #expect(releases == 2); #expect(!model.shouldCapture)
        model.activate("test.other"); #expect(calls.count == 2)
        settings.enabled = true; settings.scheme = .option; model.update(settings)
        #expect(calls.last == .option)
        model.activate(nil); #expect(!model.shouldCapture); #expect(model.registrations.isEmpty)
    }
    @Test func conflictIsObservableAndRetryDoesNotSilentlySwitchScheme() {
        var count = 0
        let model = HotKeyTakeover(settings:.init(),register:{ scheme in count += 1; return registrations(scheme,status: count == 1 ? -9878 : 0) },release:{})
        model.activate("test.editor")
        #expect(model.status.contains("Command+1")); #expect(model.status.contains("-9878"))
        #expect(model.settings.scheme == .command)
        model.retry(); #expect(model.registrations.allSatisfy { $0.registered })
        model.stop(); #expect(model.registrations.isEmpty)
    }
    @Test func exclusionsAreNormalizedAndIndependentFromHistoryCollection() {
        #expect(HotKeySettings.parseExclusions(" com.microsoft.edgemac\ncom.apple.finder,com.microsoft.edgemac;invalid/id ") == Set(["com.microsoft.edgemac","com.apple.finder"]))
        #expect(HotKeyService.keyCodes.count == 12)
        #expect(HotKeyService.labels.joined() == "1234567890-=")
    }
}

@MainActor struct HotKeyPermissionTests {
    @Test func unavailableInputPermissionDoesNotStealKeysAndRecoveryRestoresConfiguredScheme() {
        var registers = 0, releases = 0
        let model = HotKeyTakeover(settings:.init(),register:{ _ in registers += 1; return [] },release:{ releases += 1 })
        model.setInputReady(false); model.activate("test.browser")
        #expect(registers == 0); #expect(!model.shouldCapture)
        #expect(model.status.contains("权限"))
        model.setInputReady(true); #expect(registers == 1)
        model.setInputReady(false); #expect(releases == 1)
        #expect(model.settings.enabled)
    }
}
