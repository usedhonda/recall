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

## Device Reflection

Commit `57290dc` was installed once and immediately launched without activation
at 12:57:17.631064Z-12:57:20.133091Z, after a fresh unlocked Listening snapshot
with no open chunk (2.502-second operation window, not a gap-free claim).
The process remained Listening at 12:58:22Z. Natural GPS transport timed out
at 12:57:52Z, and the persisted connection state classified it as unreachable
with code -1001, no HTTP response, and no notification claim.

This proves runtime classification and persistence, not a shown OS notification.
Notification authorization/presentation remains unverified; the system permission
and the Config action are separate from recording and retry progress. The natural
transport failure itself is still unresolved, with no new verified Hub receipt.

## On-Device Request Diagnostics

Following the owner's report that notification authorization did not resolve the
error, the app records the last 20 natural Hub requests and displays the latest
five under Config / Network / Hub Connection Diagnostics. Each record contains
request time, HTTP status or fixed URL loading code, last reported URLSession
transaction phase, DNS/connect/TLS durations when provided, and reuse/proxy flags.
Missing metrics stay unknown; a phase timestamp is evidence of progress, not proof
that a later phase failed. Request metrics and completion merge by a local ID
regardless of callback order, and the bounded records survive relaunch.

The endpoint is represented only by SHA-256 of the configured HTTPS URL with its
optional trailing root slash removed, matching the deployment operator's existing
comparison method. No URL, address, credential, request/response body, or header
is recorded. No probe, manual POST, retry, VPN change, or new listener is added.
The per-task delegate preserves the existing redirect prohibition.

The device build passes. The Simulator test launch entered simulator diagnostics
without executing assertions and was interrupted; it is not reported as a test
pass. The owner explicitly selected Kana for the incident investigation. Acceptance
therefore uses the normal Kana app's natural requests, not a hosted test runner
that would take over its recording process.

The diagnostic candidate `686a79b` was reflected on Kana in an unlocked Listening
window with no open chunk, installing and immediately launching without activation
at 13:18:45.453711Z-13:18:47.682496Z (2.229 seconds, not gap-free).
Natural requests persisted real timeout records. Their configured endpoint hashes
match the existing Hub deployment fingerprint. iOS reported transaction metrics
without DNS/connect/TLS/request/response timestamps, so the recorded phase is
`not_reported`; do not reinterpret missing timestamps as a specific network failure.

USB screen capture and official developer application launch were verified on Kana.
The actual recall warning was observed while its recording remained Listening.
Opening the already installed Tailscale app showed its switch ON and status
"Starting..." in the settled screen, not Connected. This preserves the owner's
VPN-on observation while distinguishing switch intent from a working tunnel.
No VPN/account/profile setting was changed. Mac iPhone Mirroring still requested
Mac authentication for UI control; only that operation depends on owner Touch ID.
Do not block code work or diagnostic reads behind that local UI boundary.

## Transient Retry Versus Sustained Outage

After connectivity recovery, the owner observed an error appear and disappear.
The same log window contains isolated connection-lost/timeout failures and many
verified receipts. For example, a status request timed out at 15:52:02Z, another
request returned HTTP 201 at 15:52:03Z, and the status lane verified a receipt at
15:52:07Z. These are not asserted to be the same request. A post-clear screenshot
and persisted state show no current global connection issue.

The earlier policy could promote one failed upload into a global red Hub warning
until another response cleared it. The corrected policy uses an actual HTTP
response within the existing 60-second resource-timeout window as positive path
evidence: an isolated route failure then shows amber RETRYING UPLOAD, without an
outage notification. A failure with no recent response still shows the red outage
and retains the persisted one-alert claim. Initial no-response outages, TLS,
authorization, receipt verification, and storage errors keep their prior meaning.

Retryable transport failures are recorded as network retry entries, not terminal
red error entries. Their codes and retained status remain in diagnostics; past
error history is not rewritten or deleted. Delivery failures still retain the
original and return failure to the worker, with no change to retry/ACK behavior.

This correction is candidate `fb3ba9c`. The actual pure policy source passes its
native regression for transient retry/no alert, stale failures, sustained outage
once, persistence/relaunch, authorization distinction, and initial outage. The
device build and Simulator compile-only test build pass, without a test runner
or deliberate network disruption.

It was installed once and immediately launched without activation from
16:05:35.128437Z to 16:05:37.727868Z, preserving the owner's audio-OFF intent.
Post-launch diagnostics contain HTTP 201 successes with no current global issue
or claimed notification, and the audio flags remain OFF/user-stop. No transient
fault was induced merely to obtain a screenshot; the transient display branch is
verified by the policy regression rather than falsely claimed as observed live.
