import CryptoKit
import Foundation

/// The routes admitted by the Recall producer profile. This type only describes
/// the wire contract; it does not enable a route or perform any I/O.
enum HubRecallRoute: String, CaseIterable, Sendable {
    case audioOriginal = "audio-original"
    case gpsDelivery = "gps-delivery"
    case healthSnapshot = "health-snapshot"
    case geofence
    case wifi
    case channelReport = "channel-report"
    case nowPlaying = "now-playing"
    case glassesOriginal = "glasses-original"

    var domain: String {
        switch self {
        case .audioOriginal: return "audio"
        case .gpsDelivery: return "gps"
        case .healthSnapshot: return "health"
        case .geofence, .wifi, .channelReport, .nowPlaying: return "status"
        case .glassesOriginal: return "glasses"
        }
    }

    var kind: String { "recall.\(rawValue).v1" }
}

struct HubProducerParent: Codable, Equatable, Sendable {
    let source: String
    let externalID: String
    let eventID: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case externalID = "external_id"
        case eventID = "event_id"
    }
}

struct HubProducerEnvelope: Sendable {
    let source: String
    let route: HubRecallRoute
    let deviceID: String
    let observationID: String
    let externalID: String
    let originalSHA256: String?
    let originalByteLength: Int
    let encodedJSON: Data

    var expectedReceipt: HubExpectedStorageReceipt {
        HubExpectedStorageReceipt(source: source, externalID: externalID,
                                  sha256: originalSHA256, byteLength: originalByteLength)
    }
}

struct HubExpectedStorageReceipt: Equatable, Sendable {
    let source: String
    let externalID: String
    let sha256: String?
    let byteLength: Int
}

struct HubStorageReceipt: Codable, Equatable, Sendable {
    let receiptVersion: Int
    let source: String
    let externalID: String
    let eventID: String
    let sha256: String?
    let byteLength: Int
    let ingestSequence: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case receiptVersion = "receipt_version"
        case source
        case externalID = "external_id"
        case eventID = "event_id"
        case sha256
        case byteLength = "byte_length"
        case ingestSequence = "ingest_sequence"
    }

    /// Decodes a receipt while rejecting unknown keys and JSON type coercion.
    static func decode(_ data: Data) throws -> HubStorageReceipt {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw HubProducerError.invalidReceipt
        }
        let receipt: HubStorageReceipt
        do { receipt = try JSONDecoder().decode(HubStorageReceipt.self, from: data) }
        catch { throw HubProducerError.invalidReceipt }
        guard receipt.receiptVersion == 1,
              receipt.source == "recall",
              receipt.source.count > 0,
              receipt.externalID.isEmpty == false,
              isStrictInteger(dictionary["receipt_version"]),
              isStrictInteger(dictionary["byte_length"]),
              isStrictInteger(dictionary["ingest_sequence"]),
              receipt.byteLength >= 0,
              receipt.ingestSequence > 0,
              receipt.eventID.count == 36,
              receipt.eventID == receipt.eventID.lowercased(),
              UUID(uuidString: receipt.eventID).map({ $0.uuidString.lowercased() == receipt.eventID }) == true,
              receipt.sha256 == nil || HubProducerContract.isSHA256(receipt.sha256!) else {
            throw HubProducerError.invalidReceipt
        }
        return receipt
    }

    func matched(to expected: HubExpectedStorageReceipt, boundEventID: String? = nil) throws -> String {
        guard expected.source == "recall", !expected.externalID.isEmpty, expected.byteLength >= 0,
              expected.sha256 == nil || HubProducerContract.isSHA256(expected.sha256!) else {
            throw HubProducerError.invalidReceipt
        }
        guard source == expected.source else { throw HubProducerError.receiptSourceMismatch }
        guard externalID == expected.externalID else { throw HubProducerError.receiptExternalIDMismatch }
        guard sha256 == expected.sha256 else { throw HubProducerError.receiptHashMismatch }
        guard byteLength == expected.byteLength else { throw HubProducerError.receiptByteLengthMismatch }
        if expected.sha256 != nil, sha256 == nil { throw HubProducerError.metadataReceiptForOriginal }
        if let boundEventID, eventID != boundEventID { throw HubProducerError.receiptEventIDMismatch }
        return eventID
    }
}

