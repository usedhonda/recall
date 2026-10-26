# Hub Connection Diagnostics And One-Time Alerts

## Owner Scope

Make iPhone-side connection/VPN trouble understandable in the app and permit a
notification, but only once for the same continuous outage. Preserve all streams,
retry policies, credentials, and VPN settings. No extra probe or test POST.

## Evidence And Meaning

The connection monitor consumes only natural Hub delivery results. A satisfied
NWPath means a local network path is available, not that the public Internet or
the Hub is reachable. Timeout/DNS/connectivity failures plus that path yield
"Hub unreachable; check Tailscale" rather than "Tailscale is off". Public Network
Extension configuration APIs read the calling app's VPN configurations, not the
separate Tailscale app's state. No new VPN entitlement, profile, or credential is
introduced to bypass that boundary.

Ordinary offline remains distinct. TLS, access rejection, other HTTP statuses,
and unverified receipts have separate in-app explanations. A real HTTP response
proves a response path, not valid authorization, a durable receipt, or new GPS
delivery. No response-body content or private endpoint is displayed or persisted.

## One Alert Per Outage

All lanes share one persisted alert claim. It is recorded before submitting the
non-repeating local notification; relaunch, interface changes, continued failure,
and Internet reconnection do not re-arm it. Only a natural HTTP response resets
the network-outage latch and removes its pending/delivered notice. A stale failure
from a request started before that response cannot reopen the outage. Receipt
validation continues separately and retains unacknowledged data on failure.

iOS notification authorization is required. The first foreground outage can ask
once using the system prompt; background processing never forces a permission
prompt. Config / Network exposes an Enable Connection Alerts button, or links to
the app's notification settings after denial. Lack of permission leaves the
in-app warning and delivery retries working; it never blocks recording or queues.
Authorized foreground notifications are presented as a banner/list without sound.

## Verification

The focused policy tests cover one claim across lanes and JSON reload, no alert
while offline, no re-arm on ordinary reconnection, HTTP-response recovery, stale
request exclusion, a subsequent independent outage, and non-VPN error messages.
The 320-point banner is rendered as a test attachment to check readable wrapping.
Real notification presentation is not established by policy tests or a build;
record authorization and OS delivery separately after device reflection.
