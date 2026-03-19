const DB_NAME = "recall-web-history";
const STORE_NAME = "entries";
const DB_VERSION = 1;
const MAX_ENTRIES = 1000;

let dbPromise = null;

function requestToPromise(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("IndexedDB request failed"));
  });
}

function transactionDone(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error || new Error("IndexedDB transaction aborted"));
    transaction.onerror = () => reject(transaction.error || new Error("IndexedDB transaction failed"));
  });
}

function openDatabase() {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE_NAME)) {
          const store = db.createObjectStore(STORE_NAME, { keyPath: "key", autoIncrement: true });
          store.createIndex("createdAt", "createdAt", { unique: false });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("Failed to open IndexedDB"));
    });
  }

  return dbPromise;
}

async function trimOverflow(store) {
  const total = await requestToPromise(store.count());
  const overflow = total - MAX_ENTRIES;
  if (overflow <= 0) return;

  await new Promise((resolve, reject) => {
    let removed = 0;
    const cursorRequest = store.openCursor();
    cursorRequest.onsuccess = () => {
      const cursor = cursorRequest.result;
      if (!cursor || removed >= overflow) {
        resolve();
        return;
      }

      cursor.delete();
      removed += 1;
      cursor.continue();
    };
    cursorRequest.onerror = () => reject(cursorRequest.error || new Error("Failed to trim queue"));
  });
}

export async function enqueue(entry) {
  const db = await openDatabase();
  const transaction = db.transaction(STORE_NAME, "readwrite");
  const store = transaction.objectStore(STORE_NAME);
  await requestToPromise(store.add({ entry, createdAt: Date.now() }));
  await trimOverflow(store);
  await transactionDone(transaction);
}

export async function dequeueAll() {
  const db = await openDatabase();
  const transaction = db.transaction(STORE_NAME, "readwrite");
  const store = transaction.objectStore(STORE_NAME);
  const rows = await requestToPromise(store.getAll());

  for (const row of rows) {
    store.delete(row.key);
  }

  await transactionDone(transaction);
  rows.sort((a, b) => a.createdAt - b.createdAt);
  return rows.map((row) => row.entry);
}

export async function count() {
  const db = await openDatabase();
  const transaction = db.transaction(STORE_NAME, "readonly");
  const store = transaction.objectStore(STORE_NAME);
  const total = await requestToPromise(store.count());
  await transactionDone(transaction);
  return total;
}
