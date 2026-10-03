import Foundation
import Security

/// One source credential and its destination are an atomic Keychain value.
/// Private operator import only; this is not the existing Gateway QR protocol.
struct HubDeviceConfiguration: Codable, Sendable {
    let schemaVersion: Int
    let source: String
    let endpoint: URL
    let bearerToken: String
    let deviceID: String
    let enabledRoutes: Set<String>
    let legacyDisabledRoutes: Set<String>

    func validated(deviceID expectedDeviceID: String) throws -> Self {
        let knownRoutes = Set(HubRecallRoute.allCases.map(\.rawValue))
        guard schemaVersion == 1, source == "recall", !deviceID.isEmpty,
              deviceID == expectedDeviceID,
              enabledRoutes.isSubset(of: knownRoutes),
              legacyDisabledRoutes.isSubset(of: enabledRoutes),
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              !bearerToken.isEmpty,
              !bearerToken.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw HubProvisioning.Failure.invalidConfiguration }
        return self
    }
}

@MainActor
final class HubProvisioning {
    static let shared = HubProvisioning()
    enum Failure: Error {
        case invalidConfiguration, activationRollback, importFailure, keychain(OSStatus)
    }

    private(set) var configuration: HubDeviceConfiguration?
    // Nonsecret latches keep an enabled route fail-closed when Keychain access
    // is temporarily unavailable. Missing credentials never mean legacy fallback.
    var enabledRoutes: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []) }
    var legacyDisabledRoutes: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []) }
    private static let enabledKey = "hub.enabledRoutes.v1"
    private static let disabledKey = "hub.legacyDisabledRoutes.v1"
    private let service = "com.recall.hub-ingress"
    private let account = "source-configuration-v1"
    private init() {}

    /// Called before any producer starts and on ordinary reconciliation ticks.
    /// Import file is removed only after a verified atomic Keychain replacement.
    func loadAndImport() throws {
        let expectedDeviceID = AppSettings.shared.deviceId
        if let data = try readKeychain() {
            guard let decoded = try? JSONDecoder().decode(HubDeviceConfiguration.self, from: data) else {
                throw Failure.invalidConfiguration
            }
            let value = try decoded.validated(deviceID: expectedDeviceID)
            configuration = value
            latch(value)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var importURL = documents.appendingPathComponent("hub-provisioning.json")
        guard FileManager.default.fileExists(atPath: importURL.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: importURL.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attrs[.size] as? NSNumber, bytes.intValue <= 65_536 else {
                throw Failure.invalidConfiguration
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: importURL.path)
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try importURL.setResourceValues(resource)
            let data = try Data(contentsOf: importURL)
            guard let decoded = try? JSONDecoder().decode(HubDeviceConfiguration.self, from: data) else {
                throw Failure.invalidConfiguration
            }
            let value = try decoded.validated(deviceID: expectedDeviceID)
            guard enabledRoutes.isSubset(of: value.enabledRoutes),
                  legacyDisabledRoutes.isSubset(of: value.legacyDisabledRoutes) else {
                throw Failure.activationRollback
            }
            try saveKeychain(data)
            guard try readKeychain() == data else { throw Failure.importFailure }
            configuration = value
            latch(value)
            try FileManager.default.removeItem(at: importURL)
            ActivityLogger.shared.log(.network, "Hub private configuration imported")
        } catch let failure as Failure { throw failure }
        catch { throw Failure.importFailure }
    }

    private func latch(_ value: HubDeviceConfiguration) {
        UserDefaults.standard.set(Array(enabledRoutes.union(value.enabledRoutes)).sorted(), forKey: Self.enabledKey)
        UserDefaults.standard.set(Array(legacyDisabledRoutes.union(value.legacyDisabledRoutes)).sorted(), forKey: Self.disabledKey)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func readKeychain() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return data
    }

    private func saveKeychain(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }
        let added = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
    }
}
