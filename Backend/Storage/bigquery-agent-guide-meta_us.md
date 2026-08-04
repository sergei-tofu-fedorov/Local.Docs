`meta_us` — dataset reference (Meta/Facebook ads: schema · joins · caveats)
=========================================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when routing (guide §2)
sends you to `meta_us`** — ad **spend / delivery / creatives** for the Meta (Facebook) ad accounts, and joining that spend
to user conversions in `amplitude_us`. Cost rules and identity model live in the core guide.

Start with the reporting layer, not the raw tables
--------------------------------------------------

Five views/functions sit on top of `src_meta_*` and already contain the parts that are easy to get wrong: pulling the
landing page out of nested JSON, picking the one non-double-counting purchase type, and computing ratios so they survive
aggregation. **Reach for these first** — hand-rolling the same logic from the raw tables is where wrong numbers come from.

| Object | Grain | Use it for |
|---|---|---|
| `tvf_meta_report_by_landing(from_date, to_date, account)` | 3 levels (`total`/`landing`/`ad`) | the creative report over any period. `account = NULL` means all accounts |
| `vw_meta_ad_daily` | ad × day | any custom cut — group and filter this instead of joining `src_*` yourself |
| `vw_meta_ad_resolved` | ad (current state) | landing, creative format, texts, links, what the ad set promotes |
| `vw_meta_landing_last_7d` | landing | standing "where is the money going" — 7 closed days, rolling |
| `vw_meta_ad_links_audit` | ad (current state) | where an ad really sends people; flags store/caption mismatches |

```sql
-- report for a period, one account
SELECT * FROM `inv-project.meta_us.tvf_meta_report_by_landing`(
         DATE '2026-07-01', DATE '2026-07-31', 'act_2725877157763325')
ORDER BY IF(level = 'total', 0, 1), spend DESC;

-- custom cut: monthly by account
SELECT FORMAT_DATE('%Y-%m', date) month, source_account,
       SUM(spend) spend,
       SAFE_DIVIDE(SUM(spend), SUM(impressions)) * 1000 cpm,
       SUM(purchases_clean) purchases
FROM `inv-project.meta_us.vw_meta_ad_daily`
WHERE date BETWEEN '2026-06-01' AND '2026-07-31'
GROUP BY month, source_account;
```

`vw_meta_ad_daily` deliberately carries **no** `cpc`/`cpm`/`ctr`/`cpa` — see the ratio trap below. `vw_meta_ad_resolved`
and `vw_meta_ad_links_audit` have no time dimension at all; to scope an audit to a period, join on `ad_id` from
`vw_meta_ad_daily`. Ordering inside a table function is not guaranteed — sort in your own query.

`meta_us` — Meta Marketing API mirror (two ad accounts)
-------------------------------------------------------

Written by the `tofu-ai-backend` **meta-ingest** Hangfire jobs. Four separate ticks, because the cost of a pull is
Meta's per-account **cpu-time** budget and one big tick exhausts it:

| Job | Cron (UTC) | Pulls |
|---|---|---|
| `meta-ingest` | `0 5 * * *` | ad-account dimension + the creatives top-up |
| `meta-ingest-statuses` | `0 7-21 * * *` | campaigns + ad sets in full, ads as a delta on their own `updated_time`; each written to **both** the dimension and the `_hist` snapshot |
| `meta-ingest-insights` | `0 2,8,14,20 * * *` | ad-level daily insights; deep 28-day attribution pass at 08:00, 2-day intraday pass otherwise |
| `meta-ingest-ads-reconcile` | `0 3 * * 0` | the full ad snapshot, weekly — a reconciliation, not the source of freshness |

**The ad dimension is maintained hourly by the delta, not by the full snapshot.** Measured on Invoice Maker: 23 870 ads,
of which **111 change in a day and 108 of those are simply new**. The weekly full pull exists only for what a delta
cannot see — an ad that stopped delivering because its *parent* was paused leaves its own `updated_time` untouched, so
without the reconciliation the dimension's `effective_status` would drift indefinitely.

> **⚠ TWO ad accounts — always filter or group by `source_account`.** An unfiltered `SUM(spend)` silently mixes two
> unrelated products.

