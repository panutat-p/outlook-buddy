#!/usr/bin/env swift
/**
 Outlook Buddy

 Watches Microsoft Outlook and Microsoft Teams for Microsoft identity sign-in
 pages. It fills email, then password, and stops before MFA or any later prompt.

 Usage:
   ./scripts/microsoft-login-buddy.swift
   ./scripts/microsoft-login-buddy.swift once
   ./scripts/microsoft-login-buddy.swift inspect
   ./scripts/microsoft-login-buddy.swift dump

 Requires Accessibility permission for the launching terminal/binary.
 Credentials are loaded from project-root .env:
   MICROSOFT_EMAIL
   MICROSOFT_PASSWORD
 */

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Configuration

private struct TargetApp: Hashable {
    let name: String
    let bundleID: String
}

private let targetApps = [
    TargetApp(name: "Microsoft Outlook", bundleID: "com.microsoft.Outlook"),
    TargetApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
]

private let idleSafetyPollSeconds: TimeInterval = 60
private let activeBurstSeconds: TimeInterval = 20
private let activePollInterval: TimeInterval = 0.4
private let pageTransitionTimeout: TimeInterval = 30
/// Wait for the user to finish MFA before deciding whether the other Microsoft
/// app still needs its own sign-in.
private let postPasswordObservationSeconds: TimeInterval = 120
/// Outlook and Teams sometimes share the newly refreshed Microsoft session.
private let sharedSSOPropagationSeconds: TimeInterval = 3
private let sequenceCooldownSeconds: TimeInterval = 30
private let maxTreeDepth = 30

// MARK: - Logging

private func log(_ message: String) {
    FileHandle.standardError.write(Data("[outlook-buddy] \(message)\n".utf8))
}

// MARK: - Accessibility

private func requireAccessibility(prompt: Bool) {
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
    ] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        log("Accessibility is not granted. Enable the launching terminal or binary in System Settings → Privacy & Security → Accessibility.")
        exit(1)
    }
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String {
    guard let value = axValue(element, attribute) else { return "" }
    if let string = value as? String { return string }
    if let string = value as? NSString { return string as String }
    return String(describing: value)
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    guard let value = axValue(element, attribute) else { return false }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return false
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let array = axValue(element, kAXChildrenAttribute as String) as? [AnyObject] else {
        return []
    }
    return array.map { unsafeBitCast($0, to: AXUIElement.self) }
}

private func normalized(_ value: String) -> String {
    value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "\n", with: " ")
}

private func elementLabel(_ element: AXUIElement, includeValue: Bool = true) -> String {
    var values = [
        axString(element, kAXTitleAttribute as String),
        axString(element, kAXDescriptionAttribute as String),
        axString(element, kAXHelpAttribute as String),
        axString(element, "AXPlaceholderValue"),
        axString(element, "AXDOMIdentifier"),
    ]
    if includeValue {
        values.append(axString(element, kAXValueAttribute as String))
    }
    return normalized(values.joined(separator: " "))
}

