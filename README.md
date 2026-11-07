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

- **The parser hasn't been tested against live responses.** The field names (`lat`, `lng`, `label`, `late`, `Offset_sec`, `trainno`, `nextstop`, …) come from SEPTA's published examples and community clients. SEPTA has no formal spec and changed these feeds in 2024. Parsing is lenient on purpose: it accepts strings or numbers, alternate key spellings, and skips vehicles without usable coordinates. If the map comes up empty, check the raw JSON first.
- **Trolley detection uses a hand-written list.** TransitView doesn't say whether a vehicle is a bus or a trolley. `TransitMode.trolleyRoutes` lists both the old route numbers and the 2025 metro names (T1–T5, D1/D2, G1). Any route missing from that list is shown as a bus.
- **Subway (Market-Frankford / Broad Street) isn't shown.** These lines aren't in the two JSON feeds used here. The GTFS-RT feed may cover them.
- **Lateness sentinels are guessed.** Values of 900+ minutes are treated as "no estimate".
- **Performance at full load is unverified.** With every mode on, the map can hold around 1,000 markers. Standard `Marker`s are used rather than custom views to keep this manageable. If it lags, cluster markers or show only vehicles inside the visible region.
- **Coverage is thinner than it used to be.** Developers reported fewer buses tracked after the 2024 feed changes. Swiftly's feeds may be more complete but require an agreement.
- **There are no automated tests yet.** The parsers in `SEPTAClient` are static functions over `Data`, so they're ready for XCTest fixtures once real responses have been captured.

## Project layout

```
SEPTATracker/
  SEPTATrackerApp.swift      App entry point, injects shared state
  Models/                    Vehicle, TransitMode (bus / trolley / rail)
  Services/                  SEPTAClient (HTTP + parsing), VehicleStore (polling + filters), LocationService
  Support/                   Lenient JSON field readers
  Views/                     Map, vehicle detail sheet, filter sheet
  Assets.xcassets
```

## Next steps

1. Capture real responses, add them as test fixtures, and fix the parsing to match.
2. Draw route lines and stops from SEPTA's static GTFS data.
3. Add arrival predictions for a chosen stop (GTFS-RT trip updates).
4. Show service alerts.
5. Save favorite routes and use them as the default filter.
