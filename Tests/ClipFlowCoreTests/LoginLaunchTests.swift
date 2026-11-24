import Foundation
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor struct LoginLaunchTests {
    func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "ClipFlow.tests.login.\(UUID())")) }
    @Test func enabledByDefaultAndOptOutSurvivesRelaunch() throws {
        let d = try defaults(); var state = LoginLaunchState.notRegistered, registrations = 0
        let controller = LoginLaunchController(defaults: d, state: { state }, register: { registrations += 1; state = .enabled }, unregister: { state = .notRegistered })
        controller.start(); #expect(controller.desiredEnabled); #expect(state == .enabled); #expect(registrations == 1)
        controller.apply(false); #expect(!controller.desiredEnabled); #expect(state == .notRegistered)
        let reopened = LoginLaunchController(defaults: d, state: { state }, register: { registrations += 1 }, unregister: {})
        reopened.start(); #expect(!reopened.desiredEnabled); #expect(registrations == 1)
    }
    @Test func systemApprovalIsShownAndNotRepeatedlyOverridden() throws {
        let d = try defaults(); var state = LoginLaunchState.notRegistered, registrations = 0
        let controller = LoginLaunchController(defaults: d, state: { state }, register: { registrations += 1; state = .requiresApproval }, unregister: { state = .notRegistered })
        controller.start(); #expect(controller.state == .requiresApproval)
        #expect(controller.statusText.contains("等待系统批准"))
        controller.start(); #expect(registrations == 1)
        controller.apply(false); #expect(state == .notRegistered)
    }
    @Test func registrationFailureNeverReportsEnabled() throws {
        let controller = LoginLaunchController(defaults: try defaults(), state: { .notRegistered }, register: { throw CocoaError(.fileWriteNoPermission) }, unregister: {})
        controller.start(); #expect(controller.state == .notRegistered)
        #expect(!controller.errorMessage.isEmpty); #expect(controller.statusText.contains("未完成"))
    }
    @Test func cancellationFailureRemainsVisibleAsEnabled() throws {
        let d = try defaults(); d.set(false, forKey: "launchAtLogin")
        let controller = LoginLaunchController(defaults: d, state: { .enabled }, register: {}, unregister: { throw CocoaError(.fileWriteNoPermission) })
        controller.start(); #expect(!controller.desiredEnabled); #expect(controller.state == .enabled)
        #expect(!controller.errorMessage.isEmpty)
    }
}
