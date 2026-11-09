# recall Web History extension

## Delivery queue

A captured entry is committed to IndexedDB before the first network attempt.
Reading a retry batch leaves its rows in storage. Each accepted request removes
only that row's key; a stopped worker, network error or non-2xx response leaves
unacknowledged rows available for the next alarm. Requests send one entry at a
time, including while draining a large backlog.

The existing retention policy remains: newest 1,000 queued entries, and queued
entries older than two hours expire on drain. Activity-display failures cannot
requeue a request already accepted by the server. HTTP success remains the
existing acknowledgment contract. Delivery is at least once: if the server
accepts a request before the worker stops, the same stable entry ID may be sent
again. The receiving plugin deduplicates that ID. The client now bounds fetch
and response-body consumption to 20 seconds.

## Focused browser regression checks

With Node, Playwright and Chromium available:

```sh
node --test chrome-extension/test/queue.browser.mjs
```

Set `RECALL_TEST_CHROMIUM` to an existing Chromium executable if needed. The
fixture serves only these modules over loopback and uses isolated browser
contexts with synthetic entries. It checks IndexedDB retention across page
termination, failed delivery and concurrent rows, retention capacity, and a
controlled response-body timeout. It does not launch the extension, verify
Chrome events or send data to a configured Gateway.
