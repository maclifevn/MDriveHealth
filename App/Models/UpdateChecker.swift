/* Manual update metadata, bounded HTTPS and exact release assets. GPL-3.0-or-later. */
import Foundation

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL
}
protocol UpdateFetching: Sendable {
    /// Implementations must honor task cancellation; production owns one ephemeral session per call.
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse
}

// Immutable private configuration; callers cannot mutate the retained copy.
final class UpdateHTTPFetcher: UpdateFetching, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.timeoutIntervalForRequest = 10; copy.timeoutIntervalForResource = 12
        copy.waitsForConnectivity = false; copy.urlCache = nil; copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false; copy.urlCredentialStorage = nil
        self.configuration = copy
    }
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        let session = URLSession(configuration: configuration, delegate: UpdateNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let url = http.url, url == request.url else { throw UpdateChecker.Failure.response }
        guard http.statusCode == 200 else { return .init(data: Data(), statusCode: http.statusCode, url: url) }
        guard http.expectedContentLength <= maximumBytes else { throw UpdateChecker.Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw UpdateChecker.Failure.tooLarge }
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return .init(data: data, statusCode: http.statusCode, url: url)
    }
}
private final class UpdateNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum UpdateChecker {
    static let repository = "maclifevn/MDriveHealth"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let maximumResponseBytes = 1 << 20
    struct Release: Sendable, Equatable {
        let version: String
        let url: URL
        let downloadURL: URL?
    }
    enum Failure: Error, Sendable, Equatable {
        case response, metadata, currentVersion, unstableRelease, tooLarge, timeout, network, noRelease, rateLimited, http(Int)
        var message: String {
            switch self {
            case .response: return String(localized: "update.error.response", defaultValue: "Invalid update response.")
            case .metadata: return String(localized: "update.error.metadata", defaultValue: "Couldn't read release metadata.")
            case .currentVersion: return String(localized: "update.error.currentVersion", defaultValue: "This build has invalid version metadata.")
            case .unstableRelease: return String(localized: "update.error.unstable", defaultValue: "The latest response is not a stable release.")
            case .tooLarge: return String(localized: "update.error.tooLarge", defaultValue: "Release metadata exceeds the size limit.")
            case .timeout: return String(localized: "update.error.timeout", defaultValue: "The check timed out. Try again.")
            case .network: return String(localized: "update.error.network", defaultValue: "Could not reach GitHub. Check your connection and try again.")
            case .noRelease: return String(localized: "update.error.noRelease", defaultValue: "No public release was found. Check the releases page.")
            case .rateLimited: return String(localized: "update.error.rateLimited", defaultValue: "GitHub limited this request. Try again later.")
            case .http(let code): return String.localizedStringWithFormat(String(localized: "update.error.http", defaultValue: "GitHub returned HTTP %lld."), code)
            }
        }
    }
    enum CheckResult: Sendable, Equatable {
        case upToDate, available(Release), failed(Failure), cancelled
    }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var displayedVersion: String { currentVersion.isEmpty ? String(localized: "update.version.unknown", defaultValue: "Unknown") : currentVersion }

    static func checkForUpdate(currentVersion: String = currentVersion, fetcher: any UpdateFetching = UpdateHTTPFetcher(), timeout: Duration = .seconds(12)) async -> CheckResult {
        do {
            try Task.checkCancellation()
            guard SemanticVersion(currentVersion) != nil else { throw Failure.currentVersion }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("MDriveHealth/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let preparedRequest = request
            let response = try await withThrowingTaskGroup(of: UpdateHTTPResponse.self) { group in
                group.addTask { try await fetcher.fetch(preparedRequest, maximumBytes: maximumResponseBytes) }
                group.addTask { try await Task.sleep(for: timeout); throw Failure.timeout }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw CancellationError() }
                return response
            }
            try Task.checkCancellation()
            guard response.url == endpoint else { throw Failure.response }
            guard response.data.count <= maximumResponseBytes else { throw Failure.tooLarge }
            switch response.statusCode {
            case 200: return try interpret(response.data, currentVersion: currentVersion)
            case 404: throw Failure.noRelease
            case 403, 429: throw Failure.rateLimited
            default: throw Failure.http(response.statusCode)
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            if let failure = error as? Failure { return .failed(failure) }
            if (error as? URLError)?.code == .timedOut { return .failed(.timeout) }
            return .failed(.network)
        }
    }

    static func interpret(_ data: Data, currentVersion: String) throws -> CheckResult {
        guard data.count <= maximumResponseBytes else { throw Failure.tooLarge }
        guard let current = SemanticVersion(currentVersion) else { throw Failure.currentVersion }
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: data) } catch { throw Failure.metadata }
        let version = metadata.tag_name.hasPrefix("v") ? String(metadata.tag_name.dropFirst()) : metadata.tag_name
        guard let latest = SemanticVersion(version), metadata.assets.count <= 100 else { throw Failure.metadata }
        guard !metadata.draft, !metadata.prerelease, latest.prerelease.isEmpty else { throw Failure.unstableRelease }
        guard let page = releaseURL(path: "/\(repository)/releases/tag/\(metadata.tag_name)", received: metadata.html_url) else { throw Failure.metadata }
        let name = "MDriveHealth-\(version).dmg"
        let matches = metadata.assets.filter { $0.name == name }
        guard matches.count <= 1 else { throw Failure.metadata }
        var download: URL?
        if let asset = matches.first {
            guard asset.state == "uploaded", asset.size > 0,
                  let url = releaseURL(path: "/\(repository)/releases/download/\(metadata.tag_name)/\(name)", received: asset.browser_download_url) else { throw Failure.metadata }
            download = url
        }
        guard latest.compare(to: current) == .orderedDescending else { return .upToDate }
        return .available(.init(version: version, url: page, downloadURL: download))
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let lhs = SemanticVersion(candidate), let rhs = SemanticVersion(current) else { return false }
        return lhs.compare(to: rhs) == .orderedDescending
    }
    private static func releaseURL(path: String, received: String) -> URL? {
        var expected = URLComponents(); expected.scheme = "https"; expected.host = "github.com"; expected.path = path
        guard let actual = URLComponents(string: received), actual.scheme == "https", actual.host == "github.com",
              actual.user == nil, actual.password == nil, actual.port == nil, actual.query == nil, actual.fragment == nil,
              actual.percentEncodedPath == expected.percentEncodedPath else { return nil }
        return expected.url
    }
    private struct Metadata: Decodable {
        let tag_name: String, html_url: String
        let draft: Bool, prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String, browser_download_url: String, state: String
        let size: Int64
    }
}
