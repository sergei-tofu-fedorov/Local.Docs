# Top item names per 3A industry

Top-10 invoice line-item names for each of the four **3A industries** (`cleaning`,
`lawn_care_maintenance`, `landscaping`, `pool_spa_service`), ranked by number of
invoice line-items.

- **Generated:** 2026-06-26
- **Source:** `inv-project.ai_analysis_us.invoice_line_items` ⨝ `account_fsm_fit` (on `account_id`)
- **3A filter:** `LOWER(account_fsm_fit.industry) IN ('cleaning','lawn_care_maintenance','landscaping','pool_spa_service')` — same set as `build_recurring_offer_cohort.sql`
- **Normalization:** `LOWER(TRIM(item_name))`, empty names dropped
- **Ranking:** by `line_items` (occurrence count); `accounts` = distinct accounts using the name
- **Scanned:** ~2.4 GB
- **Related:** [3a-classification-quality.md](./3a-classification-quality.md) — leak investigation + prompt A/B (the lawn↔landscaping "leak" turned out mostly a regex artifact; the positive prompt rewrite did not fix it on nano)

## cleaning

| # | item_name | line_items | accounts |
|---|---|---|---|
| 1 | cleaning | 19,858 | 762 |
| 2 | cleaning service | 10,257 | 312 |
| 3 | cleaning services | 8,387 | 299 |
| 4 | house cleaning | 7,307 | 276 |
| 5 | office cleaning | 5,504 | 262 |
| 6 | regular cleaning | 4,807 | 147 |
| 7 | airbnb cleaning | 3,525 | 80 |
| 8 | deep clean | 3,452 | 534 |
| 9 | carpet cleaning | 3,260 | 295 |
| 10 | window cleaning | 2,901 | 213 |

## landscaping

| # | item_name | line_items | accounts |
|---|---|---|---|
| 1 | labor | 7,060 | 836 |
| 2 | lawn service | 3,999 | 99 |
| 3 | lawn maintenance | 3,412 | 154 |
| 4 | landscaping services | 3,263 | 30 |
| 5 | maintenance | 2,755 | 201 |
| 6 | monthly landscaping fee | 2,332 | 1 |
| 7 | landscaping | 2,255 | 292 |
| 8 | mulch | 2,168 | 520 |
| 9 | mowing | 2,060 | 169 |
| 10 | weekly maintenance | 1,964 | 15 |

## lawn_care_maintenance

| # | item_name | line_items | accounts |
|---|---|---|---|
| 1 | mowing | 11,310 | 314 |
| 2 | lawn maintenance | 9,185 | 272 |
| 3 | lawn care | 9,055 | 283 |
| 4 | lawn service | 6,721 | 255 |
| 5 | lawn mowing | 5,944 | 155 |
| 6 | snow removal | 3,124 | 226 |
| 7 | labor | 3,098 | 408 |
| 8 | standard mow | 2,524 | 2 |
| 9 | cut lawn | 2,283 | 9 |
| 10 | date of lawncare service | 2,204 | 1 |

## pool_spa_service

| # | item_name | line_items | accounts |
|---|---|---|---|
| 1 | pool service | 7,705 | 78 |
| 2 | monthly pool service | 4,330 | 34 |
| 3 | pool maintenance | 1,907 | 25 |
| 4 | labor | 1,517 | 93 |
| 5 | filter cleaning | 1,425 | 41 |
| 6 | weekly service | 1,186 | 14 |
| 7 | one month pool service | 1,152 | 2 |
| 8 | monthly  pool service | 1,055 | 1 |
| 9 | muriatic acid | 1,016 | 11 |
| 10 | chlorine tabs | 772 | 9 |

## Caveats

- **Line-item metric skews toward heavy billers.** Rows with `accounts` = 1–2
  (`monthly landscaping fee` 2332/1, `date of lawncare service` 2204/1,
  `standard mow` 2524/2, `monthly  pool service` 1055/1) are one or two accounts
  spamming a single name, not broadly popular items. Re-rank by `accounts` for a
  "breadth" view.
- **Normalization is LOWER+TRIM only.** Internal double spaces are not collapsed,
  so `monthly pool service` and `monthly  pool service` rank separately. Add
  `REGEXP_REPLACE(item_name, r'\s+', ' ')` to merge such dupes.

## Query

```sql
WITH li AS (
  SELECT account_id, LOWER(TRIM(item_name)) AS item_name
  FROM `inv-project.ai_analysis_us.invoice_line_items`
  WHERE item_name IS NOT NULL AND TRIM(item_name) <> ''
),
fsm AS (
  SELECT account_id, ANY_VALUE(LOWER(industry)) AS industry
  FROM `inv-project.ai_analysis_us.account_fsm_fit`
  WHERE LOWER(industry) IN ('cleaning','lawn_care_maintenance','landscaping','pool_spa_service')
  GROUP BY account_id
),
agg AS (
  SELECT f.industry, li.item_name,
         COUNT(*) AS line_items,
         COUNT(DISTINCT li.account_id) AS accounts
  FROM li JOIN fsm f USING (account_id)
  GROUP BY f.industry, li.item_name
)
SELECT industry, item_name, line_items, accounts
FROM agg
QUALIFY ROW_NUMBER() OVER (PARTITION BY industry ORDER BY line_items DESC) <= 10
ORDER BY industry, line_items DESC
```
