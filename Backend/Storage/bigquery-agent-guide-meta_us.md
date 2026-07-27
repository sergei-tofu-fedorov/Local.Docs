`meta_us` — dataset reference (Meta/Facebook ads: schema · joins · caveats)
=========================================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when routing (guide §2)
sends you to `meta_us`** — ad **spend / delivery / creatives** for the Meta (Facebook) ad account, and joining that spend
to user conversions in `amplitude_us`. Cost rules and identity model live in the core guide.

`meta_us` — Meta Marketing API mirror (FSM ad account)
------------------------------------------------------

Written by the `tofu-ai-backend` **meta-ingest** tick, **05:00 UTC daily**. One ad account so far:
**`act_2725877157763325` "Tofu - FSM"** (USD). Dimensions are full-snapshot MERGE-on-`id`; insights are incremental
daily rows MERGE-on-`(date, ad_id)`.

| Table | Grain | Cluster | Contents |
|---|---|---|---|
| `src_meta_campaigns` (199) | 1 row / campaign | `account_id` | `id`, `name`, `objective`, `status`/`effective_status`, `buying_type`, `daily_budget`/`lifetime_budget`/`budget_remaining` (**minor units**), `created_time`/`start_time`/`stop_time`, `raw` |
| `src_meta_adsets` (202) | 1 row / ad set | `campaign_id` | `campaign_id`, `optimization_goal`, `billing_event`, `bid_strategy`, budgets (minor units), `targeting` (JSON), `raw` |
| `src_meta_ads` (2 195) | 1 row / ad | `adset_id` | `campaign_id`, `adset_id`, `creative_id`, `status`/`effective_status`, `raw` |
| `src_meta_insights` | 1 row / **(date, ad)** | `campaign_id`, part. `date` | `ad_id`/`adset_id`/`campaign_id` + names, `impressions`, `reach`, `clicks`, `inline_link_clicks`, `spend`/`cpc`/`cpm`/`ctr`/`frequency` (**major units**, NUMERIC), `actions`/`action_values` (JSON) |

**Semantics worth knowing:**
- **`id` hierarchy:** `campaigns.id` ─< `adsets.campaign_id`; `adsets.id` ─< `ads.adset_id`; `ads.id` = `insights.ad_id`. `insights` also carries `adset_id`/`campaign_id`+names inline, so rollups need no join.
- **Units:** budgets = **minor units** (cents); `spend`/`cpc`/`cpm` = **major units** (USD); `ctr` = percent; `frequency` = impressions/reach.
- **`status` vs `effective_status`:** `status` = advertiser-set (`ACTIVE`/`PAUSED`/`ARCHIVED`/`DELETED`); `effective_status` = actual delivery incl. parent effects. Use `effective_status` for "is it running".
- **`actions`/`action_values`:** JSON array of `{action_type, value}` (counts / attributed value). Extract with `UNNEST(JSON_QUERY_ARRAY(actions))` filtered on `action_type` (e.g. `omni_purchase`, `offsite_conversion.fb_pixel_lead`, `mobile_app_install`, `landing_page_view`). Meta reports the **same conversion under several `action_type`s** (pixel/omni/onsite) — pick one family, don't sum across.
- **`account_id` is the *Meta* ad-account id** (digits, no `act_`), **not** our internal Tofu `Account.Id`. `source_account` = the `act_…` pulled under. → **No direct account-level join to the warehouse.** Cross-dataset attribution goes through `amplitude_us` (below).

Joining to `amplitude_us` (spend ⇄ conversions) — the money join
----------------------------------------------------------------

`meta_us` is aggregate (ad × day, no user identity). The bridge to per-user conversions/revenue is **`amplitude_us`**,
whose **Tofu Web** project (`source_project='586241'`) stamps the **actual Meta ids** onto each user's `user_properties`
via the Playfair/AppsFlyer enrichment. **These are real ids — join on the id, not the campaign name.**