| `source_account` | Product | Insights depth | Rows in `src_meta_insights` | Lifetime spend in window |
|---|---|---|---|---|
| `act_2725877157763325` | Tofu - FSM (Field Service) | 2026-01-28 → | 9 812 | ≈ $252 600 |
| `act_318657674434347` | Invoice Maker | 2025-12-04 → | 80 101 | ≈ $628 800 |

Both accounts are USD and both use `America/Los_Angeles` (matters — see the date-grain caveat). A third account
(`act_337062095880278` "TaptoPay") exists in the Business Manager but is **not** ingested.

| Table | Grain | Part. / cluster | Contents |
|---|---|---|---|
| `src_meta_campaigns` (1 483) | campaign | `created_time` / `account_id` | `objective`, `status`/`effective_status`, `buying_type`, budgets (**minor units**), `raw` |
| `src_meta_adsets` (1 576) | ad set | `created_time` / `campaign_id` | `optimization_goal`, `billing_event`, `bid_strategy`, budgets (minor units), `targeting` (JSON), **`promoted_object` (JSON)**, `raw` |
| `src_meta_ads` (26 349) | ad | `created_time` / `adset_id` | `campaign_id`, `adset_id`, `creative_id`, `status`/`effective_status`, `raw` |
| `src_meta_ad_creatives` (4 810) | creative | — / `id` | `object_type`, `video_id`, `image_hash`, `body`, `title`, `call_to_action_type`, `url_tags`, `object_story_spec` + `asset_feed_spec` (JSON), `raw`. **Partial — see the coverage caveat** |
| `src_meta_insights` (89 913) | **(date, ad)** | `date` / `campaign_id` | ids + names, `impressions`, `reach`, `clicks`, `inline_link_clicks`, `spend`/`cpc`/`cpm`/`ctr`/`frequency` (**major units**, NUMERIC), `actions`/`action_values` (JSON) |
| `src_meta_ad_accounts` (2) | ad account | — | the dimension behind `source_account`: `currency`, `timezone_name`, `account_status`, `amount_spent`/`spend_cap`/`balance` (minor units) |
| `src_meta_ads_hist` (17 945) | **(ad, snapshot)** | `DATE(snapshot_at)`, 90-day expiry / `id` | hourly status history + `creative_id` — answers "when was this paused" and "when was the creative swapped". No `raw` |
| `src_meta_adsets_hist` (17 336) | (ad set, snapshot) | same | status + budget history |
| `src_meta_campaigns_hist` (15 035) | (campaign, snapshot) | same | status + budget history |
| `sys_meta_ads_bootstrap_state` (1) | account | — | cursor for the sliced historical ad backfill; operational, not analytical |

Naming: **`_hist` = one row per observation**; `_periods` (as in `ai_analysis_us.mart_subscription_periods`) is reserved
for interval/SCD tables. `vw_`/`tvf_` = the reporting layer above. Don't conflate them.

The two traps that produce confidently wrong numbers
----------------------------------------------------

**1. Never aggregate `cpc`/`cpm`/`ctr` — recompute them from sums.** These columns are correct *per row* (verified: zero
rows disagree with `clicks/impressions` and `spend/clicks`) but they are ratios, and averaging ratios is not aggregation.
Measured on Invoice Maker:

| | `AVG` over rows | `SUM`/`SUM` | Error |
|---|---|---|---|
| CPM | 7.39 | 3.21 | +130 % |
| CPC | 0.66 | 0.46 | +43 % |
| CTR | 1.29 % | 0.70 % | +84 % |

Two independent causes. The median ad-day has only **76 impressions**, and rows under 100 impressions are more than half
of all rows while holding **1.15 %** of spend — yet an average gives them equal weight. And `cpc` arrives **`NULL`** on
the 46 % of rows with zero clicks, so `AVG` silently answers for a different population than `SUM` does. Always
`SUM(numerator)/SUM(denominator)` at the level you group — **including a single ad over a period**, since the grain is
ad × day and even one ad's line in a monthly report is an aggregate.