private func walk(
    _ root: AXUIElement,
    depth: Int = 0,
    visit: (AXUIElement, String, Int) -> Bool
) -> AXUIElement? {
    var visited = Set<CFHashCode>()

    func visitElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= maxTreeDepth else { return nil }
        let identity = CFHash(element)
        guard visited.insert(identity).inserted else { return nil }

        let role = axString(element, kAXRoleAttribute as String)
        if visit(element, role, depth) { return element }
        for child in axChildren(element) {
            if let found = visitElement(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    return visitElement(root, depth: depth)
}

private func findElement(
    _ root: AXUIElement,
    where predicate: (AXUIElement, String) -> Bool
) -> AXUIElement? {
    walk(root) { element, role, _ in predicate(element, role) }
}

private func allElements(
    _ root: AXUIElement,
    where predicate: (AXUIElement, String) -> Bool
) -> [AXUIElement] {
    var results: [AXUIElement] = []
    _ = walk(root) { element, role, _ in
        if predicate(element, role) { results.append(element) }
        return false
    }
    return results
}

private func isEditableRole(_ role: String) -> Bool {
    role == "AXTextField" || role == "AXTextArea" || role == "AXSecureTextField"
}

private func isSecureField(_ element: AXUIElement, role: String) -> Bool {
    if role == "AXSecureTextField" { return true }
    let label = elementLabel(element, includeValue: false)
    let domID = normalized(axString(element, "AXDOMIdentifier"))
    return domID == "i0118"
        || label.contains("password")
        || label.contains("passwd")
}

// MARK: - Target app and window discovery

private struct AppContext {
    let target: TargetApp
    let app: NSRunningApplication
    let window: AXUIElement
}

private func runningTargetApps() -> [(TargetApp, NSRunningApplication)] {
    let running = NSWorkspace.shared.runningApplications
    return targetApps.compactMap { target in
        guard let app = running.first(where: {
            $0.bundleIdentifier == target.bundleID || $0.localizedName == target.name
        }) else { return nil }
        return (target, app)
    }
}

private func windows(for app: NSRunningApplication) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var result: [AXUIElement] = []

    if let focused = axValue(appElement, kAXFocusedWindowAttribute as String) {
        result.append(unsafeBitCast(focused, to: AXUIElement.self))
    }
    if let main = axValue(appElement, kAXMainWindowAttribute as String) {
        let window = unsafeBitCast(main, to: AXUIElement.self)
        if !result.contains(where: { CFEqual($0, window) }) { result.append(window) }
    }
    if let list = axValue(appElement, kAXWindowsAttribute as String) as? [AnyObject] {
        for item in list {
            let window = unsafeBitCast(item, to: AXUIElement.self)
            if !result.contains(where: { CFEqual($0, window) }) { result.append(window) }
        }
    }
    return result
}

private func focus(_ context: AppContext) -> Bool {
    context.app.activate()
    AXUIElementSetAttributeValue(
        context.window,
        kAXMainAttribute as CFString,
        kCFBooleanTrue
    )
    AXUIElementPerformAction(context.window, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.35)
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app.processIdentifier
}

// MARK: - Microsoft login page classification

private let nextButtonTerms = ["next", "continue"]
private let signInButtonTerms = ["sign in", "log in", "login"]
private let accountChooserTerms = [
    "use another account",
    "sign in with another account",
    "add another account",
]
private let emailTerms = [
    "email",
    "e-mail",
    "phone",
    "skype",
    "username",
    "user name",
    "work or school account",
]
private let passwordTerms = ["password", "enter password"]
private let microsoftIdentityTerms = [
    "microsoft",
    "sign in",
    "work or school account",
    "pick an account",
]

private func containsAny(_ haystack: String, terms: [String]) -> Bool {
    terms.contains(where: haystack.contains)
}

private func isMicrosoftLoginWindow(_ window: AXUIElement) -> Bool {
    findElement(window) { element, role in
        guard role == "AXWebArea" else { return false }
        return elementLabel(element).contains("sign in to your account")
    } != nil
}

private func button(
    in window: AXUIElement,
    terms: [String],
    requireEnabled: Bool = false
) -> AXUIElement? {
    findElement(window) { element, role in
        guard role == "AXButton" || role == "AXLink" else { return false }
        if requireEnabled && !axBool(element, kAXEnabledAttribute as String) { return false }
        return containsAny(elementLabel(element), terms: terms)
    }
}

private func pageText(in window: AXUIElement) -> String {
    var snippets: [String] = []
    _ = walk(window) { element, role, _ in
        if role == "AXStaticText" || role == "AXHeading"
            || role == "AXButton" || role == "AXLink" {
            let label = elementLabel(element)
            if !label.isEmpty { snippets.append(label) }
        }
        return false
    }
    return snippets.joined(separator: " ")
}

private func hasSignInTimedOutError(in window: AXUIElement) -> Bool {
    let text = pageText(in: window)
    return text.contains("sorry, your sign-in timed out")
        || (text.contains("sign-in timed out") && text.contains("sign in again"))
}

private enum LoginPage {
    case accountChooser(button: AXUIElement)
    case email(field: AXUIElement)
    case password(field: AXUIElement)
}

private func classify(window: AXUIElement) -> LoginPage? {
    guard isMicrosoftLoginWindow(window) else { return nil }

    if let chooser = button(in: window, terms: accountChooserTerms) {
        return .accountChooser(button: chooser)
    }

    let text = pageText(in: window)
    let hasIdentityMarker = containsAny(text, terms: microsoftIdentityTerms)
    let next = button(in: window, terms: nextButtonTerms + signInButtonTerms)
    guard hasIdentityMarker, next != nil else { return nil }

    let fields = allElements(window) { _, role in isEditableRole(role) }
    guard !fields.isEmpty else { return nil }

    if let secure = fields.first(where: {
        isSecureField($0, role: axString($0, kAXRoleAttribute as String))
    }) {
        return .password(field: secure)
    }

    if containsAny(text, terms: passwordTerms),
       let field = fields.first {
        return .password(field: field)
    }

    let explicitlyLabeledEmailField = fields.first(where: { element in
        let domID = normalized(axString(element, "AXDOMIdentifier"))
        return domID == "i0116"
            || containsAny(elementLabel(element, includeValue: false), terms: emailTerms)
    })

    guard containsAny(text, terms: emailTerms)
            || explicitlyLabeledEmailField != nil else {
        return nil
    }
    return .email(field: explicitlyLabeledEmailField ?? fields[0])
}

private func visibleLoginPage(
    excludingPIDs: Set<pid_t> = []
) -> (AppContext, LoginPage)? {
    for (target, app) in runningTargetApps() {
        if excludingPIDs.contains(app.processIdentifier) { continue }
        for window in windows(for: app) {
            if let page = classify(window: window) {
                return (AppContext(target: target, app: app, window: window), page)
            }
        }
    }
    return nil
}

// MARK: - Process-targeted input

private func postKey(
    pid: pid_t,
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    hold: TimeInterval = 0.02
) {
    let source = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
        down.flags = flags
        down.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: hold)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
        up.flags = flags
        up.postToPid(pid)
    }
}

