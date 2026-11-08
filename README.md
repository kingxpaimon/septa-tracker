# SEPTA Live

An iOS app that shows where SEPTA buses, trolleys and Regional Rail trains are right now, on a map.

## What's implemented

- **Live map.** Every reporting bus, trolley and Regional Rail train is shown as a map marker, colored by mode. The app refreshes every 20 seconds while it's open and stops when it goes to the background.
- **Vehicle details.** Tap a marker to see its destination, direction, next stop, how late it is, and how old its last GPS report is (when SEPTA provides those fields).
- **Filters.** Turn modes on or off, and narrow the map to specific routes or lines. Routes are searchable.
- **Your location.** The app asks for "when in use" location to show where you are. The locate button (bottom right) works like Apple Maps: tap to center on you and follow, tap again to turn the map with your heading. If location is off, it offers a shortcut to Settings.
- **Map controls.** A map menu switches between Standard, Hybrid and Satellite, toggles traffic and points of interest (remembered between launches), and has "Show all of Philadelphia". There are also a compass, scale and 3D toggle.
- **Dropped pins.** Long-press the map to drop a pin. It shows the street address (Apple's geocoder), with **Directions** (to here), **From here**, **Star**, **Set Home** and **Set Work**. Saved places appear on the map as pins.
- **Keyboard.** A hide-keyboard button floats above the keyboard in the directions and filter screens. Scrolling the list also dismisses it.
- **Readable controls.** The floating map buttons, status bar and top bar use solid backgrounds instead of see-through materials.
- **Nearby.** The clock button opens a list of departures around you, like Transit's main screen. Each line and direction shows its nearest stop (within 500 m), the walk time, and the next three departures in the next 90 minutes as countdowns, with live predictions marked. It refreshes every minute (pull to refresh too), and a map button filters the live map to that line. Built from the on-device SEPTA schedule plus SEPTA's live predictions. On real data it took 0.009 s for 25 lines around City Hall. The schedule downloads in the background on Wi-Fi at launch, so Nearby rarely waits.
- **Alerts** (local notifications, permission asked on first use):
  - "Remind me 2 / 5 / 10 min before" on any departure in Nearby.
  - "Remind me when to leave" for a planned route: 2 minutes before you need to start walking.
  - "Alert me before my stop": 2 minutes before arriving.
  - Departure reminders move with live predictions while Nearby is open. With the app closed, a reminder fires at the last computed time. There's no background tracking, because location is "while using" only.
- **Report a problem.** The map menu creates a JSON snapshot: your note, your location, live vehicles within 1.5 km, feed status and ride state. You share it yourself; the app uploads nothing. See `TESTING.md` for a field-test checklist.
- **Rider details from SEPTA's feeds:**
  - **Trains:** platform/track ("Track 1N", flagged when changed), number of cars, and express service, both on the train and on route steps for your exact train.
  - **Buses:** crowding gauge (empty / many seats / few seats / standing / full) where SEPTA reports it; about 60% of buses in captures had a value.
  - **Bunching:** when two buses on the same route and direction are within 400 m, both show "running with #…". The next bus after them is usually a long wait. Captures had 8 bunched pairs among 393 buses on a Saturday evening and 1 among 194 on a Sunday morning.
  - **"Your bus is waiting at its first stop":** for a planned trip whose bus is parked at its first stop. Only GTFS-realtime reports these buses, and they're kept off the map.
- **App icon:** a white map pin with a bus front on a SEPTA-blue gradient. A vibration confirms when a ride is detected.
- **Ride detection (opt-in, on-device).** Turn on "Detect when I'm riding" in the map menu. While the app is open, it compares your GPS track with live vehicles. When you're moving faster than walking and staying with one specific bus or train across three of SEPTA's reports (at least a minute apart), it shows a banner ("On the 21 · #3686 · 3 min late"). It also moves that vehicle's marker to your phone's position, which is fresher than SEPTA's 30–90 s-old report, and tells you how far behind SEPTA's report is. "Not on it" dismisses a wrong guess. Nothing is stored or sent anywhere.
- **Two SEPTA feeds, merged.** Vehicle positions come from SEPTA's JSON feeds (TransitView/TrainView) and its GTFS-realtime feed. For each vehicle the app uses the newer report, and when TransitView lists a bus twice it picks the trip the bus is actually running. Trains get timestamps. Buses that only GTFS-realtime reports are *not* shown: checked against the schedule, almost none are running a trip (see "Position accuracy"). Positions are never averaged.
- **Directions.** Search for a destination (Apple's place search) or pick a saved place. Choose **Leave now**, **Leave at** a time, or **Arrive by** a time; arrive-by results list the latest departure first. Each option lists lines, times, walking, transfers and live status, and the app can point out *your* bus or train on the live map. Three planners, switchable per search:
  - **Transitous** (default): free community service. Answers in about a second, routes walking along real streets, and includes SEPTA service alerts. Has live bus and trolley data but no live train data.
  - **SEPTA, on the phone:** plans from SEPTA's own schedule with SEPTA's live feed, including train delays. Free and needs no outside service, but the first search downloads and compiles the schedule (about 27 MB, several seconds).
  - **Google** (optional): needs your own API key.
- **Route preview map.** Opening a route shows it drawn on a map. Each ride is in its line's color (rail thicker), walking is a dotted gray line, and there are markers for the start, boarding and transfer stops, the destination, and any live vehicle running your exact trip. Tap to expand to full screen. Transitous routes follow real street and track geometry. On-device SEPTA routes connect stops in order, because SEPTA's 19 MB of route shapes aren't downloaded, and their walks are straight lines. Google routes have no map: Google's terms forbid drawing them on Apple's map.
- **Saved places.** Set Home and Work, and star any other place. Saved places show up as one-tap destinations and as starting points ("From: Work"). Long-press or swipe to change or remove them. Stored on the device only.
- "Open in Google Maps" hands the trip to Google Maps. Its URL can't carry a time, so Google Maps plans for "now".
- **Partial failures.** Bus/trolley data and train data come from separate feeds. If one fails, the other keeps working, and the failing feed shows its last good data plus a warning. If only the GTFS-realtime half of a pair fails, the JSON feed is used alone, and vice versa for buses.

There's no backend and nothing needs a key unless you turn on the optional Google planner. If you use the SEPTA planner, its first search downloads SEPTA's schedule (about 27 MB) and compiles it on the phone. After that it's cached and refreshed weekly.

## Requirements

- macOS with Xcode 15 or newer
- iOS 17+ device or simulator

## Run it

1. Open `SEPTATracker.xcodeproj` in Xcode.
2. Select the `SEPTATracker` target, then open **Signing & Capabilities**.
3. Pick your development team and change the bundle identifier from `com.example.SEPTATracker` to something unique.
4. Choose an iPhone simulator or device and press Run.
5. Run the tests with ⌘U.

## On-device planner

How it works:

1. **Schedule.** `ScheduleStore` downloads `gtfs_public.zip` from SEPTA's GitHub releases (`https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip`). It's an outer zip holding `google_bus.zip` (bus, trolley, subway) and `google_rail.zip`. A built-in zip/DEFLATE reader (`ZipArchive.swift`) unpacks it; iOS has no zip API. `Timetable` compiles stops, trips, calendars and walking transfers (≤400 m) into flat arrays, cached as a ~29 MB binary file in Application Support. The cache is refreshed when it's over 7 days old or its calendars run out. If a refresh fails, the old copy is used with a warning.
2. **Live data.** Each search fetches SEPTA's two GTFS-realtime TripUpdates feeds. Bus updates give predicted times per stop, and the delay carries forward to later stops. Rail updates give one delay per train, which is applied to the whole trip. Canceled trips and skipped stops are excluded. If the feeds fail, results are schedule-only and say so.
3. **Routing.** `TripRouter` runs RAPTOR, a round-based transit routing algorithm. It finds the earliest arrival using 1, 2, 3… rides (up to 5), with up to 900 m of walking at each end. It runs again just after the first departure to find later alternatives, and adds a walk-only option under 1.6 km. It searches yesterday's, today's and tomorrow's service, so trips after midnight work.

Measured on SEPTA's real data, with Swift 6.0.3 on a Linux x86 machine (not a phone):

| | |
|---|---|
| Schedule (feed v202611010) | 13,644 stops, 47,548 trips, 2.8 million stop times, 1,088 patterns |
| Download + unzip + compile | ~4 s (1.6 s download, 2.4 s compile); cache 29 MB, reloads in 0.04 s |
| One search | 0.05–0.4 s |
| Live coverage at one moment (Sat evening) | 801–808 trips with predictions, 37 canceled |
| Live bus delays vs TransitView's own lateness for the same 376 trips | median difference 1 min, p90 1 min |

Sanity check: for 63rd & Lansdowne → Temple University, Monday 8:30 am, it suggested bus 46 → L1 → Warminster Line (40 min), bus 65 → Manayunk/Norristown Line, and T1 → Trenton Line. Transitous, an independent planner, suggested the same three combinations. Nobody has checked the results against riding the routes.

## Transitous planner

[Transitous](https://transitous.org) is a free, community-run routing service built on open transit data and OpenStreetMap. Pick "Transitous" in the directions screen. No key or setup needed.

**Compared with the on-device planner, on a capture from 2026-11-07:**

| | On-device (SEPTA) | Transitous |
|---|---|---|
| Live bus/trolley predictions | Yes | Yes |
| Live Regional Rail | Yes (delays) | **No** (`NO_RT_DATA` on every train checked) |
| Walking | Straight line × 1.25 | Real street network (OSM) |
| Service alerts | No | Yes (shown as route warnings, e.g. T1 shuttle busing) |
| Works offline after first download | Schedule only | No |
| Depends on a third party | No (SEPTA only) | Yes, volunteer-run, best effort |

Transitous trip IDs embed SEPTA's own (`…_us-pa-SEPTA-Bus_968699`), so "your bus is live" matching works for its results too.

**Usage policy — read before publishing.** From https://transitous.org/api/:
- **Non-commercial only.** Apps using the API are expected to be **open source**. This project is licensed under Apache 2.0 (see `LICENSE`). The repository must be public for that to count, and the app code has to be on the default branch for visitors to see it.
- Every request sends `User-Agent: SEPTA-Live/<version> (+https://github.com/kingxpaimon/septa-tracker)` as the required contact.
- The app shows the required link to https://transitous.org/sources/ and an OpenStreetMap credit under Transitous results.
- They flag more than ~720 route searches/day as heavy use. Each search here is one request.
- No guarantees. They can stop serving the app at any time. The on-device planner doesn't depend on them.

## Google planner setup (optional)

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
| GTFS-RT TripUpdates (bus/trolley/subway) | `https://www3.septa.org/gtfsrt/septa-pa-us/Trip/rtTripUpdates.pb` | Live predictions and cancellations for the planner |
| GTFS-RT TripUpdates (rail) | `https://www3.septa.org/gtfsrt/septarail-pa-us/Trip/rtTripUpdates.pb` | Live train delays for the planner |
| SEPTA GTFS schedule | `https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip` | Timetable for the on-device planner |
| Transitous plan API | `https://api.transitous.org/api/v1/plan` | Alternative planner (free, policy applies) |
| Google Routes API (optional) | `https://routes.googleapis.com/directions/v2:computeRoutes` | Alternative planner (needs key) |

GTFS-realtime is decoded by a small hand-written protobuf reader (`GTFSRealtime.swift`), so there's no SwiftProtobuf dependency.

Not used yet, but available:

- GTFS-realtime service alerts, under the same `/gtfsrt/` paths
- Route shapes in the static GTFS (skipped when compiling, to save space)

## Position accuracy: why not average Transit / Google Maps?

The original idea was to average SEPTA bus positions from the Transit app and Google Maps. That isn't done, for three reasons:

- **Neither offers the data.** Google Maps has no public API for live vehicle positions. Transit's API is partner-only.
- **They wouldn't add information.** Both get SEPTA positions from SEPTA's own feeds, so averaging them would mix copies of the same GPS reports.
- **Averaging lags the vehicle.** The copies come from different moments. A moving bus's average lands behind where it actually is.

What the app does instead, measured on a live capture (2026-11-07 ~6:17 pm Eastern):

| | TransitView alone | Merged with GTFS-realtime |
|---|---|---|
| Buses/trolleys only GTFS-realtime reports | — | 87–129 per snapshot, but **2 of 396 were running a trip**; not shown (see below) |
| Duplicate entries resolved by actual trip | 0 of 6 correct (old "keep first" rule) | 6 of 6 |
| Positions replaced by a newer report | — | 4 of 397 (TransitView was usually as new or newer) |
| Trains with a report timestamp | 0 of 18 | 18 of 18 |

So the freshness gain for buses is small. The real wins are choosing the right trip for duplicated buses (8 of 8 checks across captures) and timestamps for trains. For trains, the GTFS-realtime position is always preferred when it matches, because TrainView has no timestamp to compare. In one case, train 4459, TrainView's position was about 6.5 km from the stretch between the two stations it reported itself between, while GTFS-realtime's matched them. That's one example, not a measured error rate.

**Correction: the "extra" buses aren't in service.** An earlier version added buses that appear only in GTFS-realtime and claimed about 30% more coverage. A check of every such vehicle against SEPTA's schedule, on 4 snapshots (Sat 2026-11-07 6:17 pm and Sun 2026-11-08 7:47–7:49 am), found 396 of them:

| What they were doing | Count |
|---|---|
| Waiting at their first stop for a trip that hadn't started | 271 (68%) |
| Finished their trip | 80 (20%) |
| Driving to the start of their next trip | 43 (11%) |
| **Running their trip** | **2 (0.5%)** |

For comparison, 97% of buses that both feeds report were mid-trip, within ~7 m of their route. TransitView leaves the idle buses out on purpose, so the app now does too (`VehicleMerger.mergeSurface(includeRealtimeOnly:)`, off by default). GTFS-realtime's own fields don't separate them cleanly: "stopped at stop 1" also matches 12–27 buses that are about to depart.

## Known gaps and risks

- **Built and tested in Xcode, but not yet used.** On 2026-11-08 the project built with `xcodebuild` for the iOS Simulator (`generic/platform=iOS Simulator`), and `xcodebuild test` passed on an iOS 27.2 "iPhone Duo" simulator. Nobody has opened the app and used it yet: the map, location permission, directions screen and first-run schedule download are unchecked in practice, and it hasn't run on a physical iPhone.
- **What was verified, and how.** SEPTA's JSON feeds and GTFS-realtime feeds were captured live on 2026-11-07, and SEPTA's GTFS schedule (v202611010) was downloaded the same evening. Trimmed copies of the live responses are in `SEPTATrackerTests/Fixtures/`; entries were dropped, nothing edited. `MiniSEPTA.zip` and `MiniTripUpdates-*.pb` are hand-made. All non-UI code (the planner, zip reader, parsers, merger, Google client) was compiled with Swift 6.0.3 on Linux, using stub `CoreLocation`/`SwiftUI` modules. All 83 tests passed there. Disabling live delays or cancellations in the router makes tests fail, so they do check those paths. The planner also ran end to end against the real schedule and live feeds (see "On-device planner"). The tests also pass in Xcode (see above).
- **The optional Google planner has never made a real request.** No API key was available. `GoogleRoutes-Synthetic.json` was written by hand from Google's documentation, and how Google names SEPTA lines is a guess.
- **Live-vehicle matching.** For SEPTA-planned rides, *your* bus is found by trip ID (TransitView's `trip` equals the schedule's `trip_id`) and your train by train number. It's shown only when that vehicle is currently reporting. Otherwise the app falls back to the line's closest vehicle by straight-line distance, which ignores direction.
- **The planner hasn't been checked against reality.** Its routes match an independent planner on one sample trip and look plausible on others, but nobody has ridden them. Known simplifications:
  - Walking is straight-line distance × 1.25 at 1.3 m/s, with no street network, so walks across rivers, rail yards or highways are underestimated.
  - Transfers allow 0 minutes of slack at the same stop, and walking transfers are capped at 400 m.
  - Trips with untimed stops are dropped rather than interpolated (none were seen in SEPTA's feed).
  - No fares, accessibility or bike options, and no "arrive by" searches.
  - Live rail delays are applied to the whole trip, because the rail feed's `stop_sequence` (e.g. 0, 13, 17) didn't line up with the schedule's numbering.
  - One live train carried a weekday trip ID on a Saturday. Predictions for trips the schedule doesn't run that day are ignored.
- **First directions search needs a download.** About 27 MB, on any network (there's no Wi-Fi-only setting), then a few seconds of compiling. Peak memory while compiling is roughly 300 MB (estimated, not measured on a phone), which could be a problem on older iPhones.
- **The schedule URL is SEPTA's GitHub "latest release".** If SEPTA renames the asset or stops publishing there, refreshes fail and the app keeps using its last copy until the calendars run out.
- **Arrive-by on the SEPTA planner is a binary search over departure times**, about 8–12 forward searches (0.16–0.27 s on Linux for real trips). It returns the latest departure that makes it plus up to two earlier ones. It looks back 2 hours, then 4 hours. Longer trips report "no routes".
- **Picking a future time with live data:** live predictions are applied to future searches too, but they only affect trips currently in SEPTA's feed. A trip hours away is effectively schedule-only.
- **Field names now match a live response, but there's still no spec.** TransitViewAll returns `{"routes":[{"<route>":[…]}]}`. TrainView returns a bare array. Field names and types are documented in `SEPTAClient.swift`. A single weekend-evening capture won't show every variant (for example, null coordinates, or a train with no next stop), so parsing stays lenient.
- **`Offset_sec` was misread before.** It is the schedule deviation in seconds (`Offset_sec / 60 ≈ late`), not how old the GPS report is. Report age now comes from TransitView's `timestamp` field (Unix seconds). TrainView has no timestamp, so trains show no report age.
- **TransitView lists some vehicles twice.** The duplicates have the same vehicle number and position but different trip IDs (10 of 433 entries in one capture, 6 of 399 in another). GTFS-realtime's `trip_id` says which trip is active, and that's used when available. It was always the entry with non-zero lateness; the `late: 0` entry is the next trip. When GTFS-realtime is unavailable, the app falls back to preferring the late entry. (The previous "keep the first entry" rule was wrong in every observed case.)
- **Idle buses are hidden.** Buses only GTFS-realtime reports are left off the map, because almost all are waiting for or done with a trip. That could hide a rare genuinely running bus (2 of 396 in the check).
- **Regional Rail matching relies on a trip-ID pattern.** GTFS-realtime rail trip IDs looked like `PAO9566_20261019_SID189798`, and the digits after the line code matched TrainView's `trainno` for all 18 trains. One train can appear under two trip IDs at the same position. Trains only in GTFS-realtime aren't added, because its line codes (`PAO`, `TRE`) don't map cleanly to TrainView line names.
- **Trolley detection is by route key and misclassifies bus substitutions.** Route keys seen: T1–T5, G1, M1, `D1_BUS`, `D2_BUS`, plus numeric bus routes and named ones (`BLVDDIR`, `NOR_BUS`, `K`). The old numeric trolley routes (10, 11, 13, 15, 34, 36, 101, 102) didn't appear. T and G1 vehicles include bus-numbered vehicles (for example 3042 on T1, and 3659 and 3398 on G1), which will show as trolleys. M1 (Norristown High Speed Line) is shown as a trolley because there's no separate light-rail mode. `D1_BUS`/`D2_BUS` are shown as buses.
- **Lateness sentinel.** TransitView sends `late: 998` (with `Offset_sec: "0"`) for "no estimate", which was seen twice. 999 wasn't seen. Anything 900 or more is treated as no estimate. Early vehicles have negative values, and `Offset` can be `"-0"`.
- **Ride detection is not crowdsourcing yet.** It runs on your phone and improves only your own map. Sharing confirmations between riders would need a server (collecting anonymous "vehicle at point, time" reports), explicit opt-in consent, a privacy policy and App Store privacy labels. None of that exists. Detection runs only while the app is open; background detection would need "Always" location permission.
- **Ride detection is tested on simulated tracks only.** Its thresholds haven't been checked on real rides: about 9 mph, 120 m for buses, 250 m for trains, 3 reports spanning ≥60 s, ending after 150 s without a match. Known weak spots:
  - A cyclist or car keeping pace with a bus for a minute or more can be mistaken for a rider.
  - Two buses running together stay ambiguous; no ride is shown.
  - Trains without a GTFS-realtime timestamp match only if TrainView's position is fresh.
  - A rider who boards with the app already open can take 1–2 minutes to be detected.
- **Subway isn't on the live map.** The L and B lines aren't in the vehicle feeds used here. The planner does route on them from the schedule (`L1`, `B1` and others), without live data.
- **Performance at full load is unverified.** The capture had 433 surface vehicles on a Saturday evening. Weekday peak will be higher. Standard `Marker`s are used rather than custom views. If the map lags, cluster markers or show only vehicles inside the visible region.
- **Coverage.** No evidence that TransitView misses buses on a trip; the earlier "about a quarter" claim was wrong (see the correction above). Whether either feed misses buses outright hasn't been measured.

## Project layout

```
SEPTATracker/
  SEPTATrackerApp.swift      App entry point, injects shared state
  Models/                    Vehicle, TransitMode (bus / trolley / rail)
  Services/                  SEPTAClient (HTTP + JSON parsing), GTFSRealtime (protobuf), VehicleMerger,
                             GoogleRoutesClient, TransitousClient, LiveLineMatcher, TripPlanner/PlaceSearch,
                             VehicleStore (polling + filters), LocationService
  Planner/                   On-device routing: CSVReader, Timetable (compile + cache),
                             LiveDelays (TripUpdates), TripRouter (RAPTOR), ScheduleStore (download/cache)
  Support/                   Lenient JSON field readers, zip/DEFLATE reader
  Views/                     Map, vehicle detail sheet, filter sheet, directions, route detail
  Assets.xcassets
SEPTATrackerTests/
  SEPTAClientParsingTests.swift  Parser tests (run with ⌘U)
  VehicleMergerTests.swift   GTFS-realtime decoding and merging
  GoogleRoutesTests.swift    Routes request/parse, live line matching
  PlannerTests.swift         Zip, timetable compile, RAPTOR (leave at / arrive by), live delays, exact-vehicle matching
  SavedPlacesTests.swift     Home/Work/starred storage
  RideDetectorTests.swift    Ride detection on simulated GPS tracks
  RiderInsightsTests.swift   Track/cars/crowding parsing, bunching, waiting-bus matching
  NearbyAndAlertsTests.swift Nearby departures (incl. live/cancellations/after midnight), alert timing, diagnostics
  TransitousTests.swift      Transitous request/parse (real response fixture)
  Fixtures/                  Trimmed live SEPTA responses; MiniSEPTA.zip, MiniTripUpdates-*.pb and
                             GoogleRoutes-Synthetic.json are hand-made
Config/
  App.xcconfig               Base settings; includes the gitignored Secrets.xcconfig
```

## Next steps

1. Run the app (⌘R): check the live map, saved places, leave-at/arrive-by, and a search with each planner.
2. Try directions on a real phone: whether the suggested routes make sense, and the SEPTA planner's first-run download time and memory use.
3. Draw the chosen route on the live map (allowed for SEPTA and Transitous data, not Google's).
4. Use street-network walking times in the SEPTA planner (e.g. MapKit walking ETAs for the first and last legs).
5. Show SEPTA service alerts outside Transitous results (GTFS-realtime Alerts).
6. Save favorite routes and use them as the default map filter.
7. If keeping Google: capture a real Routes API response and check the current Google terms.
8. Consider linking Transitous's donation page.

## License

Copyright 2026 kingxpaimon. Licensed under the [Apache License, Version 2.0](LICENSE).

Data used at runtime keeps its own terms: SEPTA's feeds, and for the optional planners, Transitous's data sources and OpenStreetMap (ODbL) or Google Maps Platform.
