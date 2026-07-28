import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnalyticsEnvironment: Equatable {
    let appVersion: String
    let build: String
    let osVersion: String
    let architecture: String

    static var current: AnalyticsEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        return AnalyticsEnvironment(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: AnalyticsEnvironment.nativeArchitecture
        )
    }

    private static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

enum AnalyticsEventName: String, CaseIterable, Equatable {
    case appInstalled = "app_installed"
    case appLaunched = "app_launched"
    case onboardingStarted = "onboarding_started"
    case translateCompleted = "translate_completed"
    case rewriteCompleted = "rewrite_completed"
    case smartReplyCompleted = "smart_reply_completed"
    case askScreenCompleted = "ask_screen_completed"
    case onboardingCompleted = "onboarding_completed"
    case permissionsPrompted = "permissions_prompted"
    case permissionGranted = "permission_granted"
    case permissionsCompleted = "permissions_completed"
    case firstUsefulActionCompleted = "first_useful_action_completed"
    case modelChanged = "model_changed"
    case toolGenerated = "tool_generated"
    case errorOccurred = "error_occurred"
}

struct AnalyticsEventPayload: Codable, Equatable {
    let event: String
    let distinctID: String
    let timestamp: String
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
        case event
        case distinctID = "distinct_id"
        case timestamp
        case properties
    }
}

struct PostHogBatchRequest: Codable, Equatable {
    let apiKey: String
    let batch: [AnalyticsEventPayload]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case batch
    }
}

enum PrivacySafeAnalytics {
    private static let anonymousDeviceIDKey = "analytics.anonymousDeviceID.v1"
    private static let allowedPropertyKeys: Set<String> = [
        "app_version",
        "build",
        "os",
        "architecture",
        "distinct_id",
        "mode",
        "target_language",
        "model_id",
        "model_scope",
        "provider",
        "permission",
        "accessibility_status",
        "screen_recording_status",
        "source_event",
        "source",
        "skipped",
        "error_type",
        "error_context"
    ]

    static func anonymousDeviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: anonymousDeviceIDKey),
           UUID(uuidString: existing) != nil {
            return existing
        }

        let newID = UUID().uuidString
        defaults.set(newID, forKey: anonymousDeviceIDKey)
        return newID
    }

    static func makePayload(
        event: AnalyticsEventName,
        distinctID: String,
        date: Date = Date(),
        properties: [String: String] = [:],
        environment: AnalyticsEnvironment = .current
    ) -> AnalyticsEventPayload {
        var safeProperties = sanitize(properties)
        safeProperties["distinct_id"] = distinctID
        safeProperties["app_version"] = environment.appVersion
        safeProperties["build"] = environment.build
        safeProperties["os"] = environment.osVersion
        safeProperties["architecture"] = environment.architecture

        return AnalyticsEventPayload(
            event: event.rawValue,
            distinctID: distinctID,
            timestamp: ISO8601DateFormatter().string(from: date),
            properties: safeProperties
        )
    }

    private static func sanitize(_ properties: [String: String]) -> [String: String] {
        properties.reduce(into: [:]) { result, pair in
            guard allowedPropertyKeys.contains(pair.key) else { return }
            let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result[pair.key] = String(trimmed.prefix(96))
        }
    }
}

@MainActor
final class AnalyticsClient {
    private static let endpointDefaultsKey = "analytics.posthog.endpoint"
    private static let apiKeyDefaultsKey = "analytics.posthog.apiKey"
    private static let appInstalledTrackedKey = "analytics.appInstalledTracked.v1"
    private static let firstUsefulActionTrackedKey = "analytics.firstUsefulActionTracked.v1"
    private static let onboardingStartedTrackedKey = "analytics.onboardingStartedTracked.v1"
    private static let permissionsPromptedTrackedKey = "analytics.permissionsPromptedTracked.v1"
    private static let onboardingCompletedTrackedKey = "analytics.onboardingCompletedTracked.v1"
    private static let permissionsCompletedTrackedKey = "analytics.permissionsCompletedTracked.v1"

