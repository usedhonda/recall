import Foundation

struct MultipartFormData {
    let boundary: String
    private var parts: [Data] = []

    init() {
        boundary = "recai-\(UUID().uuidString)"
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        var part = Data()
        part.append("--\(boundary)\r\n")
        part.append("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        part.append("\r\n")
        part.append("\(value)\r\n")
        parts.append(part)
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        var part = Data()
        part.append("--\(boundary)\r\n")
        part.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        part.append("Content-Type: \(mimeType)\r\n")
        part.append("\r\n")
        part.append(data)
        part.append("\r\n")
        parts.append(part)
    }

    func build() -> Data {
        var body = Data()
        for part in parts {
            body.append(part)
        }
        body.append("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
