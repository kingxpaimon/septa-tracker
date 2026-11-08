# Field testing SEPTA Live

Automated tests cover parsing, routing, ride detection (simulated) and alerts timing, but
none of them ride a bus. This checklist is for real trips. When something is off, open the
map menu → **Report a problem…**, describe it, and share the snapshot file. It records what
the app saw (your location, nearby vehicles, feed status, ride state) so the issue can be
reproduced.

## Before you go
- [ ] On Wi-Fi, open the app once and wait ~1 minute (the SEPTA schedule downloads in the background).
- [ ] Allow location ("While Using") and notifications.
- [ ] Map menu → turn on **Detect when I'm riding**.

## At the stop
- [ ] **Nearby** (clock button): does your line show the right stop and direction?
- [ ] Compare the next departure with the stop's sign / SEPTA app / reality. Note "•" (live) vs scheduled.
- [ ] Tap a time → **Remind me 2 min before**. Did the notification arrive at about the right time?
- [ ] Your bus on the map: is the marker where the bus actually is? How far off, roughly?
- [ ] Train: does the route step show the right **Track** and number of **cars**?
- [ ] If two buses arrive together, did both show **Bunched**?

## Planning
- [ ] Directions to a saved place with **Transitous** and with **SEPTA**. Are the suggestions sensible? Which was right?
- [ ] **Arrive by** a time you actually need: did you arrive on time?
- [ ] Route preview map: do the lines follow the real route?
- [ ] "Your bus is waiting at its first stop": if shown, was it true?

## On board
- [ ] Ride banner appears within ~2 minutes of moving? Right vehicle number?
- [ ] Banner stays while riding, goes away within ~3 minutes after you get off?
- [ ] Any false banner while walking, cycling or in a car next to a bus? (Report it.)
- [ ] **Alert me before my stop**: did it fire about 2 minutes before? (With the app closed, it uses the time from when you set it.)

## Record
| Date | Trip | What happened | Expected | Snapshot shared? |
|---|---|---|---|---|
| | | | | |
