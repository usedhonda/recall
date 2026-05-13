# GPS arrival acceleration with location anchors

Task: `recall-29644707-01`  
Date: 2026-05-13 JST

## Task Intent

Add low-cost and OS-level location arrival/departure triggers so recall can POST quickly when the user reaches or leaves configured anchor places, without relaxing existing location accuracy filters.

## Changes

### Phase 1

- Changed `LocationManager.minDistance` from `50m` to `20m`.
- Existing `minSendInterval` remains `15s`.
- Existing foreground/background accuracy filters remain unchanged: foreground `100m`, background `200m`.

### Phase 2

- Added `LocationAnchor` model in `AppSettings` and persisted `[LocationAnchor]` as JSON in `UserDefaults`.
- Added `LocationManager.refreshRegions()`.
- Added `CLCircularRegion` monitoring for saved anchors when location is enabled and authorization is `authorizedAlways`.
- Region enter/exit logs `Region enter: <name>` / `Region exit: <name>`, then calls `forceNextSend()` + `sendCurrentLocationNow()`.
- Region monitoring failures log to `ActivityLogger` and location error history.
- `requestAuthorization()` now requests Always authorization if background location is enabled or at least one anchor exists.
- `stopUpdates()` stops active region monitoring.
- Added minimal Settings UI under Location:
  - anchor list with name, coordinate, radius
  - delete button and swipe action
  - add current location as new anchor
  - name input and radius slider, default `50m`

## Scope Guard

Intentionally not changed:

- Location accuracy filters (`100m` foreground / `200m` background)
- `minSendInterval` / heartbeat interval policy
- `TelemetrySampleBatch` schema / health2 / nowPlaying
- `AudioRecordingEngine`, `AudioSessionManager`, `BackgroundKeepAlive`
- Existing `liveUpdates()` / heartbeat / queue fallback behavior

## Verification

Command:

```bash
~/.claude/apple-dev/bin/ios-build.sh device kana
```

Result:

- Build succeeded.
- App installed on kana.
- App launched on kana.
- Existing warnings only; no new blocking build errors observed.

Runtime region enter/exit requires an anchor configured on-device and physical movement or simulator fake-location testing. The implementation is ready for recall.cc / owner validation.

## Intent Drift Check

Pass. Changes directly implement Phase 1 + Phase 2 arrival acceleration and avoid scope-out areas.