private func typeText(_ text: String, pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for scalar in text.unicodeScalars {
        var characters = [UniChar](String(scalar).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters
        )
        up?.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters
        )
        down?.postToPid(pid)
        up?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.012)
    }
}

private func fill(
    _ value: String,
    field: AXUIElement,
    context: AppContext,
    description: String
) -> Bool {
    guard focus(context) else {
        log("\(context.target.name): could not make target app frontmost; refusing to type")
        return false
    }
    let result = AXUIElementSetAttributeValue(
        field,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard result == .success else {
        log("\(context.target.name): could not focus \(description) field; refusing to type")
        return false
    }
    Thread.sleep(forTimeInterval: 0.25)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == context.app.processIdentifier else {
        log("\(context.target.name): focus changed before typing; aborting")
        return false
    }
    postKey(pid: context.app.processIdentifier, keyCode: 0, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.05)
    typeText(value, pid: context.app.processIdentifier)
    log("\(context.target.name): filled \(description)")
    return true
}

private func pressFreshButton(
    context: AppContext,
    terms: [String],
    description: String
) -> Bool {
    for _ in 0..<10 {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == context.app.processIdentifier else {
            log("\(context.target.name): focus changed before \(description); aborting")
            return false
        }
        if let fresh = button(in: context.window, terms: terms, requireEnabled: true) {
            let result = AXUIElementPerformAction(fresh, kAXPressAction as CFString)
            if result == .success {
                log("\(context.target.name): pressed \(description)")
                return true
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    log("\(context.target.name): \(description) was not available; no coordinate fallback used")
    return false
}

// MARK: - Credentials

private struct Credentials {
    let email: String
    let password: String
}

private func findDotEnvURL() -> URL? {
    let fileManager = FileManager.default
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let scriptDirectory = argv0.deletingLastPathComponent()
    var candidates = [
        cwd.appendingPathComponent(".env"),
        scriptDirectory.appendingPathComponent(".env"),
        scriptDirectory.deletingLastPathComponent().appendingPathComponent(".env"),
    ]
    var directory = cwd
    for _ in 0..<4 {
        candidates.append(directory.appendingPathComponent(".env"))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    var seen = Set<String>()
    return candidates.first { url in
        let path = url.standardizedFileURL.path
        return seen.insert(path).inserted && fileManager.isReadableFile(atPath: path)
    }
}

private func parseDotEnv() -> (values: [String: String], path: String?) {
    guard let url = findDotEnvURL(),
          let raw = try? String(contentsOf: url, encoding: .utf8) else {
        return ([:], nil)
    }
    var values: [String: String] = [:]
    for rawLine in raw.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        values[key] = value
    }
    return (values, url.path)
}

private func credentialValue(_ name: String, env: [String: String]) -> String {
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
        return value
    }
    return env[name] ?? ""
}

private func loadCredentials() -> Credentials {
    let loaded = parseDotEnv()
    if let path = loaded.path { log("loaded credentials from \(path)") }
    return Credentials(
        email: credentialValue("MICROSOFT_EMAIL", env: loaded.values),
        password: credentialValue("MICROSOFT_PASSWORD", env: loaded.values)
    )
}

private func validate(_ credentials: Credentials) -> Bool {
    var valid = true
    if credentials.email.isEmpty || !credentials.email.contains("@") {
        log("MICROSOFT_EMAIL is empty or invalid")
        valid = false
    }
    if credentials.password.isEmpty {
        log("MICROSOFT_PASSWORD is empty")
        valid = false
    }
    return valid
}

// MARK: - Sequence

private enum PageActionResult {
    case noPage
    case advanced
    case passwordSubmitted(context: AppContext, startedWithTimeout: Bool)
    case failed
}

private enum SequenceResult {
    case noPage
    case passwordSubmitted
    case failed
}

private enum PostPasswordOutcome {
    case continued
    case timedOut
    case manualPromptStillOpen
}

private func handleVisiblePage(
    credentials: Credentials,
    excludingPIDs: Set<pid_t>
) -> PageActionResult {
    guard let (context, page) = visibleLoginPage(excludingPIDs: excludingPIDs) else {
        return .noPage
    }
    StatusItem.shared.set(.watching)

    switch page {
    case .accountChooser:
        guard focus(context) else { return .failed }
        guard pressFreshButton(
            context: context,
            terms: accountChooserTerms,
            description: "Use another account"
        ) else { return .failed }
        return .advanced

    case .email(let field):
        guard fill(
            credentials.email,
            field: field,
            context: context,
            description: "email"
        ) else { return .failed }
        guard pressFreshButton(
            context: context,
            terms: nextButtonTerms + signInButtonTerms,
            description: "Next"
        ) else { return .failed }
        return .advanced

    case .password(let field):
        let startedWithTimeout = hasSignInTimedOutError(in: context.window)
        if startedWithTimeout {
            log("\(context.target.name): timed-out sign-in detected; retrying this password page")
        }
        guard fill(
            credentials.password,
            field: field,
            context: context,
            description: "password"
        ) else { return .failed }
        guard pressFreshButton(
            context: context,
            terms: signInButtonTerms + nextButtonTerms,
            description: "Sign in"
        ) else { return .failed }
        log("\(context.target.name): password submitted; observing only for the known timeout error")
        return .passwordSubmitted(
            context: context,
            startedWithTimeout: startedWithTimeout
        )
    }
}

private func matchingLoginWindow(for context: AppContext) -> AXUIElement? {
    windows(for: context.app).first(where: isMicrosoftLoginWindow)
}

private func observePostPassword(
    context: AppContext,
    startedWithTimeout: Bool
) -> PostPasswordOutcome {
    let deadline = Date().addingTimeInterval(postPasswordObservationSeconds)
    var oldTimeoutCleared = !startedWithTimeout
    var loginWindowStillOpen = false

    while Date() < deadline {
        Thread.sleep(forTimeInterval: activePollInterval)
        guard let window = matchingLoginWindow(for: context) else {
            return .continued
        }
        loginWindowStillOpen = true

        if classify(window: window) == nil {
            // MFA or another manual prompt is open. Wait for the user to finish
            // so shared SSO has a chance to close the other app's login window.
            continue
        }

        let timedOut = hasSignInTimedOutError(in: window)
        if !timedOut {
            oldTimeoutCleared = true
        } else if oldTimeoutCleared {
            return .timedOut
        }
    }

    // Never start the other app's sign-in while MFA/consent is still open.
    return loginWindowStillOpen ? .manualPromptStillOpen : .continued
}

private func runOneSequence(credentials: Credentials) -> SequenceResult {
    var sawPage = false
    var submittedPassword = false
    var completedPIDs = Set<pid_t>()
    var timeoutRetriedPIDs = Set<pid_t>()
    var transitionDeadline = Date().addingTimeInterval(pageTransitionTimeout)

    while Date() < transitionDeadline {
        switch handleVisiblePage(
            credentials: credentials,
            excludingPIDs: completedPIDs
        ) {
        case .noPage:
            if submittedPassword {
                return .passwordSubmitted
            }
            if sawPage {
                Thread.sleep(forTimeInterval: activePollInterval)
                continue
            }
            return .noPage
        case .advanced:
            sawPage = true
            transitionDeadline = Date().addingTimeInterval(pageTransitionTimeout)
            Thread.sleep(forTimeInterval: 0.8)
        case .passwordSubmitted(let context, let startedWithTimeout):
            switch observePostPassword(
                context: context,
                startedWithTimeout: startedWithTimeout
            ) {
            case .continued:
                submittedPassword = true
                sawPage = true
                completedPIDs.insert(context.app.processIdentifier)
                log("\(context.target.name): sign-in completed; checking whether the other Microsoft app still needs authentication")
                Thread.sleep(forTimeInterval: sharedSSOPropagationSeconds)
                transitionDeadline = Date().addingTimeInterval(pageTransitionTimeout)
            case .timedOut:
                let pid = context.app.processIdentifier
                guard !timeoutRetriedPIDs.contains(pid) else {
                    log("\(context.target.name): sign-in timed out again; stopping")
                    return .failed
                }
                timeoutRetriedPIDs.insert(pid)
                sawPage = true
                log("\(context.target.name): Microsoft reported a sign-in timeout; retrying once")
                transitionDeadline = Date().addingTimeInterval(pageTransitionTimeout)
                Thread.sleep(forTimeInterval: 0.5)
            case .manualPromptStillOpen:
                log("\(context.target.name): MFA or another manual prompt is still open; deferring the other app")
                return .passwordSubmitted
            }
        case .failed:
            return .failed
        }
    }
    log("Microsoft login page transition timed out; stopping without further input")
    return sawPage ? .failed : .noPage
}

private func watch(credentials: Credentials) -> Never {
    let wake = MicrosoftWakeSource.shared
    log("watching Outlook and Teams sign-in windows — Ctrl+C or Quit to stop")

    while true {
        let result = runOneSequence(credentials: credentials)
        switch result {
        case .passwordSubmitted, .failed:
            StatusItem.shared.set(.idle)
            log("cooling down \(Int(sequenceCooldownSeconds))s")
            Thread.sleep(forTimeInterval: sequenceCooldownSeconds)
            continue
        case .noPage:
            break
        }

        let wakeResult = wake.wait(timeout: idleSafetyPollSeconds) {
            StatusItem.shared.set(.idle)
            log("idle — waiting for Outlook or Teams login UI")
        }
        guard wakeResult.fromEvent else { continue }

        StatusItem.shared.set(.watching)
        let burstDeadline = Date().addingTimeInterval(activeBurstSeconds)
        var terminalResult: SequenceResult?
        while Date() < burstDeadline {
            let burstResult = runOneSequence(credentials: credentials)
            switch burstResult {
            case .passwordSubmitted, .failed:
                terminalResult = burstResult
            case .noPage:
                break
            }
            if terminalResult != nil { break }
            Thread.sleep(forTimeInterval: activePollInterval)
        }
        if terminalResult != nil {
            StatusItem.shared.set(.idle)
            log("cooling down \(Int(sequenceCooldownSeconds))s")
            Thread.sleep(forTimeInterval: sequenceCooldownSeconds)
        }
    }
}

// MARK: - Wake source

private final class MicrosoftWakeSource: NSObject {
    struct WaitResult {
        let fromEvent: Bool
    }

    static let shared = MicrosoftWakeSource()

    private let condition = NSCondition()
    private var signaled = false
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var started = false

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in self?.handleWorkspaceEvent(note) },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in self?.handleWorkspaceEvent(note) },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in self?.handleTermination(note) },
        ]

        attachObservers()
        if !runningTargetApps().isEmpty { poke() }
        log("wake source started for Outlook and Teams")
    }

    func wait(
        timeout: TimeInterval,
        beforeSleep: (() -> Void)? = nil
    ) -> WaitResult {
        condition.lock()
        if signaled {
            signaled = false
            condition.unlock()
            return WaitResult(fromEvent: true)
        }
        condition.unlock()

        beforeSleep?()

        condition.lock()
        defer { condition.unlock() }
        if signaled {
            signaled = false
            return WaitResult(fromEvent: true)
        }
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        let fromEvent = signaled
        signaled = false
        return WaitResult(fromEvent: fromEvent)
    }

    func poke() {
        condition.lock()
        signaled = true
        condition.signal()
        condition.unlock()
    }

    private func targetApp(from note: Notification) -> NSRunningApplication? {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              targetApps.contains(where: {
                  app.bundleIdentifier == $0.bundleID || app.localizedName == $0.name
              }) else {
            return nil
        }
        return app
    }

    private func handleWorkspaceEvent(_ note: Notification) {
        guard targetApp(from: note) != nil else { return }
        attachObservers()
        poke()
    }

    private func handleTermination(_ note: Notification) {
        guard let app = targetApp(from: note) else { return }
        detachObserver(pid: app.processIdentifier)
    }

    private func attachObservers() {
        let running = runningTargetApps()
        let runningPIDs = Set(running.map { $0.1.processIdentifier })
        for pid in observers.keys where !runningPIDs.contains(pid) {
            detachObserver(pid: pid)
        }

        for (target, app) in running {
            let pid = app.processIdentifier
            if observers[pid] != nil { continue }

            var observer: AXObserver?
            guard AXObserverCreate(pid, microsoftAXCallback, &observer) == .success,
                  let observer else {
                log("could not attach Accessibility observer to \(target.name) pid=\(pid)")
                continue
            }
            let appElement = AXUIElementCreateApplication(pid)
            let notifications = [
                kAXWindowCreatedNotification as String,
                kAXFocusedWindowChangedNotification as String,
                kAXMainWindowChangedNotification as String,
                kAXFocusedUIElementChangedNotification as String,
                kAXValueChangedNotification as String,
            ]
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in notifications {
                let error = AXObserverAddNotification(
                    observer,
                    appElement,
                    name as CFString,
                    refcon
                )
                if error != .success && error != .notificationAlreadyRegistered {
                    log("\(target.name): could not observe \(name) (\(error.rawValue))")
                }
            }
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            observers[pid] = observer
            log("Accessibility observer attached to \(target.name) pid=\(pid)")
        }
    }

    private func detachObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }
}