**2. Meta reports one purchase under several `action_type`s — sum only `omni_purchase`.** Verified exactly on our data:
`omni_purchase` 19 662 = app `app_custom_event.fb_mobile_purchase` 19 026 + web pixel
`offsite_conversion.fb_pixel_purchase` 636. Summing the four types a naive report would add gives **58 350 — 2.97× too
high**. `omni_*` is Meta's umbrella family and already covers both web and app; pick it alone.

`vw_meta_ad_daily` exposes both: `purchases_clean` (the right one) and `purchases_inflated` (kept only so the gap is
visible). The table function likewise has `cpa_clean` alongside `cpa` — read the clean one.

**Trials are always 0.** No `action_type` matching `*trial*` reaches our insights at all, even though ad sets optimise
for `START_TRIAL` (visible in `promoted_object.custom_event_type`). So the funnel event is either not sent by the app or
arrives under another name; the nearest candidates by meaning are `omni_initiated_checkout` (53 169) and
`app_custom_event.fb_mobile_initiated_checkout` (51 413), but they are **not** trials and were deliberately not
substituted. Treat a zero trials column as "not instrumented", not as "no trials happened".

Semantics worth knowing
-----------------------

- **`source_account` is the filter column.** Fully populated everywhere, always `act_<digits>`, equal to
  `'act_' || account_id`. Not a clustering key on any table, so filtering by it prunes nothing — fine, the dataset is
  small, but expect no cost win.
- **`id` hierarchy:** `campaigns.id` ─< `adsets.campaign_id`; `adsets.id` ─< `ads.adset_id`; `ads.id` = `insights.ad_id`;
  `ads.creative_id` = `ad_creatives.id`. `insights` carries `adset_id`/`campaign_id` + names inline, so rollups need no join.
- **Ad *names* are not unique.** Two live FSM ads share the name `FSM_Static_011_…_V_16 - Copy`. Group ad-level reports
  by `ad_id` and carry the name along — grouping by name merged those two into one row with 4.6× the impressions while
  the other ad vanished from the report entirely (caught by diffing against a reference export).
- **Units:** budgets = **minor units** (cents); `spend`/`cpc`/`cpm` = **major units** (USD); `ctr` = percent;
  `frequency` = impressions/reach. Both accounts are USD today, but currency is a property of the **ad account**, so a
  future non-USD account would break cross-account sums silently.
- **`date` is the AD ACCOUNT's day, not UTC.** Meta buckets `time_increment=1` by the account timezone
  (`America/Los_Angeles` for both), i.e. `date` runs 07:00→07:00 UTC (08:00 in winter). Every other Tofu dataset is UTC,
  so a naive `DATE(event_time) = insights.date` join is off by 7–8 hours and nothing in the data hints at it.
  **Do not convert insights to UTC** — a daily row spans two UTC days and cannot be split without assuming uniform
  delivery. Convert the *other* side: `DATE(event_time, 'America/Los_Angeles')`. Use the IANA zone name, **never** a
  numeric offset — DST makes it wrong.
