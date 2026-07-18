# flash-lite prompt findings — human review of `fsm-fit-judge-diverse` (running log)

Per-account observations from the Argilla human pass (4-model votes + reasoning), feeding the
flash-lite fixes in [`flashlite-improvement.md`](./flashlite-improvement.md). Goal: improve the
**flash-lite call path** (model-specific responseSchema `description`s / few-shots), NOT the shared
nano-tuned `FsmFitPrompt`. Accounts referenced by pseudonymous `account_id` only (no PII).

Legend: ✅ = flash-lite correct · ❌ = flash-lite wrong (vs the other models / human read).

## RESULTS vs the human gold (n=200, all labelled) — FINAL

Flag macro-F1 is over the **5 reliable flags** (contract_based_billing excluded — the annotator's own call on it
is noisy, "nearly ignore it"; scored separately).

| model | industry acc | NOT-FSM P/R | flag macro-F1 (5 reliable) |
|---|---|---|---|
| prod-nano (v3, prod store) | 64.0% | 69% / 18% | 0.513 |
| nano (v7, re-run) | 67.5% | 54% / 77% | 0.574 |
| flash_raw (v7, no levers) | 82.5% | 72% / 70% | 0.639 |
| **flash_now (+C1–C6, final)** | **~86%** | 81% / 69% | **0.721** |
| claude | 89.0% | 87% / 89% | 0.685 |

(Gold after the user re-judged all 29 flash-fails + earlier corrections. flash-lite leads flags (0.721 vs 0.685),
claude leads industry (89% vs ~86%). **Industry number is noisy:** Vertex temp-0 re-runs vary ~±1.5pp (≈3
accounts) — that run-to-run variance now EXCEEDS the per-rule effects, which is why the late micro-rules (store
install-ignore, sales-name, CCTV, disambiguation) couldn't be shown to help. flash-lite practical ceiling ≈86-87%.)

- **flash-lite >> nano** (81% vs 69% industry even raw) → confirms the prod nano→flash-lite switch.
- **The calibration won:** flash-lite industry 81.0→84.5%, 5-flag macro-F1 0.649→**0.708** — now **above claude (0.694)**
  on flags and ~1pt behind on industry, at a fraction of the cost.
- Final per-flag (flash_now): on_site 0.90, labour 0.87, scheduling 0.64, recurring 0.50, complex 0.62.
  contract_based_billing collapsed to F1 0.14 but is **deliberately ignored** (unreliable gold).
- Δ from the C4 round (F4 guard + relaxed F1 + compaction): on_site 0.85→**0.90**, complex 0.48→**0.62**,
  labour precision 78→92%; recurring -0.06; contract noise ignored.


**Labelling convention — `FSM-fit?` marker:** blank == **yes** (fsm-fit); only an explicit **`no`** marks the
account NOT FSM-fit. The annotator only clicks "no"; forgetting to click counts as yes. Operationalised by a
`fsm_fit="yes"` suggestion on every record (UI default) and by `export_gold.py` (`fsm_fit = no` only when the
response is explicitly "no", else "yes").

---

## F1 — `complex_multi_line_jobs` over-flagged from item *variety* (not per-invoice composition)

- **account_id:** `znbq5x5ok2-4f37e1bb3ee3446283a7f08b297498c8-4fad7503c3c985fd29a01b438cf0354f`
  (automotive locksmith; items are key-cutting / key-programming jobs across many different vehicles)
- **Signals:** `avg_line_items_per_invoice = null`, `avg_invoice_amount = null`, `distinct_addresses = 8`.
- **Votes — `complex_multi_line_jobs`:** prod-nano ❌→False · nano False · **flash-lite ❌ True** · claude False.
  flash-lite reasoning: *"The variety of services and vehicle makes suggests complex jobs…"*
- **Why wrong:** the flag is about a SINGLE invoice mixing labour + parts + materials (signalled by a
  high per-invoice line count + moderate/high amount). flash-lite instead inferred it from the
  **diversity of item names across the account** — many distinct one-type jobs ≠ complex multi-line.
  Here `avg_line_items_per_invoice` is null, so there's no composition signal at all.
- **Repeat pattern:** same faulty "variety of services → complex multi-line" reasoning seen on at least
  `zv19a5onpn-…` (snow/tree/grading account) — so it generalises, not a one-off.
- **Proposed lever (schema description for `complex_multi_line_jobs` on the flash-lite call):**
  *"TRUE only when a SINGLE invoice combines labour + parts/materials — signalled by a moderate-to-high
  `avg_line_items_per_invoice` (≈3+) AND amount ($500+). A VARIETY of different one-type items across the
  account (e.g. many key jobs for different vehicles, or several distinct services) is NOT
  complex_multi_line_jobs. When `avg_line_items_per_invoice` is null or ≤2, default FALSE."*
- **Secondary (same record):** flash-lite also set `scheduling=true` from *"multiple distinct addresses
  implies scheduling"* — already a known over-flag; distinct addresses alone = on_site_work, not
  scheduling (claude also over-called scheduling here; prod-nano/nano = False).

## F2 — wholesale / supply sellers misrouted to a trade (item-driven, NOT name-driven)

- **User flag:** "Pool Cleaning Supplies Whole Sale" is a goods seller, not a service → should be `other`;
  asked to key on words like *sale* in the business name.
- **But** on that exact account flash-lite (post-C1) is already correct: `other`, no flags, reasoning cites
  "supplies sold by the unit… name indicates wholesale". prod-nano is the one wrong (`pool_spa_service`).
- **Real flash-lite misses found by scanning selling-named accounts:**
  - `J.G. HARDWARE AND CONSTRUCTION SUPPLIES` — items are pure materials by the unit (deform bar, cement,
    CHB block, conduit pipe, wire, gravel, plywood). flash-lite reasoning literally says *"sale of
    construction materials, not direct FSM service"* yet output **`general_contracting`** — a
    **CONTRADICTION INVARIANT violation** (the prompt already mandates `other` when the reasoning concludes
    materials/wholesale). This is the clean target.
  - `WINCARE HOTEL SUPPLY` — mixed (chlorine/pillows/mattress/umbrella + some pump/dynamo service items);
    flash-lite → `pool_spa_service`. Borderline, dominant pattern is supply.
- **Counter-example (why NOT to trigger on the name):** `Gmc Pest Control, Sales & Rentals LTD.` has "Sales"
  in the name but the items are genuine service (pest control service, termite treatment, bait-station
  installation) → flash-lite correctly says `pest_control`. A "sale in name → other" rule would WRONGLY
  send this to other. So the name keyword is at most weak corroboration, never the trigger.
- **Proposed lever (flash-lite call):** reinforce the product-vs-service step + contradiction invariant —
  *"If the line items are predominantly GOODS/MATERIALS sold by the unit (SKUs, sizes/quantities, rebar,
  cement, pipe, conduit, wire, gravel, plywood, chlorine drums, retail products), the account SELLS
  materials → industry = `other` and all flags false, EVEN IF the name or the material type implies a trade
  (hardware, construction supply, pool supply). Never output a trade industry when your own reasoning says
  it's a materials/supply/wholesale seller. Judge by the line items, not the business name — a name
  containing 'Sales'/'Supply' on an account whose items are real services stays its service industry."*