private func microsoftAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<MicrosoftWakeSource>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .poke()
}

// MARK: - Menu bar

private final class StatusItem {
    enum State {
        case idle
        case watching

        var symbol: String {
            switch self {
            case .idle: "moon.zzz.fill"
            case .watching: "bolt.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .idle: .systemIndigo
            case .watching: .systemYellow
            }
        }

        var description: String {
            switch self {
            case .idle: "Outlook Buddy idle"
            case .watching: "Outlook Buddy handling Microsoft sign-in"
            }
        }
    }

    static let shared = StatusItem()
    private var item: NSStatusItem?
    private var state: State = .idle

    func attach(_ item: NSStatusItem) {
        self.item = item
        apply(state)
    }

    func set(_ newState: State) {
        let update = { [weak self] in
            guard let self else { return }
            self.state = newState
            self.apply(newState)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.sync(execute: update)
        }
    }

    private func apply(_ state: State) {
        guard let button = item?.button,
              let image = NSImage(
                  systemSymbolName: state.symbol,
                  accessibilityDescription: state.description
              ) else { return }
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [state.color])
        button.image = image
            .withSymbolConfiguration(size)?
            .withSymbolConfiguration(palette)
        button.image?.isTemplate = false
        button.toolTip = state.description
    }
}

private func runWithMenuBar(_ work: @escaping () -> Int32) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    StatusItem.shared.attach(item)

    let menu = NSMenu()
    let quit = NSMenuItem(
        title: "Quit Outlook Buddy",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quit.target = app
    menu.addItem(quit)
    item.menu = menu

    MicrosoftWakeSource.shared.start()
    DispatchQueue.global(qos: .utility).async {
        let code = work()
        DispatchQueue.main.async { exit(code) }
    }
    app.run()
    exit(0)
}

