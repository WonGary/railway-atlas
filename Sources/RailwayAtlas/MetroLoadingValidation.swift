#if os(macOS)
import Foundation
import MapKit
import RailwayCore

@MainActor
enum MetroLoadingValidation {
    static func run() async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetroLoadingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = RailwayMapStore(tileSession: session)
        store.mapMode = .apple
        store.enrichWikiColours = false
        store.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.58, longitude: 127.10),
                                         span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.045))
        store.refreshViewport(force: true)
        try await Task.sleep(for: .milliseconds(500))
        guard MetroLoadingProtocol.state.requests == 1 else { throw DataError.invalid("Colour request did not start alongside rail tiles") }
        let generation = store.metroGeneration
        for factor in [0.65, 0.8, 1.25, 1 / 0.65] {
            store.zoom(factor)
            try await Task.sleep(for: .milliseconds(100))
            guard store.metroGeneration == generation else { throw DataError.invalid("Zoom cancelled city colour request") }
        }
        for _ in 0..<80 {
            if !store.metroLoading && store.assemblyTask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !store.metroLoading, MetroLoadingProtocol.state.requests == 1,
              store.onlineLines.contains(where: { $0.appearance.colors.first?.hex == "#00A84D" }) else {
            throw DataError.invalid("Delayed colour response was lost or requested twice after zoom")
        }
        store.changeMode(.cached)
        for _ in 0..<80 {
            if !store.onlineLoading && store.assemblyTask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.onlineLines.contains(where: { $0.appearance.colors.first?.hex == "#00A84D" }),
              MetroLoadingProtocol.state.requests == 1 else { throw DataError.invalid("Offline reload lost the learned line colour") }
        MetroLoadingProtocol.state.setFailure(true, longitude: 126.70)
        let retry = RailwayMapStore(tileSession: session, metroRetryDelays: [1])
        retry.mapMode = .apple; retry.enrichWikiColours = false
        retry.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.58, longitude: 126.70),
                                          span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.045))
        retry.refreshViewport()
        for _ in 0..<70 {
            if retry.metroNeedsRetry { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard retry.metroNeedsRetry else { throw DataError.invalid("Failed metro attempt was incorrectly marked complete") }
        MetroLoadingProtocol.state.setFailure(false, longitude: 126.70)
        await retry.tileRepository.retrySources()
        for _ in 0..<60 {
            if !retry.metroNeedsRetry && !retry.metroLoading && retry.assemblyTask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !retry.metroNeedsRetry, retry.onlineLines.contains(where: { $0.appearance.colors.first?.hex == "#00A84D" }) else {
            throw DataError.invalid("Metro did not recover automatically after a temporary outage")
        }
        retry.changeMode(.cached)
        return "Delayed Seoul relation response survives four zoom changes: one geometry request, one city generation, matching line colour. Offline reload keeps the colour with no new request. A temporarily failed city request is retried automatically and colours arrive after recovery. Local protocol fixture with shortened retry delay, no external service or credentials used."
    }
}

private final class MetroLoadingState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failure = false
    private var longitude = 127.10
    func record() { lock.lock(); count += 1; lock.unlock() }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setFailure(_ value: Bool, longitude: Double) {
        lock.lock(); defer { lock.unlock() }
        failure = value; self.longitude = longitude
    }
    var response: (Bool, Double) { lock.lock(); defer { lock.unlock() }; return (failure, longitude) }
}
private final class MetroLoadingProtocol: URLProtocol, @unchecked Sendable {
    static let state = MetroLoadingState()
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "data" })?.value ?? ""
        let geometry = query.contains("way(r.routes)")
        if geometry { Self.state.record() }
        let (failed, longitude) = Self.state.response
        let data = query.isEmpty ? Data() : Data("""
        {"elements":[
          {"type":"relation","id":2404374,"tags":{"route":"subway","network":"수도권 전철","ref":"2"},"members":[
            {"type":"way","ref":1234,"geometry":[{"lat":37.58,"lon":\(longitude - 0.01)},{"lat":37.581,"lon":\(longitude + 0.01)}]}]}
        ]}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: query.isEmpty ? 204 : failed ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=600"])!
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        if geometry && !failed { DispatchQueue.global().asyncAfter(deadline: .now() + 1.2, execute: work) }
        else { work.perform() }
    }
    override func stopLoading() { pending?.cancel() }
}
#endif
