# Preserve independent stream intent on launch

Base: `cb4d590396b9eb685302f3a46afa01c3c2fa1023`.

## Finding and change

`RecallApp.startIndependentStreams` replaced saved Location, background Location and Health OFF values with ON, and started the Glasses receiver without reading its saved switch. This contradicted the existing stream-independence contract. Startup now restores each stream without writing its intent. The existing first-install ON behavior is provided by non-persistent defaults; an explicitly stored OFF wins. Retained media uploads continue independently.

Health authorization may suspend while its switch turns OFF. Background-observer registration and the authorization continuation now respect the current intent, and a later explicit ON restores observers after authorization. No stream is gated by another stream or by the audio stop flag.

## Validation

- Passed: existing `scripts/check-contract.sh`; source review of the startup, saved settings, Health authorization and Glasses toggle paths.
- One regression method extends `DurableOffAndChannelAckTests`, covering absent/false/true stored settings without altering the persistent domain while reading. Tests added/removed/consolidated: 1/0/0. Native methods 150 -> 151 in this branch.
- Not run: Xcode build, XCTest, simulator/device authorization and launch checks. The editing host has no Swift/Xcode. The PR remains draft for those checks.
- Required native checks: relaunch with Location/Health/Glasses OFF; turn Health OFF during its authorization wait; turn Health ON again; confirm retained media drains independently.

## Compatibility

No schema or toggle layout changes. Default ON behavior is retained for unset Location/Health keys; stored OFF values survive. Existing already-overwritten intent cannot be reconstructed. No installation, deployment or live data access occurred. Local Silero/FluidAudio inference and provider/API settings are unchanged.
