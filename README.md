# SEPTA Live

An iOS app that shows where SEPTA buses, trolleys and Regional Rail trains are right now, on a map.

## What's implemented

- **Live map.** Every reporting bus, trolley and Regional Rail train is shown as a map marker, colored by mode. The app refreshes every 20 seconds while it's open and stops when it goes to the background.
- **Vehicle details.** Tap a marker to see its destination, direction, next stop, how late it is, and how old its last GPS report is (when SEPTA provides those fields).
- **Filters.** Turn modes on or off, and narrow the map to specific routes or lines. Routes are searchable.
- **Your location.** The app asks for "when in use" location so the map can show where you are, with a button to center on it.
- **Partial failures.** Bus/trolley data and train data come from separate feeds. If one fails, the other keeps working, and the failing feed shows its last good data plus a warning.

There's no backend and no API key. The app calls SEPTA's public endpoints directly.

## Requirements

- macOS with Xcode 15 or newer
- iOS 17+ device or simulator

## Run it

1. Open `SEPTATracker.xcodeproj` in Xcode.
2. Select the `SEPTATracker` target, then open **Signing & Capabilities**.
3. Pick your development team and change the bundle identifier from `com.example.SEPTATracker` to something unique.
4. Choose an iPhone simulator or device and press Run.

## Data sources

| Feed | Endpoint | Used for |
|---|---|---|
| TransitViewAll | `https://www3.septa.org/api/TransitViewAll/index.php` | Bus and trolley positions |
| TrainView | `https://www3.septa.org/api/TrainView/index.php` | Regional Rail positions |

Not used yet, but available:

- GTFS-realtime vehicle positions (protobuf): `https://www3.septa.org/gtfsrt/septa-pa-us/Vehicle/rtVehiclePosition.pb` (bus/trolley) and `.../septarail-pa-us/...` (rail)
- GTFS-realtime trip updates and alerts, under the same `/gtfsrt/` paths
- SEPTA's static GTFS schedule (routes, stops, shapes)

## Known gaps and risks

- **The app has never been built in Xcode or run on a device.** Nothing here has gone through the iOS SDK. The views, `VehicleStore`, `LocationService`, the Xcode project file and the shared scheme were all written by hand and haven't been compiled. Expect to fix small build errors on first open.
- **What was verified, and how.** Both feeds were fetched live on 2026-11-07 (Saturday, around 6 pm Eastern). Trimmed copies are in `SEPTATrackerTests/Fixtures/`; entries were dropped but no field was edited. `SEPTAClient`, `JSONValues`, `Vehicle` and `TransitMode` were compiled with Swift 6.0.3 on Linux, using stub `CoreLocation`/`SwiftUI` modules. All 11 parser tests passed there, and the full untrimmed capture parsed to 423 vehicles plus 18 trains. The tests have not been run in Xcode.
- **Field names now match a live response, but there's still no spec.** TransitViewAll returns `{"routes":[{"<route>":[…]}]}`. TrainView returns a bare array. Field names and types are documented in `SEPTAClient.swift`. A single weekend-evening capture won't show every variant (for example, null coordinates, or a train with no next stop), so parsing stays lenient.
- **`Offset_sec` was misread before.** It is the schedule deviation in seconds (`Offset_sec / 60 ≈ late`), not how old the GPS report is. Report age now comes from TransitView's `timestamp` field (Unix seconds). TrainView has no timestamp, so trains show no report age.
- **TransitView lists some vehicles twice.** The duplicates have the same vehicle number and position but different trip IDs, destinations and lateness, apparently one for the trip ending and one for the next. 10 of 433 entries were duplicates. The parser keeps the first entry. Whether that's the trip the vehicle is actually running is **unverified**, so destination and lateness for these vehicles may belong to the wrong trip.
- **Trolley detection is by route key and misclassifies bus substitutions.** Route keys seen: T1–T5, G1, M1, `D1_BUS`, `D2_BUS`, plus numeric bus routes and named ones (`BLVDDIR`, `NOR_BUS`, `K`). The old numeric trolley routes (10, 11, 13, 15, 34, 36, 101, 102) didn't appear. T and G1 vehicles include bus-numbered vehicles (for example 3042 on T1, and 3659 and 3398 on G1), which will show as trolleys. M1 (Norristown High Speed Line) is shown as a trolley because there's no separate light-rail mode. `D1_BUS`/`D2_BUS` are shown as buses.
- **Lateness sentinel.** TransitView sends `late: 998` (with `Offset_sec: "0"`) for "no estimate", which was seen twice. 999 wasn't seen. Anything 900 or more is treated as no estimate. Early vehicles have negative values, and `Offset` can be `"-0"`.
- **Subway (Market-Frankford / Broad Street) isn't shown.** These lines aren't in the two JSON feeds used here. The GTFS-RT feed may cover them.
- **Performance at full load is unverified.** The capture had 433 surface vehicles on a Saturday evening. Weekday peak will be higher. Standard `Marker`s are used rather than custom views. If the map lags, cluster markers or show only vehicles inside the visible region.
- **Coverage is thinner than it used to be.** Developers reported fewer buses tracked after the 2024 feed changes. Swiftly's feeds may be more complete but require an agreement.

## Project layout

```
SEPTATracker/
  SEPTATrackerApp.swift      App entry point, injects shared state
  Models/                    Vehicle, TransitMode (bus / trolley / rail)
  Services/                  SEPTAClient (HTTP + parsing), VehicleStore (polling + filters), LocationService
  Support/                   Lenient JSON field readers
  Views/                     Map, vehicle detail sheet, filter sheet
  Assets.xcassets
SEPTATrackerTests/
  SEPTAClientParsingTests.swift  Parser tests (run with ⌘U)
  Fixtures/                  Trimmed live TransitViewAll / TrainView responses
```

## Next steps

1. Build in Xcode, fix any compile errors, and run the tests (⌘U).
2. Capture a weekday-peak response and check for field variants the weekend capture missed.
3. Decide which duplicate entry to keep (compare against the GTFS-RT vehicle feed, which reports the active trip).
4. Draw route lines and stops from SEPTA's static GTFS data.
5. Add arrival predictions for a chosen stop (GTFS-RT trip updates).
6. Show service alerts.
7. Save favorite routes and use them as the default filter.
