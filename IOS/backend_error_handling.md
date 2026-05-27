# iOS Backend Error Handling

## Error Response Flow

**Backend JSON** → `ResponseError` → `InvokeResult` → `ErrorInfo` → UI

---

## 1. Parsing Layer

### `ResponseError` (`Modules/InvoicesModuleApi/.../Core/ResponseError.swift`)
- `code: String` — the backend error code
- `userDescription: String?` — mapped from JSON field `"message"`
- `info: ErrorInfoPayload?` — optional extra payload (e.g. version info)
- `traceId: String?`

### `ResponseBase<T>` (`Core/ResponseBase.swift`)
Wraps the full response with `success: Bool` and `error: ResponseError?`

### `InvokeResult` (`Core/InvokeResult.swift`)
Result enum:
- `.success(Data?)`
- `.failure(resultCode: String?, title: String?, userMessage: String?, info: ErrorInfoPayload?)`
- `.failedInitilizeRequest`
- Exposes `.errorCode` and `.userMessage` (converts to `ErrorInfo`)

### `ErrorInfo` (`Models/ErrorInfo.swift`)
The app-facing error:
- `code: String?`, `title: String?`, `message: String`, `info: ErrorInfoPayload?`
- Conforms to `LocalizedError`

---

## 2. ALL Error Codes (`ApiErrorType` enum)

File: `Modules/InvoicesModule/.../Models/ApiErrorType.swift`

| Case | Raw Value |
|---|---|
| `unknownSystemError` | `"System_0"` |
| `networkError` | `"System_-1009"` |
| `cancelled` | `"System_-999"` |
| `versionMismatch` | `"version_mismatch"` |
| `invalidReceipt` | `"invalid_receipt"` |
| `notFound` | `"not_found"` |
| `unknown` | `"unknown"` |
| `platformAlreadyTaken` | `"platform_already_taken"` |
| `bannedAccount` | `"banned_account"` |
| `forbidden` | `"forbidden"` |
| `masterNotFound` | `"master_not_found"` |
| `masterDeleted` | `"master_deleted"` |
| `invalidOtpCode` | `"invalid_one_time_password"` |
| `passwordSendForbidden` | `"password_sending_temporary_forbidden"` |
| `failedInitialize` | `"failedInitialize"` |
| `contentIdAlreadyTaken` | `"content_id_already_taken"` |
| `contentNotFound` | `"content_not_found"` |
| `unknownError` | `"0"` |

Fallback: any unrecognized code maps to `.unknownError`.

---

## 3. Where Each Error Code is Handled

### `ApiImplBase.swift` (lines 310-322) — global API layer

| Code | Action |
|---|---|
| `bannedAccount` | Logs server error |
| `masterNotFound` | **Force logout** |

### `AuthServiceImpl.swift` — authentication flows

| Code | Action |
|---|---|
| `masterDeleted` | Special auth error handling (lines 202, 272, 321) |
| `platformAlreadyTaken` | Special auth error handling (lines 208, 278, 327) |
| `invalidOtpCode` | OTP validation failure (line 333) |

### `BaseCommandHandler.swift` (lines 122-150+) — sync commands

| Code | Action |
|---|---|
| `notFound` | Recovery/retry logic |
| `versionMismatch` | Version conflict resolution |
| `networkError` | Network retry logic |
| `contentIdAlreadyTaken` | Duplicate content handling |

### `SyncWorker.swift` (lines 219, 332, 365)

| Code | Action |
|---|---|
| `notFound` | Graceful skip / retry with delay |

### `RestoreServiceImpl.swift` (lines 191-262)

| Code | Action |
|---|---|
| `notFound` | Graceful handling during restore |

### `SubscriptionProcessorImpl.swift` (line 368-369)

| Code | Action |
|---|---|
| `invalidReceipt` | Receipt validation failure |

### `TapToPayServiceImpl.swift` (lines 196-279)

| Code | Action |
|---|---|
| Expired token (int code) | Token refresh |
| `notAvailableTap2payCode` | Tap-to-pay unavailable |

### `ProcessRestoreViewModel.swift` (lines 96-98)

| Code | Action |
|---|---|
| `networkError` | Network error UI feedback |

---

## 4. Additional Error Context (`ErrorInfoPayload`)

File: `Models/ErrorInfoPayload.swift` — carries extra data:
- `.version(VersionInfo)` — for `versionMismatch` errors (contains actual version)
- `.dictionary([String: String])` — generic key-value context
- `.unknown` — fallback

---

## 5. Key Patterns

- **Network errors** are identified by code prefix `"System_-"` (via `isNetworkError` on `ErrorInfo`)
- **User-facing message** always comes from `userDescription` (JSON `"message"` field) via `ErrorInfo.message`
- **Force logout** triggers on `masterNotFound` and `bannedAccount`
- **Version conflicts** carry the actual version in the payload for resolution
- **Unrecognized codes** fall through to `.unknownError` and display the backend's message as-is