- **Status:** not yet applied (item-driven, safe). Decide whether to fold into the next flash-lite re-run.

## F3b — `on_site_work` over-inferred from the address aggregate on PRODUCT/resale accounts

- **Trigger:** account `xgbeccmguc-…` (CCTV / networking gear — HIKVISION cameras, DVRs, baluns, Cat6, switches,
  monitor, UPS; notes "Advance 60% … 2 Year Warranty" = a SALES invoice). flash-lite → `computers_it` +
  on_site_work, reasoning *"multiple distinct addresses also suggests on-site work."*
- **Question raised:** is flash-lite mistaking electronic manufacturer/model strings for addresses? **No.**
  Data check: flash mentions "address" in 41/200 reasonings; only 1 has `distinct_addresses≤1` — so the claim is
  grounded in the REAL backend aggregate (`distinct_addresses=5`, `multi_address_work=true` here), not
  hallucinated from item text. flash is not fooled by "2MP CAMERA 40M"/"Cat 6"/HIKVISION.
- **Real issue:** flash treats `distinct_addresses` / `multi_address_work` as on_site_work evidence even for a
  PRODUCT/resale account, where N distinct addresses = N distinct BUYERS / deliveries, not N on-site jobs.
- **Proposed lever (flash-lite call):** *"`distinct_addresses` and `multi_address_work` count distinct CUSTOMER
  billing locations. For a SERVICE business they support on_site_work, but for a PRODUCT / resale account (items
  sold by the unit) multiple addresses just mean multiple buyers/deliveries and do NOT by themselves establish
  on_site_work. Do not set on_site_work from the address aggregate alone when the items are goods."*
- Model spread (this is a borderline sell-vs-install CCTV account): nano=other[] · flash=computers_it[on_site] ·
  prod=computers_it[on_site,complex] · claude=security_alarm[on_site,labour,scheduling,complex].