struct HubProcessingReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, leased, completed, failed, expired }
    let receiptVersion: Int
    let intentCommitted: Bool
    let jobID: String
    let originalEventID: String
    let pipelineVersion: String
    let state: State

    enum CodingKeys: String, CodingKey, CaseIterable {
        case receiptVersion = "receipt_version"
        case intentCommitted = "intent_committed"
        case jobID = "job_id"
        case originalEventID = "original_event_id"
        case pipelineVersion = "pipeline_version"
        case state
    }

    static func decode(_ data: Data, expectedOriginalEventID: String) throws -> HubProcessingReceipt {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
              isStrictInteger(dictionary["receipt_version"]),
              isStrictBoolean(dictionary["intent_committed"]) else { throw HubProducerError.invalidProcessingReceipt }
        let receipt: HubProcessingReceipt
        do { receipt = try JSONDecoder().decode(HubProcessingReceipt.self, from: data) }
        catch { throw HubProducerError.invalidProcessingReceipt }
        guard receipt.receiptVersion == 1,
              receipt.intentCommitted,
              !receipt.jobID.isEmpty,
              receipt.originalEventID == expectedOriginalEventID,
              receipt.pipelineVersion == "local-stt-v1" else { throw HubProducerError.invalidProcessingReceipt }
        return receipt
    }
}

enum HubProducerError: Error, Equatable {
    case invalidSourcePayload
    case invalidRoute
    case invalidIdentity
    case externalIDTooLong
    case invalidOriginalHash
    case originalHashMismatch
    case conflictingOriginal
    case envelopeTooLarge
    case invalidReceipt
    case receiptSourceMismatch
    case receiptExternalIDMismatch
    case receiptHashMismatch
    case receiptByteLengthMismatch
    case receiptEventIDMismatch
    case metadataReceiptForOriginal
    case invalidProcessingReceipt
    case processingReceiptMismatch
}

enum HubProducerContract {
    static let source = "recall"
    static let maximumEncodedJSONBytes = 20_971_520

