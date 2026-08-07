import AppKit
import CoreServices
import XCTest
@testable import AudioFinder

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultsAreSafeAndUsefulForFirstLaunch() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .notRegistered)

        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        XCTAssertTrue(store.showRecentlyActive)
        XCTAssertEqual(store.recentlyActiveDuration, 30)
        XCTAssertTrue(store.hideSystemApps)
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .notRegistered)
    }

    func testEnablingLaunchAtLoginRegistersTheMainApp() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .notRegistered)
        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        store.launchAtLogin = true

        XCTAssertEqual(loginItems.registerCallCount, 1)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .enabled)
        XCTAssertNil(store.launchAtLoginError)
    }

    func testApprovalRequiredRemainsVisiblyEnabled() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .requiresApproval)

        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .requiresApproval)
        store.openLoginItemSettings()
        XCTAssertEqual(loginItems.openSettingsCallCount, 1)
    }

    func testDisablingLaunchAtLoginUnregistersTheMainApp() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .enabled)
        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        store.launchAtLogin = false

        XCTAssertEqual(loginItems.unregisterCallCount, 1)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .notRegistered)
        XCTAssertNil(store.launchAtLoginError)
    }

    func testApprovalRequestUsesTheActionableStateInsteadOfAGenericError() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .notRegistered)
        loginItems.registerError = FakeLoginItemError.registrationFailed
        loginItems.statusAfterRegisterFailure = .requiresApproval
        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        store.launchAtLogin = true

        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .requiresApproval)
        XCTAssertNil(store.launchAtLoginError)
    }

    func testRegistrationFailureIsReportedAndRealStateWins() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let loginItems = FakeLoginItemManager(status: .notRegistered)
        loginItems.registerError = FakeLoginItemError.registrationFailed
        let store = SettingsStore(defaults: defaults, loginItemManager: loginItems)

        store.launchAtLogin = true

        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(store.loginItemStatus, .notRegistered)
        XCTAssertEqual(store.launchAtLoginError, "The login item could not be registered.")

        loginItems.registerError = nil
        loginItems.status = .enabled
        store.refreshLaunchAtLogin()
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertNil(store.launchAtLoginError)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let domain = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }
}

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testStartAppliesSettingsAndStartsServicesOnlyOnce() {
        let domain = "AppCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "showRecentlyActive")
        defaults.set(60, forKey: "recentlyActiveDuration")
        defaults.set(false, forKey: "hideSystemApps")
        let store = SettingsStore(
            defaults: defaults,
            loginItemManager: FakeLoginItemManager(status: .notRegistered)
        )
        let monitor = FakeAudioMonitor()
        let browserTabs = FakeBrowserTabMonitor()
        let coordinator = AppCoordinator()

        coordinator.start(settings: store, monitor: monitor, browserTabs: browserTabs)
        coordinator.start(settings: store, monitor: monitor, browserTabs: browserTabs)

        XCTAssertTrue(coordinator.hasStarted)
        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(browserTabs.startCallCount, 1)
        XCTAssertEqual(monitor.lastWindow, 60)
        XCTAssertFalse(monitor.lastHideSystem)
        XCTAssertFalse(monitor.lastShowRecent)
    }

    func testBecomingActiveRefreshesBothSources() {
        let domain = "AppCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsStore(
            defaults: defaults,
            loginItemManager: FakeLoginItemManager(status: .notRegistered)
        )
        let monitor = FakeAudioMonitor()
        let browserTabs = FakeBrowserTabMonitor()

        AppCoordinator().applicationBecameActive(
            settings: store,
            monitor: monitor,
            browserTabs: browserTabs
        )

        XCTAssertEqual(monitor.refreshCallCount, 1)
        XCTAssertEqual(browserTabs.refreshCallCount, 1)
    }
}

@MainActor
final class AppDelegateTests: XCTestCase {
    func testRecognizesTheLoginItemLaunchMarker() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertTrue(AppDelegate.isLoginItemLaunch(event))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil))
    }

    func testIgnoresTheMarkerOnAnUnrelatedAppleEvent() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertFalse(AppDelegate.isLoginItemLaunch(event))
    }

    func testRecognizesTheLegacyPropertyDataLoginMarker() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
            forKeyword: AEKeyword(keyAEPropData)
        )

        XCTAssertTrue(AppDelegate.isLoginItemLaunch(event))
    }

    func testReopenRequestsThePrimaryWindow() {
        let notification = expectation(description: "Primary window requested")
        let token = NotificationCenter.default.addObserver(
            forName: .audioFinderShowPrimaryWindow,
            object: nil,
            queue: .main
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(
            AppDelegate().applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: false
            )
        )
        wait(for: [notification], timeout: 0.1)
    }
}

@MainActor
final class AudioMonitorIntegrationTests: XCTestCase {
    func testSandboxedMonitorConnectsToCoreAudio() throws {
        guard OSSupport.isSupported else {
            throw XCTSkip("This macOS version is below the supported floor.")
        }
        let monitor = AudioMonitor()

        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(monitor.state, .ok)
        XCTAssertNil(monitor.lastError)
    }
}

final class BrowserExtensionTrustTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BrowserExtensionTrust.reset()
    }

    override func tearDown() {
        BrowserExtensionTrust.reset()
        super.tearDown()
    }

    func testProductionWebStoreOriginIsTrustedAndRemembered() {
        let origin = BrowserExtensionTrust.productionExtensionOrigin

        XCTAssertEqual(BrowserExtensionTrust.trustableOrigin(from: origin), origin)
        XCTAssertEqual(BrowserExtensionTrust.trustedOrigins, [origin])
    }

    func testMalformedExtensionOriginsAreRejected() {
        XCTAssertNil(BrowserExtensionTrust.trustableOrigin(from: nil))
        XCTAssertNil(BrowserExtensionTrust.trustableOrigin(from: "https://example.com"))
        XCTAssertNil(BrowserExtensionTrust.trustableOrigin(from: "chrome-extension://too-short"))
    }
}

@MainActor
private final class FakeLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus
    var registerError: Error?
    var statusAfterRegisterFailure: LoginItemStatus?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            if let statusAfterRegisterFailure {
                status = statusAfterRegisterFailure
            }
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}

private enum FakeLoginItemError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "The login item could not be registered."
    }
}

@MainActor
private final class FakeAudioMonitor: AudioMonitoring {
    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var lastWindow: TimeInterval?
    private(set) var lastHideSystem = true
    private(set) var lastShowRecent = true

    func apply(window: TimeInterval, hideSystem: Bool, showRecent: Bool) {
        lastWindow = window
        lastHideSystem = hideSystem
        lastShowRecent = showRecent
    }

    func start() {
        startCallCount += 1
    }

    func refreshNow() {
        refreshCallCount += 1
    }
}

@MainActor
private final class FakeBrowserTabMonitor: BrowserTabMonitoring {
    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0

    func start() {
        startCallCount += 1
    }

    func refreshNow() {
        refreshCallCount += 1
    }
}