- **Status:** not applied — answer to the question + candidate lever.

## F4 — `industry=other` must force ALL flags false (product/non-FSM accounts leak flags)

- **User rule:** if the items are products, the flags make no sense. A product / non-FSM account (industry
  `other`) should have all six evidence flags false; delivery/shipping scheduling of goods is NOT the
  `scheduling` flag.
- **Trigger:** `Destino Industrial Muebles` (furniture: "Cama box…" beds) — flash → `other` but flags
  `[on_site_work, scheduling, contract_based_billing]`, reasoning literally *"product sales, not
  FSM-applicable work."*
- **Magnitude:** **46 of 66** flash `other`-accounts carry ≥1 flag (massage, pet care, flower shop, healing,
  furniture, etc. — correctly `other`, but flags leak). The biggest single inconsistency found so far.
- **Lever (two parts):** (a) flash-lite calibration — *"If industry is `other` (not FSM-applicable: product
  sales, out-of-scope service, wholesale, retail), set ALL SIX evidence flags FALSE. Delivery/shipping
  scheduling of products is NOT `scheduling`; selling goods is not `on_site_work`/`labour_billing`. The flags
  describe FSM work evidence, which a non-FSM account does not have."* (b) belt-and-suspenders deterministic
  guard in the runner: if `industry=="other"`, zero all flags (the invariant holds by definition, and the
  model leaks even when it reasons correctly).
- **Status:** not yet applied — strong, high-coverage invariant; recommend applying next.

## F5 — refining industry accuracy: the `other` boundary (84.5% → ?)

Error analysis of the 31 industry misses (vs human gold, flash_now):
- **24 of 31 are the `other` boundary** — 14 trades demoted to `other`, 10 `other`-accounts given a trade.
  Only 7 are trade↔trade.
- **Key pattern (recoverable):** flash often REASONS a trade but outputs `other` — F3's "prefer other when
  uncertain" over-firing on terse-but-real service text. Examples: `D&K Paving` ("Asphalt patch, Driveway" —
  reasoning "on-site work and labour billing" → other), `Helping Hands` ("Waste collection and disposal" →
  other), `Madison` ("Trash Disposal, 1 Load" → other), `Solar Group` ("Installation of solar panels, Labor" →
  other), `Gates & Doors` ("Service Call, Labor, Repairs" → other). ~5-7 recoverable.
- **Policy-disagreement misses (NOT clear errors), flash follows the prompt:** name-only `ALL Painting` (empty
  items ⇒ other), automotive repair ⇒ other (the vehicle rule; human chose mechanical_service), `Godinez Pool
  Steel` rebar ⇒ other (materials/F2). "Fixing" these means changing policy.
- **trade↔trade (7):** handyman→plumbing (2×), landscaping→snow_removal, appliance_repair→cleaning,
  security_alarm→computers_it, general_contracting→locksmith, snow_removal→general_contracting.
- **Proposed levers:** (1) soften F3 — default to `other` only for products / out-of-scope / empty, not for
  terse-but-real services; restore the base "don't default to other when a trade is identifiable". (2)
  anti-contradiction: if the items show a service performed (collection/disposal, repair, install, labour,
  service call), classify the trade. (3) optional disambiguation maps (collection→junk_removal,
  asphalt/paving→general_contracting). Trade-off: softening F3 can return some of the 10 `other→trade` misses
  (lower NOT-FSM precision); realistic net industry gain ~+2-3pts (ceiling ~87-88%; ~7 misses are policy).
