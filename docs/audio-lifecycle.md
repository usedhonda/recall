# Audio capture lifecycle ownership

Recall uses one shared serial teardown barrier for stop, route, interruption, retry,
and engine replacement. Normal processing finalization is joined by that barrier.
Tap admission is closed under a lock before removing the tap and draining its accepted ring tail;
the drain uses the hardware rate captured when that tap was installed.

Writer, reservation, buffers, and capture metadata are detached before asynchronous
encoding. The queued owner retains them until `finish()` and reservation release have
completed, even if the originating engine is released. A stop invalidates the capture
generation synchronously; VAD, admission, URL generation, and other suspended work must
check that generation before mutating the new lane. New capture waits for old processing
and finalization before resetting the ring or VAD.

Short-chunk policy is unchanged: at most 0.5 s is discarded, below the configured minimum
is held pending, and forced pending finalization discards buffers under 3 s. Encoding or
resampling failures record an explicit audio-original gap; hardware-rate bytes are never
silently presented as valid 16 kHz output.

Deterministic tests cover detached-owner single finish/release, stale admission release,
shared teardown ordering, and accepted-tail/old-tap rejection. These are not evidence
of AVAudioEngine real-time callback deadlines or full on-device interruption behavior.
Those require actual device logs and lifecycle acceptance.
