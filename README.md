# SEPTA Live

An iOS app that shows where SEPTA buses, trolleys and Regional Rail trains are right now, on a map.

## What's implemented

- **Live map.** Every reporting bus, trolley and Regional Rail train is shown as a map marker, colored by mode. The app refreshes every 20 seconds while it's open and stops when it goes to the background.
- **Vehicle details.** Tap a marker to see its destination, direction, next stop, how late it is, and how old its last GPS report is (when SEPTA provides those fields).
- **Filters.** Turn modes on or off, and narrow the map to specific routes or lines. Routes are searchable.
- **Your location.** The app asks for "when in use" location so the map can show where you are, with a button to center on it.
- **Two SEPTA feeds, merged.** Vehicle positions come from SEPTA's JSON feeds (TransitView/TrainView) and its GTFS-realtime feed. For each vehicle the app uses the newest report, picks the right trip when TransitView lists a vehicle twice, and adds in-service buses that only GTFS-realtime reports. Positions are never averaged. See "Position accuracy" below.
- **Directions.** Search for a destination (Apple's place search). The app gets transit route options from the Google Routes API and shows them as a list: lines, times, walking, fare. For each SEPTA ride it shows how many of that line's vehicles are live and how far the closest one is from your boarding stop, with a button to show that line on the live map. "Open in Google Maps" hands the trip to Google Maps for turn-by-turn directions. In-app routes need an API key (see Directions setup); the hand-off works without one.
- **Partial failures.** Bus/trolley data and train data come from separate feeds. If one fails, the other keeps working, and the failing feed shows its last good data plus a warning. If only the GTFS-realtime half of a pair fails, the JSON feed is used alone, and vice versa for buses.

There's no backend. SEPTA's feeds need no key. Google directions need your own Google Maps Platform API key, which ships inside the app.

## Requirements

- macOS with Xcode 15 or newer
- iOS 17+ device or simulator

## Run it

1. Open `SEPTATracker.xcodeproj` in Xcode.
2. Select the `SEPTATracker` target, then open **Signing & Capabilities**.
3. Pick your development team and change the bundle identifier from `com.example.SEPTATracker` to something unique.
4. Choose an iPhone simulator or device and press Run.
5. Run the tests with ⌘U.

## Directions setup

1. In Google Cloud, create a project with billing enabled and enable the **Routes API**.
2. Create an API key. Under **Application restrictions**, choose iOS apps and add your bundle identifier. Under **API restrictions**, allow only the Routes API. Set a daily quota.
3. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (gitignored) and paste the key.
4. Rebuild. The key reaches the app through `Info.plist` (`GoogleMapsAPIKey`).

Anyone can extract a key from an app binary. The restrictions in step 2 limit what a stolen key can do, but a server-side proxy is the only real protection. Each search is a billed Routes API request, plus another each time you change the preference. Check Google's current pricing.

**Google's terms.** The May 2024 archived Google Maps Platform Service Specific Terms (section 11, Routes API) allow showing Routes API content without a map, but say it must not be used "in conjunction with a non-Google map". This app's map is MapKit. So directions open full screen, results are lists only, and no Google route geometry or stop location is drawn on the map; the field mask doesn't even request polylines. The "Show on live map" button only filters the map to SEPTA's own vehicle data for that route. This is my reading of an archived version of the terms. Check the current terms before shipping. Google's attribution guidelines also call for its logo; the app currently shows text only (`GoogleAttribution` in `TripPlannerView.swift`).

## Data sources

| Feed | Endpoint | Used for |
|---|---|---|
| TransitViewAll | `https://www3.septa.org/api/TransitViewAll/index.php` | Bus and trolley positions |
| TrainView | `https://www3.septa.org/api/TrainView/index.php` | Regional Rail positions |
| GTFS-RT VehiclePositions (bus/trolley) | `https://www3.septa.org/gtfsrt/septa-pa-us/Vehicle/rtVehiclePosition.pb` | Fresher positions, active trip, extra vehicles |
| GTFS-RT VehiclePositions (rail) | `https://www3.septa.org/gtfsrt/septarail-pa-us/Vehicle/rtVehiclePosition.pb` | Timestamped train positions |
| Google Routes API | `https://routes.googleapis.com/directions/v2:computeRoutes` | Transit route recommendations (needs key) |

GTFS-realtime is decoded by a small hand-written protobuf reader (`GTFSRealtime.swift`), so there's no SwiftProtobuf dependency.

Not used yet, but available:

- GTFS-realtime trip updates and alerts, under the same `/gtfsrt/` paths
- SEPTA's static GTFS schedule (routes, stops, shapes)

## Position accuracy: why not average Transit / Google Maps?

The original idea was to average SEPTA bus positions from the Transit app and Google Maps. That isn't done, for three reasons:

- **Neither offers the data.** Google Maps has no public API for live vehicle positions. Transit's API is partner-only.
- **They wouldn't add information.** Both get SEPTA positions from SEPTA's own feeds, so averaging them would mix copies of the same GPS reports.
- **Averaging lags the vehicle.** The copies come from different moments. A moving bus's average lands behind where it actually is.

What the app does instead, measured on a live capture (2026-11-07 ~6:17 pm Eastern):

| | TransitView alone | Merged with GTFS-realtime |
|---|---|---|
| Buses/trolleys shown | 393 | **522** (+129 in service that TransitView omits) |
| Duplicate entries resolved by actual trip | 0 of 6 correct (old "keep first" rule) | 6 of 6 |
| Positions replaced by a newer report | — | 4 of 397 (TransitView was usually as new or newer) |
| Trains with a report timestamp | 0 of 18 | 18 of 18 |

So the freshness gain for buses is small. The real wins are coverage, choosing the right trip, and timestamps for trains. For trains, the GTFS-realtime position is always preferred when it matches, because TrainView has no timestamp to compare. In one case, train 4459, TrainView's position was about 6.5 km from the stretch between the two stations it reported itself between, while GTFS-realtime's matched them. That's one example, not a measured error rate.

## Known gaps and risks

- **The app has never been built in Xcode or run on a device.** Nothing here has gone through the iOS SDK. These were written by hand and never compiled: the views (including `TripPlannerView` and `RouteDetailView`), `VehicleStore`, `LocationService`, `TripPlanner`/`PlaceSearch`, the Xcode project file, `Config/App.xcconfig`, and the shared scheme. The project file does load in the `pbxproj` Python library. Expect to fix small build errors on first open.
- **What was verified, and how.** SEPTA's JSON feeds were captured live on 2026-11-07 (Saturday ~6 pm Eastern), and again with both GTFS-realtime feeds at ~6:17 pm. Trimmed copies are in `SEPTATrackerTests/Fixtures/`; entries were dropped, nothing edited. These were compiled with Swift 6.0.3 on Linux, using stub `CoreLocation`/`SwiftUI` modules: `SEPTAClient`, `JSONValues`, `Vehicle`, `TransitMode`, `GTFSRealtime`, `VehicleMerger`, `TransitRoute`, `GoogleRoutesClient` and `LiveLineMatcher`. All 34 tests passed there. The tests have not been run in Xcode.
- **The Google Routes integration has never made a real request.** No API key was available. `GoogleRoutes-Synthetic.json` was written by hand from Google's documentation. The request format, the response parsing, and the `X-Ios-Bundle-Identifier` header used with iOS-restricted keys are all unverified against the live API. So is how Google names SEPTA lines. Live matching assumes Google's short name equals the TransitView route key ("21", "T1") and that Google's rail line name minus " Line" equals TrainView's `line`. If that's wrong, rides just show no live info. Capture a real response and replace the synthetic fixture first.
- **"Closest live vehicle" ignores direction.** It's the straight-line distance from the boarding stop to the nearest vehicle on that route, which may be heading the other way or may have already passed. A real "next bus" estimate needs GTFS-realtime trip updates.
- **Directions always start from your current location.** There's no way to pick a different starting point, and no departure-time picker. The API supports both.
- **Field names now match a live response, but there's still no spec.** TransitViewAll returns `{"routes":[{"<route>":[…]}]}`. TrainView returns a bare array. Field names and types are documented in `SEPTAClient.swift`. A single weekend-evening capture won't show every variant (for example, null coordinates, or a train with no next stop), so parsing stays lenient.
- **`Offset_sec` was misread before.** It is the schedule deviation in seconds (`Offset_sec / 60 ≈ late`), not how old the GPS report is. Report age now comes from TransitView's `timestamp` field (Unix seconds). TrainView has no timestamp, so trains show no report age.
- **TransitView lists some vehicles twice.** The duplicates have the same vehicle number and position but different trip IDs (10 of 433 entries in one capture, 6 of 399 in another). GTFS-realtime's `trip_id` says which trip is active, and that's used when available. It was always the entry with non-zero lateness; the `late: 0` entry is the next trip. When GTFS-realtime is unavailable, the app falls back to preferring the late entry. (The previous "keep the first entry" rule was wrong in every observed case.)
- **GTFS-realtime-only vehicles have less detail.** The 129 extra buses have a route, position and timestamp, but no destination, next stop or lateness. Vehicles in that feed with no trip (407 in the capture, presumably out of service) are left out. That they're out of service is an assumption.
- **Regional Rail matching relies on a trip-ID pattern.** GTFS-realtime rail trip IDs looked like `PAO9566_20261019_SID189798`, and the digits after the line code matched TrainView's `trainno` for all 18 trains. One train can appear under two trip IDs at the same position. Trains only in GTFS-realtime aren't added, because its line codes (`PAO`, `TRE`) don't map cleanly to TrainView line names.
- **Trolley detection is by route key and misclassifies bus substitutions.** Route keys seen: T1–T5, G1, M1, `D1_BUS`, `D2_BUS`, plus numeric bus routes and named ones (`BLVDDIR`, `NOR_BUS`, `K`). The old numeric trolley routes (10, 11, 13, 15, 34, 36, 101, 102) didn't appear. T and G1 vehicles include bus-numbered vehicles (for example 3042 on T1, and 3659 and 3398 on G1), which will show as trolleys. M1 (Norristown High Speed Line) is shown as a trolley because there's no separate light-rail mode. `D1_BUS`/`D2_BUS` are shown as buses.
- **Lateness sentinel.** TransitView sends `late: 998` (with `Offset_sec: "0"`) for "no estimate", which was seen twice. 999 wasn't seen. Anything 900 or more is treated as no estimate. Early vehicles have negative values, and `Offset` can be `"-0"`.
- **Subway (Market-Frankford / Broad Street) isn't shown.** These lines aren't in the two JSON feeds used here. The GTFS-RT feed may cover them.
- **Performance at full load is unverified.** The capture had 433 surface vehicles on a Saturday evening. Weekday peak will be higher. Standard `Marker`s are used rather than custom views. If the map lags, cluster markers or show only vehicles inside the visible region.
- **Coverage gaps.** TransitView omitted about a quarter of in-service buses compared with GTFS-realtime in the capture. GTFS-realtime may have gaps of its own; nothing here measures that.

## Project layout

```
SEPTATracker/
  SEPTATrackerApp.swift      App entry point, injects shared state
  Models/                    Vehicle, TransitMode (bus / trolley / rail)
  Services/                  SEPTAClient (HTTP + JSON parsing), GTFSRealtime (protobuf), VehicleMerger,
                             GoogleRoutesClient, LiveLineMatcher, TripPlanner/PlaceSearch,
                             VehicleStore (polling + filters), LocationService
  Support/                   Lenient JSON field readers
  Views/                     Map, vehicle detail sheet, filter sheet, directions, route detail
  Assets.xcassets
SEPTATrackerTests/
  SEPTAClientParsingTests.swift  Parser tests (run with ⌘U)
  VehicleMergerTests.swift   GTFS-realtime decoding and merging
  GoogleRoutesTests.swift    Routes request/parse, live line matching
  Fixtures/                  Trimmed live SEPTA responses; GoogleRoutes-Synthetic.json is hand-written
Config/
  App.xcconfig               Base settings; includes the gitignored Secrets.xcconfig
```

## Next steps

1. Build in Xcode, fix any compile errors, and run the tests (⌘U).
2. With an API key, capture a real Routes API response for a SEPTA trip, replace the synthetic fixture, and fix line-name matching.
3. Check the current Google Maps Platform terms and attribution requirements.
4. Capture a weekday-peak response and check for field variants the weekend capture missed.
5. Use GTFS-realtime trip updates for real "next vehicle at your stop" times.
6. Draw route lines and stops from SEPTA's static GTFS data.
7. Show service alerts.
8. Save favorite routes and use them as the default filter.