// MARK: - Redacted diagnostic dump

private func redacted(_ text: String) -> String {
    let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
    guard let regex = try? NSRegularExpression(
        pattern: emailPattern,
        options: [.caseInsensitive]
    ) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
        in: text,
        options: [],
        range: range,
        withTemplate: "<redacted-email>"
    )
}

private func dumpElement(
    _ element: AXUIElement,
    depth: Int = 0,
    visited: inout Set<CFHashCode>
) {
    guard depth <= maxTreeDepth else { return }
    let identity = CFHash(element)
    guard visited.insert(identity).inserted else { return }

    let role = axString(element, kAXRoleAttribute as String)
    let indentation = String(repeating: "  ", count: depth)
    let isEditable = isEditableRole(role)
    let label = elementLabel(element, includeValue: !isEditable)
    let display = isEditable
        ? "\(elementLabel(element, includeValue: false)) value=<redacted>"
        : label
    if !role.isEmpty || !display.isEmpty {
        print("\(indentation)\(role.isEmpty ? "(no role)" : role) \(redacted(display))")
    }
    for child in axChildren(element) {
        dumpElement(child, depth: depth + 1, visited: &visited)
    }
}

private func dumpTargets() {
    let running = runningTargetApps()
    if running.isEmpty {
        print("Outlook and Teams are not running.")
        return
    }
    for (target, app) in running {
        let appWindows = windows(for: app).filter(isMicrosoftLoginWindow)
        print("=== \(target.name) bundle=\(target.bundleID) pid=\(app.processIdentifier) windows=\(appWindows.count) ===")
        if appWindows.isEmpty {
            print("(no dedicated Microsoft login window detected)")
        }
        for (index, window) in appWindows.enumerated() {
            let title = axString(window, kAXTitleAttribute as String)
            print("--- window \(index + 1): \(title.isEmpty ? "(untitled)" : title) ---")
            var visited = Set<CFHashCode>()
            dumpElement(window, visited: &visited)
        }
    }
}

