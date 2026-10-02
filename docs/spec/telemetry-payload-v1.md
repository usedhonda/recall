# Telemetry Payload Spec v1 (Self-Describing Health Records)

> **Status**: v1.0 — recall iOS 側実装完了 (commit `44dd6f5` 時点で kana にデプロイ済み)
> **Owner (sender side)**: recall iOS (`~/projects/ios/recall/`)
> **Audience**: VoiceLog / OpenClaw (`/api/telemetry` 受け側)
> **目的**: HealthKit / Location / NowPlaying 等の telemetry を「**self-describing record**」として送信し、サーバー側が古さ・出所・単位・集計区間を完全に判定できる状態にする

---

## 1. Endpoint

```
POST {server_base}/api/telemetry
Authorization: Bearer <token>
Content-Type: application/json
User-Agent: recall-ios/1.0
```

- `{server_base}`: `AppSettings.telemetryServerURL` (実運用では **Gateway `http://mac-mini.tailnet:18789`** を指す。auto-migrate ロジックで `:8765` → `:18789` 置換あり)
- TLS 不要 (Tailscale WireGuard で暗号化済み)
- 認証: Bearer token (Keychain 管理)

### 1.1 Current routing (verified 2026-10-02)

Recall sends telemetry to Gateway `/api/telemetry`; audio remains on VoiceLog
`/ingest`. Gateway materialized location/health/Wi-Fi/geofence state is mirrored to
the independent Personal Data Hub every 60 seconds. This is not full raw-event
capture or a Recall producer cutover. VoiceLog originals/transcripts use a separate
five-minute mirror. Consumer delivery must be verified separately from HTTP receipt.

The old `vibeterm-telemetry` plugin name and the former Phase 3 proposals were historical
implementation notes, not a current migration instruction. Server runtime ownership and
cutover rules are in oc-general's `docs/contracts/personal-realtime-data.md`.

---

## 2. Request Body 全体

