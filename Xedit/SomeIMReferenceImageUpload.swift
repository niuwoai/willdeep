//
//  SomeIMReferenceImageUpload.swift
//  WillDeep
//
//  Turns a local image file into a public URL that the image-generation
//  gateway can fetch as a reference image.
//
//  Why this exists at all: `/v1/images/generations` only accepts reference
//  images as URLs, and the gateway fetches them with an ordinary HTTP GET
//  (see muchtoken `internal/asyncmedia/openai_image.go` →
//  `fetchImageBytesForOpenAI`). A `data:` URL therefore cannot work — Go's
//  HTTP client has no such scheme — and nothing on any image route decodes
//  an input data URL. The nano-banana route is worse: it forwards the URL
//  list verbatim to its upstream. So local bytes have to be uploaded first;
//  there is no inline path to fall back on.
//
//  The upload endpoint lives under `/api/v1`, NOT the `/v1` inference
//  prefix, and accepts a gateway API key. Its documented limits: 8 MB, real
//  JPEG/PNG/GIF/WebP only (sniffed by magic bytes, not by extension), and a
//  24-hour lifetime.
//

import CryptoKit
import Foundation

nonisolated struct SomeIMReferenceImage: Equatable, Sendable {
    /// The public URL to hand to `reference_image_urls[]`.
    let publicURL: String
    /// When the gateway stops serving it. Uploads are re-done after this.
    let expiresAt: Date

    init(publicURL: String, expiresAt: Date) {
        self.publicURL = publicURL
        self.expiresAt = expiresAt
    }
}

nonisolated enum SomeIMReferenceImageUpload {
    /// Server-side limit. Checked here too so an oversized file fails with a
    /// clear local message instead of a 413 from the relay.
    static let maximumBytes = 8 * 1024 * 1024

    /// Conservative default when the response omits `expires_at`. The server
    /// documents 24 hours; expiring our cache earlier only costs one re-upload.
    static let assumedLifetime: TimeInterval = 20 * 60 * 60

    /// Magic-byte sniffing mirroring the server's own check, so a mislabelled
    /// file is rejected before we spend an upload on it.
    static func imageExtension(forContentsOf fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 16) ?? Data()
        let bytes = [UInt8](head)
        func matches(_ prefix: [UInt8]) -> Bool {
            bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
        }
        if matches([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if matches([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if matches([0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if bytes.count >= 12,
           Array(bytes.prefix(4)) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
        throw AgentToolError.invalidArgument(
            "Reference image is not a JPEG/PNG/GIF/WebP: \(fileURL.lastPathComponent)"
        )
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "jpg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// The upload host is derived from the inference base URL by dropping its
    /// path entirely: the two live on the same host under different prefixes
    /// (`/v1` for inference, `/api/v1` for this). Deriving rather than
    /// hardcoding keeps a self-hosted or staging base URL working.
    static func endpoint(inferenceBaseURL: String) throws -> URL {
        let trimmed = inferenceBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmed), components.host != nil else {
            throw AgentClientError.invalidBaseURL
        }
        components.path = "/api/v1/customer/tmp-files"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw AgentClientError.invalidBaseURL }
        return url
    }

    /// Upload one local image and return its public URL.
    static func upload(
        fileURL: URL,
        inferenceBaseURL: String,
        apiKey: String,
        session: URLSession
    ) async throws -> SomeIMReferenceImage {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AgentToolError.invalidArgument("Reference image is not a file: \(fileURL.path)")
        }
        let size = values.fileSize ?? 0
        guard size > 0 else {
            throw AgentToolError.invalidArgument("Reference image is empty: \(fileURL.lastPathComponent)")
        }
        guard size <= maximumBytes else {
            throw AgentToolError.invalidArgument(
                "Reference image is larger than the 8 MB upload limit: \(fileURL.lastPathComponent)"
            )
        }
        let ext = try imageExtension(forContentsOf: fileURL)
        let payload = try Data(contentsOf: fileURL, options: [.mappedIfSafe])

        let boundary = "willdeep-\(UUID().uuidString)"
        var request = URLRequest(url: try endpoint(inferenceBaseURL: inferenceBaseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = AgentNetworkSupport.resourceTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        request.httpBody = multipartBody(
            boundary: boundary,
            filename: "reference.\(ext)",
            mimeType: mimeType(forExtension: ext),
            payload: payload
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.httpFailed(
                http.statusCode,
                AgentNetworkSupport.limitDebugText(
                    String(data: data.prefix(64 * 1024), encoding: .utf8) ?? "<non-UTF8 response body>"
                )
            )
        }
        return try parse(response: data)
    }

    /// The payload nests the record under `data` on this endpoint, but a bare
    /// object is accepted too so a relay that unwraps it does not break us.
    static func parse(response data: Data) throws -> SomeIMReferenceImage {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { throw AgentClientError.invalidResponse }
        let record = (object["data"] as? [String: Any]) ?? object
        guard let publicURL = (record["public_url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !publicURL.isEmpty else {
            throw AgentToolError.invalidArgument("Reference upload response had no public_url.")
        }
        var expiresAt = Date().addingTimeInterval(assumedLifetime)
        if let seconds = record["ttl_seconds"] as? Double, seconds > 0 {
            expiresAt = Date().addingTimeInterval(min(seconds, assumedLifetime))
        } else if let text = record["expires_at"] as? String,
                  let parsed = ISO8601DateFormatter().date(from: text) {
            expiresAt = parsed
        }
        return SomeIMReferenceImage(publicURL: publicURL, expiresAt: expiresAt)
    }

    static func multipartBody(
        boundary: String,
        filename: String,
        mimeType: String,
        payload: Data
    ) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(payload)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Content hash, so the same face reused across shots and episodes is
    /// uploaded once per lifetime window rather than once per generation.
    /// Keyed on bytes rather than path: regenerating a character's portrait
    /// writes a new file, and an identical file copied elsewhere should hit.
    static func contentKey(forContentsOf fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Process-wide cache of uploaded reference images.
///
/// Deliberately in memory only: the server's copy expires in 24 hours, so a
/// cache that outlived the process would hand out dead URLs after a restart,
/// and the failure would surface as a confusing upstream fetch error rather
/// than a re-upload.
nonisolated final class SomeIMReferenceImageCache: @unchecked Sendable {
    static let shared = SomeIMReferenceImageCache()

    private let lock = NSLock()
    private var entries: [String: SomeIMReferenceImage] = [:]

    init() {}

    func cached(contentKey: String) -> SomeIMReferenceImage? {
        lock.withLock {
            guard let entry = entries[contentKey] else { return nil }
            // A minute of slack: a URL about to expire mid-request is worse
            // than one extra upload.
            guard entry.expiresAt > Date().addingTimeInterval(60) else {
                entries[contentKey] = nil
                return nil
            }
            return entry
        }
    }

    func store(contentKey: String, image: SomeIMReferenceImage) {
        lock.withLock { entries[contentKey] = image }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}
