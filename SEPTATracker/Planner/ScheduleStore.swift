import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux only; lets tests run off-Mac.
#endif

/// Downloads, compiles and caches SEPTA's schedule, and plans trips with live data.
///
/// - Schedule: SEPTA's GTFS release (`gtfs_public.zip`, ~27 MB), compiled on the phone
///   into a ~30 MB cache in Application Support. Refreshed when older than `maxAge` or
///   when its calendars run out; a stale cache is still used if a refresh fails.
/// - Live: both TripUpdates feeds, fetched for every search. If they fail, routes are
///   schedule-only and say so.
actor ScheduleStore {
    static let shared = ScheduleStore()

    static let scheduleURL = URL(string: "https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip")!
    static let busTripUpdatesURL = URL(string: "https://www3.septa.org/gtfsrt/septa-pa-us/Trip/rtTripUpdates.pb")!
    static let railTripUpdatesURL = URL(string: "https://www3.septa.org/gtfsrt/septarail-pa-us/Trip/rtTripUpdates.pb")!
    static let maxAge: TimeInterval = 7 * 24 * 3600

    enum Phase: Sendable {
        case loadingCache, downloading, compiling, ready
        var message: String {
            switch self {
            case .loadingCache: return "Loading SEPTA schedule…"
            case .downloading: return "Downloading SEPTA schedule (about 27 MB)…"
            case .compiling: return "Preparing schedule…"
            case .ready: return ""
            }
        }
    }

    struct PlanResult: Sendable {
        let routes: [TransitRoute]
        let feedVersion: String
        /// Number of scheduled trips with a live prediction or cancellation; nil if live data failed.
        let liveTrips: Int?
        /// Set when an old cached schedule was used because refreshing failed.
        let staleScheduleWarning: String?
    }

    private var router: TripRouter?
    private var staleWarning: String?
    private let cacheURL: URL
    private let session: URLSession

    init(cacheDirectory: URL? = nil, session: URLSession = .shared) {
        let dir = cacheDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheURL = dir.appendingPathComponent("SEPTASchedule-v\(Timetable.formatVersion).bin")
        self.session = session
    }

    /// - Parameters:
    ///   - time: departure time, or the arrival deadline when `arriveBy` is true. Nil = now.
    func plan(from origin: GeoPoint, to destination: GeoPoint, time: Date? = nil, arriveBy: Bool = false,
              progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> PlanResult {
        let router = try await loadRouter(progress: progress)
        progress(.ready)
        let live = await fetchLive(router: router, now: Date())
        let routes = arriveBy
            ? router.plan(from: origin, to: destination, arriveBy: time ?? Date(), live: live)
            : router.plan(from: origin, to: destination, departAt: time ?? Date(), live: live)
        return PlanResult(routes: routes, feedVersion: router.timetable.feedVersion,
                          liveTrips: live?.matchedTrips, staleScheduleWarning: staleWarning)
    }

    /// Forces a fresh download next time.
    func invalidate() {
        router = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Schedule

    func loadRouter(now: Date = Date(), progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> TripRouter {
        if let router, isFresh(router.timetable, now: now) { return router }

        var cached: Timetable?
        if router == nil {
            progress(.loadingCache)
            cached = try? Timetable(serialized: Data(contentsOf: cacheURL))
            if let cached, isFresh(cached, now: now) {
                staleWarning = nil
                return install(cached)
            }
        } else {
            cached = router?.timetable
        }

        do {
            progress(.downloading)
            var request = URLRequest(url: Self.scheduleURL)
            request.timeoutInterval = 120
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SEPTAError.badStatus(http.statusCode)
            }
            progress(.compiling)
            let timetable = try Timetable.build(fromSEPTAZip: data, now: now)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? timetable.serialized().write(to: cacheURL, options: .atomic)
            staleWarning = nil
            return install(timetable)
        } catch {
            guard let cached else { throw error }
            staleWarning = "Couldn't update SEPTA's schedule (\(error.localizedDescription)). Using the copy from \(Self.dateText(cached.builtAt))."
            return install(cached)
        }
    }

    private func install(_ timetable: Timetable) -> TripRouter {
        let r = TripRouter(timetable: timetable)
        router = r
        return r
    }

    private func isFresh(_ t: Timetable, now: Date) -> Bool {
        let today = ServiceDay(containing: now).date
        return now.timeIntervalSince1970 - t.builtAt < Self.maxAge && t.validTo >= today
    }

    private static func dateText(_ unix: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: unix))
    }

    // MARK: Live

    private func fetchLive(router: TripRouter, now: Date) async -> LiveDelays? {
        async let bus = fetchTripUpdates(Self.busTripUpdatesURL)
        async let rail = fetchTripUpdates(Self.railTripUpdatesURL)
        let (b, r) = await (bus, rail)
        if b == nil && r == nil { return nil }
        return router.liveDelays(bus: b ?? [], rail: r ?? [], now: now)
    }

    private func fetchTripUpdates(_ url: URL) async -> [RealtimeTripUpdate]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return try? GTFSRealtime.parseTripUpdates(data)
    }
}