    private static func permissionGrantedTrackedKey(_ permission: String) -> String {
        "analytics.permissionGrantedTracked.\(permission).v1"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let environment: AnalyticsEnvironment
    private let endpoint: URL?
    private let apiKey: String?
    private let distinctID: String

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        environment: AnalyticsEnvironment = .current
    ) {
        self.defaults = defaults
        self.session = session
        self.environment = environment
        self.endpoint = Self.configuredEndpoint(defaults: defaults)
        self.apiKey = Self.configuredAPIKey(defaults: defaults)
        self.distinctID = PrivacySafeAnalytics.anonymousDeviceID(defaults: defaults)
    }

    func trackInstallIfNeeded() {
        trackOnce(.appInstalled, flagKey: Self.appInstalledTrackedKey)
    }

    func trackFirstUsefulActionIfNeeded(sourceEvent: AnalyticsEventName, properties: [String: String] = [:]) {
        var enrichedProperties = properties
        enrichedProperties["source_event"] = sourceEvent.rawValue
        trackOnce(.firstUsefulActionCompleted, flagKey: Self.firstUsefulActionTrackedKey, properties: enrichedProperties)
    }

    func trackOnboardingStartedIfNeeded(properties: [String: String] = [:]) {
        trackOnce(.onboardingStarted, flagKey: Self.onboardingStartedTrackedKey, properties: properties)
    }

    func trackPermissionsPromptedIfNeeded(properties: [String: String] = [:]) {
        trackOnce(.permissionsPrompted, flagKey: Self.permissionsPromptedTrackedKey, properties: properties)
    }

    func trackOnboardingCompletedIfNeeded(skipped: Bool) {
        trackOnce(
            .onboardingCompleted,
            flagKey: Self.onboardingCompletedTrackedKey,
            properties: ["skipped": skipped ? "true" : "false"]
        )
    }

    func trackPermissionGrantedIfNeeded(permission: String, properties: [String: String] = [:]) {
        trackOnce(.permissionGranted, flagKey: Self.permissionGrantedTrackedKey(permission), properties: properties)
    }

    func trackPermissionsCompletedIfNeeded(properties: [String: String] = [:]) {
        trackOnce(.permissionsCompleted, flagKey: Self.permissionsCompletedTrackedKey, properties: properties)
    }

    /// One event per install: the flag is only consumed when the client is
    /// actually configured, so an unconfigured build doesn't burn the
    /// one-shot without ever delivering it.
    private func trackOnce(_ event: AnalyticsEventName, flagKey: String, properties: [String: String] = [:]) {
        guard isConfigured, !defaults.bool(forKey: flagKey) else { return }
        defaults.set(true, forKey: flagKey)
        track(event, properties: properties)
    }

    private var isConfigured: Bool {
        endpoint != nil && !(apiKey ?? "").isEmpty
    }

    func track(_ event: AnalyticsEventName, properties: [String: String] = [:]) {
        guard let endpoint, let apiKey, !apiKey.isEmpty else {
            return
        }

        let payload = PrivacySafeAnalytics.makePayload(
            event: event,
            distinctID: distinctID,
            properties: properties,
            environment: environment
        )
        let batch = PostHogBatchRequest(apiKey: apiKey, batch: [payload])

        Task.detached { [session] in
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(batch)
                _ = try await session.data(for: request)
            } catch {
                // Analytics must never affect product UX. Drop failed events.
            }
        }
    }

    private static func configuredEndpoint(defaults: UserDefaults) -> URL? {
        if let raw = defaults.string(forKey: endpointDefaultsKey), let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "NugumiPostHogEndpoint") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://app.posthog.com/batch/")
    }

    private static func configuredAPIKey(defaults: UserDefaults) -> String? {
        if let raw = defaults.string(forKey: apiKeyDefaultsKey), !raw.isEmpty {
            return raw
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "NugumiPostHogAPIKey") as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }
}

extension AnalyticsClient {
    func trackCompletedUsage(kind: UsageStatsEventKind, targetLanguageID: String, modelID: String) {
        let event: AnalyticsEventName
        switch kind {
        case .selection, .screenArea:
            event = .translateCompleted
        case .draftMessage:
            event = .rewriteCompleted
        case .smartReply:
            event = .smartReplyCompleted
        case .replacement:
            return
        }

        let properties = [
            "mode": kind.rawValue,
            "target_language": targetLanguageID,
            "model_id": modelID
        ]
        track(event, properties: properties)
        trackFirstUsefulActionIfNeeded(sourceEvent: event, properties: properties)
    }
}
