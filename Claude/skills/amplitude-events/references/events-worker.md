# Field Service Worker app — Amplitude events catalog

- Vendor/SDK: Amplitude (via `AmplitudeSender` expect/actual; Android/iOS native SDK). Firebase analytics present but hard-disabled (`AnalyticsReporterImpl.IS_FIREBASE_ENABLED = false`).
- Central send point: `sharedUI/.../analytics/AnalyticsReporterImpl.kt:18` — `override fun report(title: String, params: Map<String, Any>?)`; the app-side hub is `core/analytics/.../storage/AnalyticsManager.kt:210` — `private fun reportEvent(title: String, params: Map<String, Any?>? = null)`.
- Identity (user_id): worker's own `masterUserId` — set in `AnalyticsReporterImpl.updateUserId` (`AnalyticsReporterImpl.kt:51-53`, `amplitude.setUserId(params["user_id"])`); value produced at `AnalyticsManager.kt:222` → `AnalyticsDepsImpl.getCurrentUserUID()` (`AnalyticsDepsImpl.kt:101-103`) = `userCenter.awaitUserData()?.takeIf{isUserValid}?.masterUserId`.

## Standard params (every event, injected by `reportEvent`, `AnalyticsManager.kt:215-248`)

| prop | provenance |
|------|------------|
| (getStandardParams) | `standard` — `AnalyticsDepsImpl.getStandardParams()` returns **empty map** (`AnalyticsDepsImpl.kt:86-88`); contributes nothing |
| `network_connected` | `client:connectivity` — `AnalyticsDepsImpl.isNetworkConnected()` (connectivity status flow) |
| `current_screen` | `computed:navigation` — last entry of nav back stack `.toTitle()` (`AnalyticsDepsImpl.kt:96-98`) |
| `current_screens_sequence` | `computed:navigation` — nav back-stack titles joined (`AnalyticsDepsImpl.kt:90-94`) |
| `full_screens_flow` | `computed:screenTracking` — `AnalyticsManager.screenSequence` list joined (accumulated in `onScreenOpen`) |
| `user_id` | `client:userCenter` — worker `masterUserId` (`getCurrentUserUID`, `AnalyticsDepsImpl.kt:101-103`) |
| `account_id` | `bff:/api/worker/businesses → businesses[0].accountId` — `getCurrentAccountID` → `AccountsCenter.getAccountId()` reads cached `BusinessesDto` from `AccountStorage` (`AccountsCenter.kt:31-34`), fetched from BFF `WorkerApi.getBusinesses()` |
| `is_first_app_launch` | `client:persisted` — `startAnalyticsInfo.isFirstLaunch` from persisted `AnalyticsInfo` (settings) |
| `is_first_login` | `client:userCenter` — `isPreviousUserExist().not()` (`previousUserDataFlow == null`) |
| `event_id` | `computed:randomUUID` |
| `previous_event_id` | `computed:lastEventId` (previous event's `event_id`; default `"no_previous_event"`) |
| `event_time` | `computed:now().toISO8601()` |
| `feature_location` | `client:remoteConfig` — `remoteConfig.get(KEY_LOCATION_PERMISSIONS)` |
| `platform` | `client:platformConfig` — `getPlatformType()` = `platformConfigProvider.osType` |
| `jobs_completed` | `client:db` — `JobsRepository.count("completed")` flow (`AnalyticsManager.kt:76-78`, local DB synced from server) |
| `business_industry` | `bff:/api/Account/business-profile → industry` — `getBusinessIndustry()` reads cached `BusinessesProfileDto.industry` from `AccountStorage`; lazily fetched via `WorkerApi.getBusinessesProfile()` (`AnalyticsDepsImpl.kt:123-130`, `BusinessProfileUpdater`) |
| `os` | `client:platform` — added in `AnalyticsReporterImpl.report` (`:22-23`), `amplitude.getOS()` = literal `"Android"`/`"iOS"` |
| `is_first_event` | `computed` — added in `report` call tail (`AnalyticsManager.kt:256-258`): `happenedEvents.contains(event.hashKey()).not()` |
| `locationManager_hasSystemPermissions` | `client:locationManager` — only when `feature_location != false` (`AnalyticsManager.kt:234-247`) |
| `locationManager_isStarted` | `client:locationManager` — same guard |
| `locationManager_latitude` | `computed:locationManager` — `"value_hidden"` if present else `"not exist"` (value masked) |
| `locationManager_longitude` | `computed:locationManager` — `"value_hidden"` if present else `"not exist"` |

Note: `null`-valued params are stripped before send (`AnalyticsManager.kt:251`). `getStandardParams()` is a no-op empty map on this platform.

- Definition style: typed `onXxx(...)` methods on `AnalyticsManager` each call the private `reportEvent(title, mapOf(...))`, which merges the event-specific props with the standard params block above and forwards to `AnalyticsReporter.report`. A few methods map to the same string title (e.g. `Page Shown`, `Onboarding Screen Shown`) with different prop sets; two job/logout methods branch to different titles.

## Events

### `Photo Added`
- Fired via: `AnalyticsManager.onPhotoAdded(...)` at `AnalyticsManager.kt:83-97`; called from `features/attachments/.../AttachmentsManager.kt:88`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `photo_tag` | `client` — tag arg from attachments UI |
| `gps_available` | `client` — boolean from attachment capture context |
| `visit_status` | `client:db` — job/visit status (local, server-synced) |
| `job_id` | `client:db` — local job id (server-synced) |

### `Photo Deleted`
- Fired via: `AnalyticsManager.onPhotoDeleted(...)` at `AnalyticsManager.kt:99-111`; called from `features/attachments/.../AttachmentsManager.kt:63`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `photo_tag` | `client` |
| `visit_status` | `client:db` |
| `job_id` | `client:db` |

### `Photo Tag Changed`
- Fired via: `AnalyticsManager.onPhotoTagChanged(...)` at `AnalyticsManager.kt:113-127`; called from `features/attachments/.../AttachmentsManager.kt:148`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `previous_tag` | `client` |
| `new_tag` | `client` |
| `visit_status` | `client:db` |
| `job_id` | `client:db` |

### `Page Shown`
Three sources, same title.
- Fired via: `AnalyticsManager.onScreenOpen(screenName)` at `AnalyticsManager.kt:129-136` (auto from navigation listener, excludes `CUSTOM_LOG_SCREENS` = `"Job Item Full Screen"`, `"Now"`); also `onJobItemFullScreen(...)` at `:299-320` (called from `features/jobs/.../JobItemViewModel.kt:178`) and `onJobItemNowScreen(...)` at `:322-337` (called from `features/jobs/.../JobsNowViewModel.kt:50`).
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `page_name` | `computed:navigation` (screen title) / `literal:"Job Item Full Screen"` / `literal:"Now"` |
| `has_address` (full screen) | `client:db` — computed from job item fields |
| `has_scope` (full screen) | `client:db` |
| `has_photos` (full screen) | `client:db` |
| `has_notes` (full screen) | `client:db` |
| `photos_count` (full screen) | `computed:client` — count of local photos |
| `notes_count` (full screen) | `computed:client` — count of local notes |
| `scope_count` (full screen) | `computed:client` |
| `jobs_today_count` (Now) | `computed:db` — today's jobs count |
| `jobs_completed_count` (Now) | `computed:db` |
| `jobs_inprogress_count` (Now) | `computed:db` |
| `jobs_scheduled_count` (Now) | `computed:db` |

### `Click User Logout`
- Fired via: `AnalyticsManager.onLogout(isLogoutByUser = true)` at `AnalyticsManager.kt:143-145`; called from `features/login/.../LogoutManager.kt:28`
- Props (beyond standard): none (only standard params).

### `User Logged Out`
- Fired via: `AnalyticsManager.onLogout(isLogoutByUser = false)` at `AnalyticsManager.kt:143,147`; called from `features/login/.../LogoutManager.kt:28` (non-user-initiated logout)
- Props (beyond standard): none.

### `User Signed In`
- Fired via: `AnalyticsManager.onLogin(method, isNewMaster)` at `AnalyticsManager.kt:150-156`; called from `features/login/.../VerificationViewModel.kt:120` (OTP) and `features/login/.../SocialSignInManager.kt:207` (social)
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `method` | `client` — sign-in method string (otp/social) |
| `is_new_master` | `client` — boolean (new master user created); reflects registration outcome (server-influenced but passed as local flag) |

### `Click Job Status Change`
- Fired via: private `AnalyticsManager.onJobStatusChanged(...)` at `AnalyticsManager.kt:190-205`, funneled by public `onJobComplete`/`onJobProgress`/`onJobResume`/`onJobSchedule` (`:158-188`); called from `features/jobs/.../JobItemViewModel.kt:404` (complete), `:215` (progress), `:354` (resume), `:450` (schedule)
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `context` | `computed:literal` — `"now"` if `isFromNow` else `"jobs_list"` |
| `status` | `literal` — `"complete"`/`"progress"`/`"resume"`/`"schedule"` per funnel method |
| `previous_status` | `client:db` — prior job status (local, server-synced) |
| `notes_count` | `computed:client` |
| `photos_count` | `computed:client` |

### `App Launched`
- Fired via: `AnalyticsManager.onAppLaunched()` at `AnalyticsManager.kt:208`; called from `sharedUI/.../di/Koin.kt:189`
- Props (beyond standard): none. Note: listed in `UN_AUTHORIZED_EVENTS` — `hashKey()` excludes `user_id` (fires pre-auth).

### `Click Note Create`
- Fired via: `AnalyticsManager.onNoteCreate(length, visitId, visitStatus)` at `AnalyticsManager.kt:277-285`; called from `features/notes/.../CreateNoteViewModel.kt:83`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `length` | `computed:client` — note text length |
| `visit_id` | `client:db` |
| `visit_status` | `client:db` |

### `Click Note Update`
- Fired via: `AnalyticsManager.onNoteUpdate(noteId, length, visitId, visitStatus)` at `AnalyticsManager.kt:288-297`; called from `features/notes/.../EditNoteViewModel.kt:132`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `note_id` | `client:db` |
| `length` | `computed:client` |
| `visit_id` | `client:db` |
| `visit_status` | `client:db` |

### `Click Note Remove`
- Fired via: `AnalyticsManager.onNoteRemove(noteId, visitId, visitStatus)` at `AnalyticsManager.kt:339-347`; called from `features/notes/.../ListNotesViewModel.kt:160` and `features/notes/.../EditNoteViewModel.kt:102`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `note_id` | `client:db` |
| `visit_id` | `client:db` |
| `visit_status` | `client:db` |

### `Click Note View`
- Fired via: `AnalyticsManager.onNoteView(noteId, length, visitId, visitStatus, authorId, isEditAllow)` at `AnalyticsManager.kt:350-368`; called from `features/notes/.../ListNotesViewModel.kt:114`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `edit_allow` | `computed:client` — permission flag for current worker |
| `author_id` | `client:db` — note author id (server-synced) |
| `note_id` | `client:db` |
| `length` | `computed:client` |
| `visit_id` | `client:db` |
| `visit_status` | `client:db` |

### `Onboarding Screen Shown`
- Fired via: `AnalyticsManager.onOnboardingOfflineShow()` at `AnalyticsManager.kt:370-372` (called `features/login/.../OnboardingOfflineModel.kt:23`) and `onOnboardingLocationShow()` at `:374-376` (called `OnboardingLocationModel.kt:23`)
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `context` | `literal:"offline"` / `literal:"location"` |

### `Tap Onboarding Continue`
- Fired via: `AnalyticsManager.onOnboardingOfflineClick()` at `AnalyticsManager.kt:378-380` (called `OnboardingOfflineModel.kt:28`) and `onOnboardingLocationClick()` at `:382-384` (called `OnboardingLocationModel.kt:28`)
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `context` | `literal:"offline"` / `literal:"location"` |

### `Location Permission Requested`
- Fired via: `AnalyticsManager.onLocationPermissionRequested()` at `AnalyticsManager.kt:386-388`; called from `core/analytics/.../api/LocationManager.kt:91`
- Props (beyond standard): none.

### `Location Permission Answered`
- Fired via: `AnalyticsManager.onLocationPermissionAnswered(granted)` at `AnalyticsManager.kt:390-392`; called from `core/analytics/.../api/LocationManager.kt:101`
- Props (beyond standard):

| prop | provenance |
|------|------------|
| `granted` | `client` — boolean permission grant result |

## Properties sourced from BFF (to trace server-side)

| prop | event(s) | BFF endpoint / response field |
|------|----------|-------------------------------|
| `account_id` | ALL events (standard param) | `WorkerApi.getBusinesses()` → `GET /api/worker/businesses` → `businesses[0].accountId` (cached in `AccountStorage`) |
| `business_industry` | ALL events (standard param) | `WorkerApi.getBusinessesProfile()` → `GET /api/Account/business-profile` → `industry` (cached in `AccountStorage`) |
| `jobs_completed` | ALL events (standard param) | indirect — local `JobsRepository` DB count of `"completed"` jobs; DB is server-synced (job source), not a direct query field |
| `job_id`, `visit_id`, `visit_status`, `previous_status`, `author_id`, `has_*`/`*_count` | photo/note/job/page events | indirect — local job/note/visit DB (server-synced aggregates); not read from a live response at event time |