private func inspectTargets() {
    var found = false
    for (target, app) in runningTargetApps() {
        for window in windows(for: app) {
            guard let page = classify(window: window) else { continue }
            found = true
            let pageName: String
            switch page {
            case .accountChooser: pageName = "account chooser"
            case .email: pageName = "email"
            case .password: pageName = "password"
            }
            print("\(target.name): \(pageName) page")
        }
    }
    if !found { print("No dedicated Microsoft login page detected.") }
}

// MARK: - Main

private func main() {
    let command = CommandLine.arguments.dropFirst().first ?? "watch"

    if command == "dump" || command == "inspect" {
        requireAccessibility(prompt: false)
        if command == "dump" {
            dumpTargets()
        } else {
            inspectTargets()
        }
        return
    }

    guard command == "watch" || command == "once" else {
        log("usage: \(CommandLine.arguments[0]) [watch|once|inspect|dump]")
        exit(2)
    }

    requireAccessibility(prompt: true)
    let credentials = loadCredentials()
    guard validate(credentials) else { exit(1) }

    if command == "once" {
        let result = runOneSequence(credentials: credentials)
        switch result {
        case .passwordSubmitted:
            exit(0)
        case .noPage:
            log("no Microsoft login page detected")
            exit(3)
        case .failed:
            exit(4)
        }
    }

    runWithMenuBar {
        watch(credentials: credentials)
    }
}

main()