> **Fast path — don't over-read or over-probe.** Everything you need for this join is in THIS file: the exact keys, JSON
> paths, filters, and a ready query below. You do **not** need to open `-amplitude_us.md`, and you do **not** need to
> `bq show` these tables (the schema is above). Lift the query → `--dry_run` → run. Two facts that save a round-trip:
> `src_meta_insights` is **currently empty** (backfill pending), so pull campaign/ad **names** from `src_meta_campaigns`
> / `src_meta_ads`, not insights; and the only ad account is `act_2725877157763325`, so no account filter is needed.

| `amplitude_us` `user_properties` key (`JSON_VALUE`) | = meta_us column |
|---|---|
| `$."[Playfair \| AF] campaign_id"` | `src_meta_campaigns.id` / `src_meta_insights.campaign_id` |
| `$."[Playfair \| AF] adset_id"` | `src_meta_adsets.id` / `src_meta_insights.adset_id` |
| `$."[Playfair \| AF] ad_id"` | `src_meta_ads.id` / `src_meta_insights.ad_id` |
| `$."[Playfair \| AF] campaign"` / `adset` / `ad` | the corresponding `name` (fuzzy fallback) |
| `$."[Playfair \| AF] media_source"` | ad channel, e.g. `facebook_int` (this account's FB traffic) |

- **Last-touch vs first-touch:** the bare `[Playfair | AF] *` keys are **last-touch**; `initial_[Playfair | AF] *` are
  **first-touch** — they can differ for the same user (pick deliberately).
- **Also available:** `utm_source` (`'Facebook'`), `utm_campaign` (= the campaign *name*), `utm_id`, `utm_content`, `fbclid`. Prefer the `[Playfair | AF] *_id` keys — they're the Meta ids and give a clean equality join.
- **Coverage (verified FB web, 2026-07-20..22, 18 457 rows):** **92.6 %** carry `[Playfair | AF] campaign_id`; **~74 %** of all FB web rows match a live id in `src_meta_campaigns` / `src_meta_ads`. The gap is older/paused/deleted campaigns not in the current snapshot (dimensions MERGE-never-delete, so coverage grows over time). Only the **web** project (586241) is verified; the FS-iOS project (760259) likely carries the same keys for app-promotion campaigns (unverified).
- **Chain to revenue:** amplitude `user_id` (platform GUID) → `ai_analysis_us.mart_account_subscriptions.platform_user_id` → `subz_account_id`(`cus_`)/`account_id` → `stripe_us`/`payments_us` (guide §1.5/§1.7). So: **spend from `meta_us`, per-ad, ÷ paying users from that chain = CAC/ROAS at ad granularity.**

**Example — spend (meta) vs Facebook trial-starts (amplitude) per campaign, last 30d:**

```sql
WITH spend AS (
  SELECT campaign_id, campaign_name, SUM(spend) spend
  FROM `inv-project.meta_us.src_meta_insights`
  WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
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
- **Insights may be empty.** As of 2026-07-24 the insights backfill fails on BigQuery `rateLimitExceeded` (windowed loop MERGEs one table too fast; coalescing fix pending). Dimensions (campaigns/adsets/ads) are populated; `src_meta_insights` may be 0 rows until the fix ships — check `bq show` row count before relying on it. **For campaign/ad ids you can still join amplitude → `src_meta_campaigns`/`src_meta_ads` today.**
- **Join on id, not name** — `[Playfair | AF] *_id` = Meta ids (clean equality); `utm_campaign`/names are fuzzy fallbacks.
- **~26 % of FB web rows don't match** a current dimension row (old/deleted campaigns) — report matched coverage, don't assume 100 %.
- **Attribution keeps moving** for recent days (~28d window); the ingest re-pulls the last 7 days, so last-week insights aren't final.
- The older `-amplitude_us.md` note "web project 586241 not in BQ" is **stale** — it is mirrored now (verified 2026-07-24).