    static func canonicalExternalID(route: HubRecallRoute, deviceID: String, observationID: String) throws -> String {
        guard !deviceID.isEmpty, !observationID.isEmpty,
              let device = deviceID.data(using: .utf8), let observation = observationID.data(using: .utf8) else {
            throw HubProducerError.invalidIdentity
        }
        let encoded = "v1:\(route.rawValue):\(device.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")):\(observation.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))"
        guard encoded.utf8.count <= 512 else { throw HubProducerError.externalIDTooLong }
        return encoded
    }

    static func makeEnvelope(route: HubRecallRoute, deviceID: String, observationID: String,
                             occurredAt: Date, timeBasis: String, sourcePayloadJSON: Data,
                             parents: [HubProducerParent] = [], originalBytes: Data? = nil,
                             originalSHA256: String? = nil, originalByteLength: Int? = nil) throws -> HubProducerEnvelope {
        guard String(data: sourcePayloadJSON, encoding: .utf8) != nil,
              sourcePayloadJSON.first(where: { ![9, 10, 13, 32].contains($0) }) == UInt8(ascii: "{"),
              let payload = try? JSONSerialization.jsonObject(with: sourcePayloadJSON),
              let payloadObject = payload as? [String: Any],
              JSONSerialization.isValidJSONObject(payloadObject) else { throw HubProducerError.invalidSourcePayload }
        let externalID = try canonicalExternalID(route: route, deviceID: deviceID, observationID: observationID)
        let computedHash = originalBytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        if let originalSHA256, !isSHA256(originalSHA256) { throw HubProducerError.invalidOriginalHash }
        if let originalSHA256, let computedHash, originalSHA256 != computedHash { throw HubProducerError.originalHashMismatch }
        let hash = originalSHA256 ?? computedHash
        let byteLength: Int
        if let originalBytes { byteLength = originalBytes.count }
        else if let originalSHA256, let originalByteLength, originalByteLength > 0 {
            _ = originalSHA256
            byteLength = originalByteLength
        } else if originalSHA256 != nil || originalByteLength != nil {
            throw HubProducerError.conflictingOriginal
        } else {
            byteLength = 0
        }

        if (route == .audioOriginal || route == .glassesOriginal) && hash == nil {
            throw HubProducerError.conflictingOriginal
        }
        let metadataWithoutPayload: [String: Any] = ["schema_version": 1, "device_id": deviceID,
                                        "observation_id": observationID,
                                        "time_basis": timeBasis, "parents": parents.map { [
                                            "source": $0.source, "external_id": $0.externalID,
                                            "event_id": $0.eventID.map { $0 as Any } ?? NSNull()
                                        ] }]
        let occurred = ISO8601DateFormatter.hub.string(from: occurredAt)
        let metadataBase = try JSONSerialization.data(withJSONObject: metadataWithoutPayload, options: [.sortedKeys])
        guard metadataBase.last == UInt8(ascii: "}") else { throw HubProducerError.invalidSourcePayload }
        var metadata = Data(metadataBase.dropLast())
        metadata.append(contentsOf: Data(",\"source_payload\":".utf8))
        metadata.append(sourcePayloadJSON)
        metadata.append(UInt8(ascii: "}"))
        var envelope: [String: Any] = ["source": source, "domain": route.domain, "kind": route.kind,
                                       "occurred_at": occurred, "external_id": externalID, "identity": NSNull()]
        if let bytes = originalBytes { envelope["payload_base64"] = bytes.base64EncodedString() }
        else if let hash { envelope["blob_sha256"] = hash }
        var envelopeBase = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard envelopeBase.last == UInt8(ascii: "}") else { throw HubProducerError.invalidSourcePayload }
        envelopeBase.removeLast()
        envelopeBase.append(contentsOf: Data(",\"metadata\":".utf8))
        envelopeBase.append(metadata)
        envelopeBase.append(UInt8(ascii: "}"))
        let encoded = envelopeBase
        guard encoded.count <= maximumEncodedJSONBytes else { throw HubProducerError.envelopeTooLarge }
        return HubProducerEnvelope(source: source, route: route, deviceID: deviceID, observationID: observationID,
                                   externalID: externalID, originalSHA256: hash,
                                   originalByteLength: byteLength, encodedJSON: encoded)
    }

    static func validateResponse(responseData: Data, expected: HubExpectedStorageReceipt,
                                 boundEventID: String? = nil) throws -> HubStorageReceipt {
        guard let object = try? JSONSerialization.jsonObject(with: responseData),
              let response = object as? [String: Any],
              let receiptObject = response["storage_receipt"],
              JSONSerialization.isValidJSONObject(receiptObject),
              let receiptDictionary = receiptObject as? [String: Any],
              isStrictInteger(receiptDictionary["receipt_version"]),
              isStrictInteger(receiptDictionary["byte_length"]),
              isStrictInteger(receiptDictionary["ingest_sequence"]) else {
            throw HubProducerError.invalidReceipt
        }
        let receipt = try HubStorageReceipt.decode(JSONSerialization.data(withJSONObject: receiptObject))
        _ = try receipt.matched(to: expected, boundEventID: boundEventID)
        return receipt
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

private func isStrictInteger(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    let type = String(cString: number.objCType)
    return type == "i" || type == "q" || type == "s" || type == "l" || type == "I" || type == "Q" || type == "S" || type == "L"
}

private func isStrictBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    let type = String(cString: number.objCType)
    return type == "c" || type == "B"
}

private extension ISO8601DateFormatter {
    static let hub: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