```jsonc
{
  "samples":    [...],   // Location samples (既存 — section 3 参照)
  "health":     {...},   // 旧 HealthSummary 形式 (deprecated, 互換期間中)
  "health2":    {...},   // 新 HealthPayload (本仕様の主役 — section 4 参照)
  "nowPlaying": {...}    // 既存 NowPlayingSnapshot (省略可)
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `samples` | array | yes (空配列可) | Location samples。background queue 経由含め batch 送信 |
| `health` | object \| null | no | Legacy HealthSummary; retained for compatibility, no removal scheduled |
| `health2` | object \| null | no | 新 HealthPayload。**本仕様で server 側が主に扱うフィールド** |
| `nowPlaying` | object \| null | no | 直近の NowPlaying スナップショット (再生中曲・ポッドキャスト等) |

---

## 3. Location Samples (既存 + quality 追加)

```jsonc
"samples": [
  {
    "id": "UUID",
    "lat": 35.6895,
    "lon": 139.6917,
    "accuracy": 5.0,
    "altitude": 30.0,        // optional
    "speed": 1.2,            // optional (m/s)
    "timestamp": "2026-04-28T11:30:00Z",
    "quality": "good",       // ★ v1 で新規追加 — "good" / "approx" / null
    "wifi": "home"           // ★ 追加 — "home" / "away" / null (端末側で導出)
  }
]
```

| Field | Type | 必須 | 意味 |
|---|---|---|---|
| `id` | string (UUID) | yes | クライアント生成、dedupe 用 |
| `lat` / `lon` | number | yes | 緯度経度 (WGS84) |
| `accuracy` | number | yes | 水平精度 (meters) |
| `altitude` | number | optional | 高度 (meters) |
| `speed` | number | optional | 移動速度 (m/s) |
| `timestamp` | ISO8601 (UTC) | yes | 取得時刻 |
| `quality` | string \| null | optional | `LocationManager.qualityFor` 由来。`"good"` = 通常精度、`"approx"` = reduced-accuracy fix、`null` = 判定不能 |
| `wifi` | string \| null | optional | `"home"` / `"away"` / `null`。ユーザー設定の home SSID から**端末側で導出**した状態。生 SSID は送信されない (`ConnectivityMonitor.wifiContext` 由来)。GPS が source of truth、Wi-Fi は補強のみ |

**サーバー側の活用**:
- `quality = "approx"` の sample は accuracy が大きく劣化している可能性。集計・地図表示時に warning 出すか、別レイヤーに分離するか判断材料にできる

---

## 4. HealthPayload (本仕様の主役)

### 4.1 Envelope

```jsonc
"health2": {
  "collectedAt": "2026-04-28T11:30:00Z",   // recall が aggregateHealthData を呼んだ時刻
  "records":  [...],   // section 4.2 — 各 metric の最新 1 record
  "sleep":    {...},   // section 4.3 — 睡眠サマリ + segments
  "workouts": [...]    // section 4.4 — workout sessions
}
```

| Field | Type | 必須 | 意味 |
|---|---|---|---|
| `collectedAt` | ISO8601 (UTC) | yes | recall がデータ集計を実行した時刻。**個々の record の `measuredAt` とは別物**。古さ判定の基準にしないこと |
| `records` | array of HealthRecord | yes (空配列可) | 各 metric につき最新 1 件。順序保証なし |
| `sleep` | object \| null | optional | 直近 24h の睡眠サマリ |
| `workouts` | array | optional | 直近 24h の workout セッション |

### 4.2 HealthRecord

```jsonc
{
  "metricId":         "HKQuantityTypeIdentifierBodyMass",
  "value":            65.3,
  "valueText":        null,
  "valueMin":         null,
  "valueMax":         null,
  "unit":             "kg",
  "aggregation":      "latest",
  "measuredAt":       "2026-04-15T07:30:00Z",
  "intervalStart":    null,
  "intervalEnd":      null,
  "sampleCount":      null,
  "source":           "Health",
  "sourceBundleId":   "com.apple.Health",
  "deviceModel":      null
}
```

| Field | Type | 必須 | 意味 |
|---|---|---|---|
| `metricId` | string | **yes** | HealthKit identifier 原文 (`HKQuantityTypeIdentifierBodyMass` 等)。マッピング table を持つ場合は原文をキーにする |
| `value` | number | yes (categorical 以外) | 数値。単位は `unit` 参照 |
| `valueText` | string | optional | category sample 用 (sleep stage 文字列等)。今回の records では未使用 |
| `valueMin` | number | optional | `aggregation = "discreteStats"` の最小値 |
| `valueMax` | number | optional | `aggregation = "discreteStats"` の最大値 |
| `unit` | string | **yes** | HealthKit 慣例: `kg` / `count` / `count/min` / `kcal` / `m` / `%` / `degC` / `ms` |
| `aggregation` | string | **yes** | `"latest"` / `"cumulativeSum"` / `"discreteAvg"` / `"discreteStats"` / `"category"` |
| `measuredAt` | ISO8601 (UTC) | **yes** | `latest` なら `HKSample.endDate`、集計なら `intervalEnd` と同値 |
| `intervalStart` | ISO8601 (UTC) | sum/avg/stats のみ必須 | 集計区間の開始 |
| `intervalEnd` | ISO8601 (UTC) | sum/avg/stats のみ必須 | 集計区間の終了 (= `measuredAt`) |
| `sampleCount` | integer | sum/avg/stats のみ必須 | 集計に使った sample 数 (※ 注意: §6 参照) |
| `source` | string | optional | `HKSource.name` (例: `"Health"` / `"Apple Watch"` / `"ISSIN Smart Recovery Ring"`) |
| `sourceBundleId` | string | optional | `HKSource.bundleIdentifier` (例: `"com.apple.Health"` / `"cc.issin.sbm"`)。**routing / filtering には bundleId を使うこと** (表示名は変わる) |
| `deviceModel` | string | optional | `HKDevice.model` (例: `"Watch"` / `"iPhone"`)。手動入力は null |

### 4.3 Sleep

```jsonc
"sleep": {
  "total":  432,         // 合計睡眠分数
  "rem":    78,
  "deep":   64,
  "core":   248,
  "awake":  42,
  "segments": [          // ★ v1 新規 — 各 sleep session の詳細
    {
      "start":          "2026-04-27T22:30:00Z",
      "end":            "2026-04-28T06:42:00Z",
      "stage":          "asleepCore",
      "source":         "ISSIN Smart Recovery Ring",
      "sourceBundleId": "cc.issin.sbm",
      "deviceModel":    null
    }
  ]
}
```

`stage` の取り得る値:
- `"asleepREM"` / `"asleepDeep"` / `"asleepCore"` / `"asleepUnspecified"`
- `"awake"` / `"inBed"`

### 4.4 Workouts

```jsonc
"workouts": [
  {
    "activityType":    "running",     // HKWorkoutActivityType の文字列名
    "durationSeconds": 1845.0,
    "energyKcal":      215.4,         // optional
    "distanceMeters":  4820.0,        // optional
    "start":           "2026-04-28T07:00:00Z",
    "end":             "2026-04-28T07:30:45Z",
    "source":          "Apple Watch",
    "sourceBundleId":  "com.apple.health",
    "deviceModel":     "Watch"
  }
]
```

`activityType` 例: `"running"` / `"walking"` / `"cycling"` / `"yoga"` / `"functionalStrengthTraining"` 等 (HKWorkoutActivityType の name で十分)

---

## 5. 対象 Metric 一覧 (recall が現状送るもの)

### Cumulative Sum 系 (24h 積算 — `intervalStart/End` あり)

| metricId | unit | 想定 source |
|---|---|---|
| `HKQuantityTypeIdentifierStepCount` | `count` | Apple Watch / iPhone |
| `HKQuantityTypeIdentifierActiveEnergyBurned` | `kcal` | Apple Watch |
| `HKQuantityTypeIdentifierBasalEnergyBurned` | `kcal` | iPhone (BMR estimate) |
| `HKQuantityTypeIdentifierDistanceWalkingRunning` | `m` | Apple Watch / iPhone |
| `HKQuantityTypeIdentifierFlightsClimbed` | `count` | iPhone barometer |

### Discrete Average 系

| metricId | unit | 集計 |
|---|---|---|
| `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | `ms` | discreteAvg |
| `HKQuantityTypeIdentifierRespiratoryRate` | `count/min` | discreteAvg |