- **Applied (C5):** added to the calibration — (a) terse-but-real service text names its trade
  (waste/trash collection→junk_removal, asphalt/paving→general_contracting, service call/labor/repairs→the
  serviced trade); (b) when items are sparse/empty, a business name clearly naming a trade is enough to pick it
  ("sometimes the name is enough" — user), with a guard that product/sector names ('… Industry/Manufacturing/
  Supply/Wholesale/Consulting') stay `other`; items still override on conflict.
- **Result:** industry **net 0 (still 84.5%)** — GAINED 7 (Madison, BV Trash, Helping Hands, D&K Paving, EBEC,
  E.M.T Janitorial, Terry Brian) vs LOST 7 (hauling/consulting/garage-doors edge cases + trade↔trade). The
  errors shuffle laterally — the `other` boundary is genuinely fuzzy. BUT NOT-FSM precision **69→77%** and 5-flag
  macro 0.708→**0.712**, so C5 is kept (recovers the terse-trade cases, honours the name rule, helps NOT-FSM).
- **Ceiling:** industry ≈ **84.5% is the practical ceiling** on this gold (claude only 85.5%). Remaining 31
  misses are genuine ambiguity/policy: automotive (vehicle→other vs human mechanical_service), trade↔trade
  (handyman↔plumbing, security_alarm↔computers_it, renovations↔general_contracting), name-vs-product edges.
  Further industry gains need policy decisions (e.g. allow automotive→mechanical_service), not prompt tweaks.

## F6 — gold correction (automotive→other) + disambiguation tried & REVERTED

- **Gold fix:** the 2 automotive-repair accounts (Next Gen Performance, Harris Custom Automotive) were
  re-labelled by the user from `mechanical_service` → **`other` / none / fsm_fit=no** (vehicle repair is
  out-of-scope; flash was right). Updated in Argilla via `update_gold_responses.py`. not-fsm gold now 60.
- **Disambiguation (#2), broad version — reverted:** "mix of small jobs ⇒ handyman; CCTV ⇒ security_alarm;
  networking/PCs ⇒ computers_it" was **net −4 on industry** (the CCTV split was too blunt — pushed mixed
  cameras+networking accounts to security_alarm) → reverted.
- **Disambiguation, narrowed CCTV (per user) — applied:** "security_alarm only when CCTV/cameras PREVAIL and
  there are no substantial non-security items; mixed cameras+networking ⇒ computers_it". Result vs the no-rule
  build: industry 84.5→**83.5%** (net −2, mostly prompt-noise on unrelated rows), but NOT-FSM precision 77→**80%**
  and 5-flag macro 0.714→**0.725**. CCTV cases now conceptually right (i-view→security_alarm, Dustin/AJ back to
  computers_it/other, Uncommonwebnet stays computers_it). Two residual: `Triple E` (ALPR/plate-reader cameras —
  flash security_alarm defensible, gold computers_it debatable) and `SMIVE` (genuinely mixed CCTV+aerial+audio —
  rule says not-security but the model still picked it: adherence limit, not rule design).
- **Decision: KEPT** the narrowed-CCTV version (user) — correct CCTV handling + better flags (0.725) and NOT-FSM
  precision (80%) outweigh the −1pp aggregate industry. This is the final flash-lite config (C1–C6).

## F7 — store/install rules tried & reverted; run-to-run noise is the real ceiling

- Tried two more rules for appliance/product retailers misrouted to a trade (ESSENTIAL$#HOME# selling
  washers/fridges, WINCARE, TUJENGE): (a) "when product SKUs dominate, treat occasional installation/delivery as
  part of the sale → other"; (b) "a name that could equally be a store/sales business, with no service evidence →
  other". **Both reverted:** neither flipped the target accounts (the model keeps picking the trade — an adherence
  limit, not a wording gap), and together they were net −1 industry from lateral churn.
- **Key lesson:** at this margin Vertex flash-lite **temp-0 re-runs vary ~±1.5pp (~3 accounts)** — the run-to-run
  variance now exceeds any single micro-rule's effect, so further industry tuning via prompt text is not
  productive (can't distinguish signal from noise). Industry gains from here come from **gold quality**, not more
  rules. flash-lite sits at ~86-87% industry vs claude 89%; it leads on flags (0.721 vs 0.685).

---

## Changes applied to the flash-lite call (and measured effect)

### C1 — labour_billing calibration (counters the under-flag)

- **Rationale (user):** this population is dominated by SERVICE businesses; service-style line items are a
  strong indication of labour billing, so flash-lite saying false when parts/products appear is wrong.
- **Change:** flash-lite call only (NOT the shared nano `FsmFitPrompt`): a "FLASH-LITE CALIBRATION" block
  appended to the system instruction + a `labour_billing` `description` on the responseSchema —
  *service-style items ⇒ labour_billing=TRUE even alongside parts; FALSE only for pure goods/parts-only/
  flat-subscription/digital; don't require an explicit 'Labor' line.* (Implemented in the scratchpad
  `run_models.py`; the persistent home is the prod flash-lite path — `flash_lite_run.py` / the Vertex
  client responseSchema.)
- **Measured (200 accounts, before → after):** `labour_billing` true **79 → 178** (99 flips False→True,
  0 reverse). Side effects: industry changed on 16; `complex_multi_line` 70→82 (+12, wrong way — see F1,
  not yet fixed); `scheduling` 56→51; `recurring` 23→32; `contract` 36→33.