- **`status` vs `effective_status`:** `status` = advertiser-set; `effective_status` = actual delivery incl. parent
  effects. Use `effective_status` for "is it running". Precedence is **nearest level wins** (the ad's own state overrides
  the parent's) — reversing that gave 96.1 % agreement with Meta's own field where the correct order gives 99.35 %.
- **Where the landing page is.** Not in `url_tags`, and not in any flat column: it sits inside `object_story_spec` /
  `asset_feed_spec` at a **format-specific path**. Five paths in order, first match wins (this is what
  `vw_meta_ad_resolved` does — don't rewrite it):
  `object_story_spec.link_data.link` → `…link_data.child_attachments[0].link` →
  `…video_data.call_to_action.value.link` → `asset_feed_spec.link_urls[0].website_url` →
  `asset_feed_spec.call_to_actions[0].value.link`.
- **`url_tags` is empty, but the tracking parameters exist** — inside the landing URL's query string. Non-empty
  `url_tags` was found on **11 of 2 479** FSM ads, which is why there is no `utm_content → creative` mapping there. The
  AppsFlyer/UTM marking (`pid`, `af_c_id`, `af_ad_id`, `utm_source`, …) lives in the destination link itself, so parse
  `vw_meta_ad_resolved.landing_full` (query string kept) rather than `landing` (stripped for grouping).
- **Creative format comes from the specs, not a column.** `object_type`/`video_id` only separate video from static; a
  **carousel** is visible only as `link_data.child_attachments` or more than one `asset_feed_spec.link_urls`.
- **`promoted_object`** (JSON, ad set level) answers what is being promoted: `application_id`, `object_store_url`,
  `custom_event_type` (the optimisation event, e.g. `START_TRIAL`), `pixel_id`, `smart_pse_enabled`. Shape varies by
  promotion type, so parse with `JSON_VALUE` and don't expect fixed keys.
  **⚠ Currently `NULL` on 100 % of rows (verified 2026-08-04, 0 of 1 576).** The column exists and the ingest code that
  requests the field is written, but **not deployed yet** — the hourly ad-set pull keeps overwriting rows without it, so
  the value will not appear until that deploy lands. Anything downstream is therefore dead until then, including
  `vw_meta_ad_links_audit.store_url_mismatch`: it is computed from `promoted_store_url`, so a clean "0 mismatches" from
  that flag proves nothing right now. Audit links by comparing `landing_full` / `cta_link` / `all_links` directly instead.
- **`actions`/`action_values`:** JSON array of `{action_type, value}`. Extract with
  `UNNEST(JSON_QUERY_ARRAY(actions))` filtered on `action_type`. See the double-counting trap above before summing.
- **`account_id` is the *Meta* ad-account id** (digits, no `act_`), **not** our Tofu `Account.Id`. → **No direct
  account-level join to the warehouse**; cross-dataset attribution goes through `amplitude_us` (below).

Joining to `amplitude_us` (spend ⇄ conversions) — the money join
----------------------------------------------------------------

`meta_us` is aggregate (ad × day, no user identity). The bridge to per-user conversions/revenue is **`amplitude_us`**,
whose **Tofu Web** project (`source_project='586241'`) stamps the **actual Meta ids** onto each user's `user_properties`
via the Playfair/AppsFlyer enrichment. **These are real ids — join on the id, not the campaign name.**

> **Fast path — don't over-read or over-probe.** Everything for this join is in THIS file: the keys, JSON paths, filters
> and a ready query. You do **not** need `-amplitude_us.md`, and you do **not** need to `bq show` these tables. Lift the
> query → `--dry_run` → run. Note the Invoice Maker coverage caveat before reusing it for that account.

| `amplitude_us` `user_properties` key (`JSON_VALUE`) | = meta_us column |
|---|---|
| `$."[Playfair \| AF] campaign_id"` | `src_meta_campaigns.id` / `src_meta_insights.campaign_id` |
| `$."[Playfair \| AF] adset_id"` | `src_meta_adsets.id` / `src_meta_insights.adset_id` |
| `$."[Playfair \| AF] ad_id"` | `src_meta_ads.id` / `src_meta_insights.ad_id` |
| `$."[Playfair \| AF] campaign"` / `adset` / `ad` | the corresponding `name` (fuzzy fallback) |
| `$."[Playfair \| AF] media_source"` | ad channel, e.g. `facebook_int` |

- **Last-touch vs first-touch:** the bare `[Playfair | AF] *` keys are **last-touch**; `initial_[Playfair | AF] *` are
  **first-touch** — they differ for the same user, so pick deliberately.
- **Also available:** `utm_source` (`'Facebook'`), `utm_campaign` (the campaign *name*), `utm_id`, `utm_content`,
  `fbclid`. Prefer the `[Playfair | AF] *_id` keys — clean equality joins.
- **Coverage (verified FB web, 2026-07-20..22, 18 457 rows):** **92.6 %** carry `[Playfair | AF] campaign_id`; **~74 %**
  match a live id in the dimensions. The gap is older/paused/deleted campaigns not in the current snapshot (dimensions
  MERGE-never-delete, so coverage grows). Only the **web** project (586241) is verified.
- **Chain to revenue:** amplitude `user_id` → `ai_analysis_us.mart_account_subscriptions.platform_user_id` →
  `subz_account_id` (`cus_`) / `account_id` → `stripe_us` / `payments_us` (guide §1.5/§1.7). So: **spend from `meta_us`
  per ad ÷ paying users from that chain = CAC/ROAS at ad granularity.**

**Example — spend vs Facebook trial-starts per campaign, last 30 d:**

```sql
WITH spend AS (
  SELECT campaign_id, campaign_name, SUM(spend) spend
  FROM `inv-project.meta_us.src_meta_insights`
  WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
    AND source_account = 'act_2725877157763325'   -- omitting this mixes two products
  GROUP BY 1,2
),
conv AS (
  SELECT JSON_VALUE(user_properties,'$."[Playfair | AF] campaign_id"') campaign_id,
         COUNT(DISTINCT user_id) trial_users
  FROM `inv-project.amplitude_us.src_amplitude_events`
  WHERE event_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
    AND source_project = '586241'
    AND event_type = 'Trial started'
    AND JSON_VALUE(user_properties,'$.utm_source') = 'Facebook'
  GROUP BY 1
)
SELECT s.campaign_name, s.spend, c.trial_users,
       SAFE_DIVIDE(s.spend, c.trial_users) AS cost_per_trial
FROM spend s LEFT JOIN conv c USING (campaign_id)
ORDER BY s.spend DESC;
```

(Both sides prune: `meta_us` by `date`, `amplitude_us` by `event_time` — always filter them.)

Caveats
-------

- **Always scope by `source_account`** (repeated because it is the easiest way to produce a confidently wrong number).
- **`src_meta_ad_creatives` is incomplete for Invoice Maker.** 4 810 creatives loaded; **8 727 still missing** for that
  account as of 2026-08-04. Creatives are fetched **by id**, only for creatives our ads reference, and only once — Meta
  exposes no `updated_time` for them, and an account's library holds roughly 3× more creatives than its live ads use
  (the surplus hangs off archived ads). The top-up is bounded per tick (`CreativesPerTick`, 1 000) and orders
  **newest ad first**, so recent periods resolve first and a report on last week already has full coverage while a
  report on 2024 may not. Consequence in reports: ads without a creative land under the landing
  `'(посадка не найдена)'` — **their spend is still counted**, so a large such row means the backfill is behind, not
  that money is unattributed at Meta.
- **The amplitude join is unmeasured for Invoice Maker.** Coverage figures are FB **web** (project `586241`). Invoice
  Maker runs app-install ads (`call_to_action_type = INSTALL_MOBILE_APP`) whose conversions land in the **iOS** project
  (`213333`). Measure coverage per `source_account` before quoting CAC/ROAS there.
- **Dimensions reach further back than insights.** Invoice Maker campaigns/ads exist from 2024-01-06 but its spend only
  from 2025-12-04, so an old campaign joins to a dimension row with **no** insights. That is the edge of the export:
  about 71 % of that account's lifetime spend ($1.56 M of $2.19 M) was deliberately left out.
- **Insights depth is fixed at first load.** The config floor applies only while an account has zero rows; afterwards the
  `MAX(date)` watermark takes over, so history older than the first load cannot be backfilled by the normal tick.
- **Archived ads are absent.** Meta's `/ads` edge excludes `ARCHIVED` by default. Also don't read `effective_status` as
  "dead": most of Invoice Maker's ads are `CAMPAIGN_PAUSED` — switched off with their campaign and revivable.
- **The newest day is always partial**, and so is any range that includes today: it is still accruing in the account's
  timezone, and attribution keeps moving for ~28 days (re-pulled by the 08:00 deep pass). When comparing against an
  external export, check *when that export was taken* before calling a difference a defect — a reference report whose
  header said "through 2026-06-22" actually stopped at the 21st, and every apparent discrepancy beyond 0.8 % was that.
- **Join on id, not name** — `[Playfair | AF] *_id` are Meta ids; `utm_campaign`/names are fuzzy fallbacks.
- **A "throttled" wait is not always a quota limit.** The binding Meta budget is per-account **cpu-time**, not the call
  counter: a lockout arrived at `total_cputime` 103 % with the call count untouched. Conversely, a back-off was once
  logged at `app_id_util_pct` 0.01 and the same request succeeded immediately on retry. Check the error code before
  concluding the app hit its tier limit.
- The older `-amplitude_us.md` note "web project 586241 not in BQ" is **stale** — it is mirrored now (verified 2026-07-24).