### Discrete Stats 系 (avg/min/max)

| metricId | unit | フィールド |
|---|---|---|
| `HKQuantityTypeIdentifierHeartRate` | `count/min` | `value` (avg) + `valueMin` + `valueMax` |

### Latest 系 (最新 1 サンプル — lookback 制限なし)

| metricId | unit | 想定 source |
|---|---|---|
| `HKQuantityTypeIdentifierRestingHeartRate` | `count/min` | Apple Watch / Smart Ring |
| `HKQuantityTypeIdentifierOxygenSaturation` | `%` | Apple Watch / Smart Ring |
| `HKQuantityTypeIdentifierBodyMass` | `kg` | 手動 / スマート体重計 |
| `HKQuantityTypeIdentifierBodyFatPercentage` | `%` | スマート体重計 / 手動 |
| `HKQuantityTypeIdentifierLeanBodyMass` | `kg` | スマート体重計 |
| `HKQuantityTypeIdentifierBodyMassIndex` | `count` (BMI 値) | 計算値 / 手動 |
| `HKQuantityTypeIdentifierBodyTemperature` | `degC` | 体温計 / 手動 |
| `HKQuantityTypeIdentifierAppleSleepingWristTemperature` | `degC` | Apple Watch |

**重要 — latest 系の `measuredAt`**:
- recall は **lookback window を撤廃** (`Date.distantPast`〜現在)。半年前のサンプルでも値として乗る
- サーバー側で「24h / 1週間 / 1ヶ月」の鮮度フィルタが必要なら、`measuredAt` を見て判断すること
- 古い値が来ていても recall 側のバグではない (HK にそれしかない or ご主人様が長期間測ってない)

---

## 6. Provenance の信頼度 (重要)

`source` / `sourceBundleId` / `deviceModel` の精度は aggregation 種別で異なる。

| aggregation | source 信頼度 | sampleCount |
|---|---|---|
| `latest` | **権威ある値** (該当 sample の writer がそのまま) | 常に null |
| `category` (sleep segment / workout) | **権威ある値** | 常に null |
| `cumulativeSum` / `discreteAvg` / `discreteStats` | **representative 扱い**: 区間内の **最新 1 sample** の writer のみ取得 | 常に **null** |

**aggregate 系の制約 (recall 側意図)**:
- HR 24h で数千 sample を `HKObjectQueryNoLimit` で読むのは battery / latency 的にコスト大 → `limit: 1, sortDescriptors: [endDate desc]` で最新 1 件のみ取得
- 結果として `sampleCount` は aggregate では送れない (常に null)
- 同一区間に Apple Watch + iPhone + サードパーティ app が混ざっていた場合でも source は 1 つしか返らない

