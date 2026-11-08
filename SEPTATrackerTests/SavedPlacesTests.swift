import XCTest
@testable import SEPTATracker

final class SavedPlacesTests: XCTestCase {
    private let cityHall = Place(name: "City Hall", subtitle: "Philadelphia", point: GeoPoint(latitude: 39.9524, longitude: -75.1636))
    private let temple = Place(name: "Temple University", subtitle: nil, point: GeoPoint(latitude: 39.9814, longitude: -75.1495))
    private let zoo = Place(name: "Philadelphia Zoo", subtitle: nil, point: GeoPoint(latitude: 39.9714, longitude: -75.1955))

    func testHomeAndWorkReplacePrevious() {
        var saved = SavedPlaces()
        saved.save(cityHall, as: .home)
        saved.save(temple, as: .work)
        saved.save(zoo, as: .home)
        XCTAssertEqual(saved.home?.place, zoo)
        XCTAssertEqual(saved.work?.place, temple)
        XCTAssertEqual(saved.all.map(\.displayName), ["Home", "Work"])
    }

    func testStarringIsDeduplicatedByLocation() {
        var saved = SavedPlaces()
        saved.save(zoo, as: .starred, label: "Zoo")
        let nearlySame = Place(name: "Zoo entrance", subtitle: nil, point: GeoPoint(latitude: 39.97141, longitude: -75.19551))
        saved.save(nearlySame, as: .starred)
        XCTAssertEqual(saved.starred.count, 1)
        XCTAssertEqual(saved.starred.first?.displayName, "Zoo")
        XCTAssertTrue(saved.isStarred(nearlySame))
        saved.unstar(nearlySame)
        XCTAssertFalse(saved.isStarred(zoo))
    }

    func testOrderAndRemoval() {
        var saved = SavedPlaces()
        saved.save(zoo, as: .starred)
        saved.save(temple, as: .work)
        saved.save(cityHall, as: .home)
        XCTAssertEqual(saved.all.map(\.kind), [.home, .work, .starred])
        XCTAssertEqual(saved.entry(at: temple)?.kind, .work)
        saved.remove(id: saved.work!.id)
        XCTAssertNil(saved.work)
        XCTAssertNil(saved.entry(at: temple))
    }

    func testPersistsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SavedPlacesTests-\(UUID().uuidString)"))
        XCTAssertEqual(SavedPlaces.load(from: defaults), SavedPlaces(), "empty when nothing stored")
        var saved = SavedPlaces()
        saved.save(cityHall, as: .home)
        saved.save(zoo, as: .starred, label: "Zoo")
        saved.store(to: defaults)
        XCTAssertEqual(SavedPlaces.load(from: defaults), saved)

        defaults.set(Data("garbage".utf8), forKey: SavedPlaces.defaultsKey)
        XCTAssertEqual(SavedPlaces.load(from: defaults), SavedPlaces(), "corrupt data falls back to empty")
    }
}