- **Status:** loaded into Argilla (non-destructive update; 4 human labels preserved). Needs human
  validation that ~89% labour is right, not a fresh over-flag. The system-prompt addendum also drifts
  industry/other flags a little — if that's unwanted, switch to the schema-`description`-only lever.

### C2 — F1 (complex over-flag) + F2 (materials→other) applied together

- **Change:** added to the flash-lite calibration block + responseSchema descriptions —
  (F1) `complex_multi_line_jobs` = a SINGLE invoice combining labour+parts (avg_line_items ~3+ AND $500+);
  account-level item VARIETY is not evidence; null/≤2 line items ⇒ false. (F2) items predominantly
  goods/materials by the unit ⇒ industry=`other` + all flags false, judged by items not name.
- **Measured (200, before C2 → after):** `complex_multi_line_jobs` **82 → 27** (57 True→False) — F1 over-flag
  largely fixed. `J.G. HARDWARE…SUPPLIES` general_contracting → **other** ✅; `Gmc Pest Control, Sales &
  Rentals` correctly stays `pest_control` ✅ (name keyword didn't misfire). industry changed on 18.
- **Side effects to watch:** `contract_based_billing` rose **33 → 50** (+17) — a KNOWN over-flag getting
  worse (accounts that lost `complex` flipped to `contract`); `WINCARE HOTEL SUPPLY` still `pool_spa_service`
  (borderline, has service items); some materials-sellers kept industry=other but still carry flags (the
  "all flags false" half of F2 is applied inconsistently). Next candidate lever: `contract_based_billing`
  tightening (high amount $2000+ AND 1-3 lines; few lines alone ≠ contract) — already drafted in
  `flashlite-improvement.md` §1.
- **Status:** loaded (non-destructive; 18 labels preserved).

### C3 — non-FSM default when uncertain (precision-over-recall tilt)

- **Rationale (user):** lots of accounts are products, not services / not field-service clients; when uncertain
  with no clear service indication, stick to non-FSM-fit (`other` + no flags).
- **Change:** flash-lite calibration bullet — predominantly-product / weak / ambiguous / sparse evidence ⇒
  `other` + all flags false; assign a trade ONLY on a clear service indication; when unsure between a trade and
  `other`, choose `other`. Worded to KEEP clearly identifiable services (so it doesn't undo the base prompt's
  "don't default to other").
- **Measured (200, before C3 → after):** `industry==other` **63 → 66** (+3; 7 newly→other, 4 left). Flags
  barely moved (labour 173→165). Industry-vs-human (n=22) unchanged at **16/22** — no regression, no net gain
  on the labelled subset.
- **Over-correction watch:** F3 pushed 2 REAL services to `other` — `Godinez Pool Steel LLC`
  (human pool_spa_service) and `Madison` (human junk_removal). The precision tilt costs some recall; keep the
  "clear service ⇒ keep the trade" guard strong.
- **Open flash-vs-human industry misses (n=23 labelled):** TUJENGE KARIAKOO (human other / flash plumbing),
  unnamed (other / security_alarm), WINCARE HOTEL SUPPLY (other / pool_spa_service), PREMIER REVAMP
  (renovations / general_contracting), + the two F3 over-corrections above.
- **Status:** loaded (non-destructive; 23 labels preserved).

### C4 — F4 (other⇒no flags) + relaxed F1 + compaction (best-practice pass)

- **Compaction:** the calibration block was rewritten short + affirmative (≈755 chars) per
  `flashlite-improvement.md` — heavy lifting moved into 5 per-field schema `description`s; no hard "NEVER/NOT"
  stacks. (User: "keep the prompt compact and follow best practices, no hard 'no'.")
- **F4:** enforced as a deterministic runner guard — `if industry=='other': all flags false` — rather than
  negative prompt rules (cleaner, guaranteed). Plus one affirmative prompt line ("an 'other'/product account
  carries no FSM evidence, so its flags stay empty").
- **F1 relaxed:** dropped the hard "avg_line_items null/≤2 ⇒ false" cutoff (it killed recall: many real
  HVAC/plumbing rows have null line-count). New affirmative description: TRUE when one invoice bundles labour
  with parts/materials; variety across the account is not the signal.
- **Measured (vs gold, Δ from C3 round):** on_site_work F1 0.85→**0.90** (FP 44→12 via F4), complex 0.48→**0.62**
  (recall 38→85 via relax), labour precision 78→92%; recurring -0.06; 5-flag macro 0.667→**0.708**.
- **contract_based_billing:** left noisy (F1 0.14) — annotator says it's unreliable, excluded from the headline.
- **Status:** loaded (non-destructive; all 200 labels preserved). This is the current best flash-lite config.