**「区間中にどのデバイスがどれだけ寄与したか」を server 側で詳細に知りたい場合は、別途 backfill API を設計する** (現 spec のスコープ外)

---

## 7. 送信タイミング

| トリガー | 主な内容 |
|---|---|
| アプリ起動時 | `queryAndSendFull()` (24h lookback) |
| 15 分補助タイマー | `queryAndSend()` (sendInterval lookback) |
| HK observer wake | 60s debounce で `queryAndSend()` (低頻度 metric の background 更新) |
| Location upload (background queue) | LocationSample batch + 直近 nowPlaying snapshot |

- 送信パスは前景 (`TelemetryService.sendHealth`) と背景 (`TelemetryUploader` 経由) の 2 系統あり、いずれも `health` + `health2` を並列で詰めて POST する
- iOS 側の重複・throttle 制御は recall が担う (server 側は受信都度処理して OK)

---

## 8. Migration status (2026-10-02)

The historical A/B/C/D routing alternatives are superseded by the current Hub contract.
Keep the Gateway telemetry and VoiceLog audio routes intact. Do not remove legacy health
fields or repoint the client merely because the Hub accepts a test event. Per-route live
acceptance must prove committed storage, provenance/freshness, scoped readback, required
consumer delivery, and rollback before cutover. Current Hub GPS/health state snapshots
prove mirror activity, not exhaustive receipt of every original sample.

---

## 9. 受信側のデータ判定ガイド

ご主人様要件「使い方は server 側の判断」に応えるため、server は以下を判定可能:

| やりたいこと | 使うフィールド |
|---|---|
| 古いデータか判定 (24h 以内 / 1 週間 / 1 ヶ月) | `measuredAt` |
| 手動入力か実測か | `source` (`= "Health"` は iOS 健康アプリ手動)、または `sourceBundleId = "com.apple.Health"` |
| 集計区間か単発測定か | `aggregation` |
| どのデバイスか (routing / preferred source 選定) | **`sourceBundleId`** (表示名 `source` は変わるので使わないこと) |
| 体重を日報に載せるか | `metricId = "HKQuantityTypeIdentifierBodyMass"` の `measuredAt` を見て、N 日以内のみ採用 |
| 心拍は Smart Ring / Watch どちら優先か | `sourceBundleId` で分離して任意のロジックで選定 |

---

## 10. 単位表記

HealthKit `HKUnit` を使った文字列で送信:

| metric 種別 | unit string |
|---|---|
| body mass / lean body mass | `kg` |
| steps / heart rate | `count` / `count/min` |
| energy | `kcal` |
| distance | `m` |
| oxygen / body fat | `%` (0-100, **0-1 ではない**) |
| temperature | `degC` |
| HRV SDNN | `ms` |

server 側で単位変換が必要な場合 (例: lbs 表示) は `unit` を見て変換すること。

---

## 11. recall iOS 側 実装ファイル参照

| 役割 | ファイル |
|---|---|
| Payload 構造定義 | `recall/Models/HealthSummary.swift` (`HealthRecord` / `HealthPayload` / `SleepSegment`) |
| Telemetry batch 構造 | `recall/Models/TelemetryModels.swift` (`TelemetrySampleBatch` / `TelemetrySample`) |
| HK 取得 + payload 組立 | `recall/Core/Health/HealthKitManager.swift` (`aggregateHealthDataPair`) |
| 前景 POST | `recall/Core/Telemetry/TelemetryService.swift` (`sendHealth`) |
| 背景 POST | `recall/Core/Telemetry/TelemetryUploader.swift` (`upload` / `uploadImmediate`) |
| Location quality 判定 | `recall/Core/Location/LocationManager.swift` (`qualityFor`) |

---

## 11.1 Receiver implementation authority

Locate the deployed Gateway receiver through the current server checkout/runtime; do not
use historical extension directory names as deployment paths. The server contract is
oc-general's `docs/contracts/personal-realtime-data.md`. Recall's existing payload shapes
remain unchanged in this accounting update.

---

## 12. 関連プラン / ログ

- 本仕様の元プラン: `~/.claude/plans/tender-sniffing-goblet.md`
- recall 側実装 commit: `44dd6f5`, `637a71a`, `124609c`, `c1fb425`, `0b9462e`, `90d4db4`
- 仕様書改版: `f316ffb` (v1 初版), `9188dcb` (Gateway 実態反映 + Phase 3)
