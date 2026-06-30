# FSM-fit: сводка бенчмарков, сравнения моделей и ручных проверок

Единый компактный обзор всех находок по классификатору **FSM-fit** (Tofu.AI.Backend): какие модели
сравнивались, какими наборами эталонов мерили качество, что показали ручные аудиты и какие выводы приняты.
Подробности — в связанных артефактах (ссылки в каждом разделе и в индексе в конце).

- **Дата свода:** 2026-06-29
- **Продакшн-модель на момент свода:** `gpt-4.1-nano` (temperature 0, strict json-schema, один аккаунт на вызов). **Решение 2026-06-29: переключаем прод на `gemini-2.5-flash-lite`** (Vertex + явный CachedContent, thinking OFF) + промпт v9 — обоснование в §0 (WEB-1525). Готовность к деплою — см. §0.
- **Промпт:** `FsmFitPrompt.cs` — на ветке `feature/fsm-fit-vertex-cached` уже `PromptVersion 9` (`v13-scheduling-calendar`); прод пока на v7-производных.
- **Что классифицируется:** индустрия аккаунта (24 значения из `Industry.cs`) + 6 evidence-флагов
  (`on_site_work`, `scheduling`, `labour_billing`, `recurring_billing`, …) → детерминированный `FsmFitScorer`
  выдаёт score/tier (none/weak/strong) и offer-рекомендацию.

---

## 1. Главные выводы (TL;DR)

1. **Качество моделей близкое, в пределах шума ±8 %** по индустрии на человеческом эталоне:
   `gemini-2.5-flash-lite` ≥ `gemini-2.5-flash` ≥ `gpt-4.1-nano` (86 % / 85 % / 83 %, n=131).
2. **На сложных гомонимных кейсах (48-acct balanced set, v7)** Flash-Lite заметно лучше nano:
   acc 94 % vs 83 %, precision 92 % vs 79 %, и стабильнее. `gpt-4.1-mini` посередине (90 %).
3. **Тир модели — больший рычаг, чем доводка промпта.** Переход nano→mini дал больше, чем v5→v7;
   v5→v7 на nano даёт лишь маржинальный прирост (FP 8→6, acc 81→83 %).
4. **Цена:** при идентичных листинговых ставках реальная стоимость зависит от кэша и «мышления».
   `gpt-4.1-nano` ~$0.17/1k (тёплый кэш) — самый дешёвый; `flash-lite` достигает паритета **только** с
   явным кэшем и thinking OFF; thinking на Gemini быстро удорожает (до ×5).
4a. **★ Рекомендуемая дешёвая конфигурация: `flash-lite` + явный Vertex `CachedContent` + thinking OFF.**
   Через прямой Vertex API (не in-BQ) это даёт хорошее качество (industry concordance к nano 92 %, и gemini
   при этом БОЛЕЕ промпт-верен, чем nano на on-site) при цене **$0.266/1k — фактический паритет с nano**,
   детерминированный кэш (100 % префикса), `thoughtsTokenCount=0`. Это и есть «без thinking, но хорошо».
   ⚠️ Не путать с **in-BQ `AI.GENERATE`** flash-lite `thinking_budget=0`, который ломается (43 % parse-fail) —
   это другой surface (см. §4.2 vs §4.3).
5. **Ручные аудиты:** «утечки» индустрий (landscaping/cleaning) на ~90 % оказались артефактом regex-тегов,
   а не ошибкой модели. nano ~91 % даже на самых сложных пограничных кейсах.
6. **Промпт под 3A-границу не тюнить:** позитивные переписывания и переусиление business_name дали net-zero
   с регрессиями контролей. Источник ошибок — слабая модель и неоткалиброванный score, не формулировки.
7. **`thinking_budget=0` небезопасен только на in-BQ `AI.GENERATE` / flash** (parse-fail + недодетекция on-site).
   На **прямом Vertex API flash-lite по умолчанию thinking уже OFF и работает чисто** (см. 4a/§4.3). Если
   thinking всё же включать на in-BQ — минимум для flash-lite = 512 (значения <512 молча игнорируются → dynamic).
8. **★ WEB-1525 (latest): на трудном seed из 236 аккаунтов flash-lite ОБХОДИТ nano** — industry 78 % vs 65 %,
   `recurring_billing` 95 % vs 61 %, `on_site_work` 85 % vs 72 % (vs claude-gold). А после исправления
   определения `scheduling` (= «выиграет ли бизнес от календаря визитов») **flash-lite 90 % vs nano 56 %** —
   прежнее «flash-lite переусиливает scheduling» оказалось артефактом узкого определения. Итог: **flash-lite —
   модель выбора для прода** (см. §0).

---

## 0. ★ WEB-1525 (2026-06-29, latest) — flash-lite на трудном seed + переопределение `scheduling`

Самое свежее и решающее сравнение: специально собранный **трудный seed из 236 прод-аккаунтов** (200
difficulty-стратифицированных по всем 24 индустриям + 36 sparse/name-only), размеченный claude-судьями как gold,
прогнан тремя арками — прод `gpt-4.1-nano`, `gemini-2.5-flash-lite` (Vertex, thinking OFF), и claude-gold как
референс. Полный разбор: `web-1525-fsmfit-seed/` (README, `compare3.json`, `scheduling-v8-test.md`).

**Трёхстороннее сравнение (vs claude-gold; concordance, не человеческая истина — её даёт Argilla-проход):**

| ось | nano | flash-lite | вывод |
|---|---|---|---|
| **industry, все 236** | 65 % | **78 %** | flash-lite (чинит 44 ошибки nano, теряет 13) |
| industry, уверенные (102) | 91 % | 92 % | ~ничья — преимущество flash-lite на **трудном хвосте** |
| **recurring_billing** | 61 % (over 92 / under 0) | **95 %** | flash-lite — нет nano-бага recurring-on-reactive-trade |
| on_site_work | 72 % | **85 %** | flash-lite (nano недодетектит on-site) |
| complex_multi_line | 86 % | 87 % | ~ничья |
| labour_billing | **80 %** | 69 % | nano — flash-lite недоставляет labour |
| contract_based | **88 %** | 76 % | nano — flash-lite переусиливает |

**Переопределение `scheduling` (ключевая находка).** Продуктовый смысл флага = «**аккаунт выиграет от календаря
визитов в приложении**» (подтверждено скорером: `Scheduling && OnSiteWork → ScheduleVisits` offer), а промпт v7
определял его узко («один визит ≠ scheduling»). Переписали определение (тест-промпт → прод `v9`/`v13-scheduling-calendar`)
и переразметили все 236 тремя арками:

| арка | scheduling TRUE v7 (узкое) | TRUE v9 (calendar) | acc vs claude-v9 |
|---|---|---|---|
| claude (референс) | 14 % | 90 % | — |
| **flash-lite** | 33 % | **88 %** | **90 %** (over 9 / under 14) |
| nano | 31 % | 50 % | **56 %** (under 100) |

Под корректным определением **flash-lite — лучший (90 %)**, а **nano недоставляет scheduling=true у 100 реальных
выездных бизнесов** (carpet cleaning, appliance-install, on-site IT, electrical, flooring), оставаясь буквальным
даже на новом промпте. Значит «flash-lite переусиливает scheduling» было **артефактом определения**, а не слабостью
модели; остаточные 9 over flash-lite — только ритейл/продукт edge-кейсы.

**Остаточные биасы flash-lite** (vs claude-gold): недоставляет `labour_billing`, переусиливает `contract_based_billing`.
Они уходят на **человеческий Argilla-разбор** (`fsm-fit-web1525-flashlite-flags`, 145 кейсов) — там же подтвердится,
не переусиливает ли местами сам claude-судья.

**Как улучшать flash-lite дальше** (`flashlite-improvement.md`, по веб-best-practices): per-field `description` в
responseSchema (точное правило флага прямо в схеме), `reasoning` первым полем (reason-before-commit), опц.
`thinking_budget 512`, flag-level few-shot. Перепроверять против человеческого gold, не claude-gold.

**Решение и готовность к проду:** переключаем прод на **flash-lite + v9**. Код готов (ветка
`feature/fsm-fit-vertex-cached` ребейзнута на `feature/FS-1241`, flash-lite+CachedContent уже сконфигурирован,
сборка зелёная). **Два прод-действия остаются** (иначе flash-lite не заработает): (1) выдать `roles/aiplatform.user`
именно SA `tofu-ai-backend@inv-project` (сейчас оно ошибочно у `tofu-auth-backend`); (2) добавить
`Analyses:Llm:Provider="Vertex"` в GSM-секрет `tofu-ai-api-secret`. Bump PromptVersion 8→9 → полная переразметка
прода на первом тике (cost-событие).

---

## 2. Эталонные наборы (gold / labelled sets)

| Набор | n | Состав | Как размечен | Где |
|---|---|---|---|---|
| **Gold eval set** | 140 | по 1 на (industry × tier), все 24 индустрии, баланс 42 none / 49 weak / 49 strong | consensus 3 моделей + ручная адъюдикация + Argilla `human_reviewed` | `bq-batch-fsm-fit/eval/gold.jsonl` |
| **48-acct labelled** | 48 | 24 genuine-3A / 24 подтверждённых не-3A гомонима | ручная разметка | `fsmfit-v5-3a-audit/eval_gt.json` |
| **3A contested** | 65 | самые спорные пограничные кейсы cleaning/lawn/landscaping | Argilla `fsm-fit-3a-contested` | `bq-batch-fsm-fit/eval/gold_3a.jsonl` |

- Первичный сигнал в эталоне — `item_names` (топ позиции по count); `top_notes` НЕ хранятся (PII: адреса, реквизиты).
- **`item_names` PII-чувствительны** → файлы `gold*.jsonl` / `gold_inputs.csv` держать приватными, не публиковать.
- Lifetime invoice count берётся из BQ-зеркала `inv-project.ai_analysis_us.invoices` (`invoice_counts.sql`).
  Из 140: все ≥1 инвойс, 11 ровно 1, остальные ≥2.
- **Argilla-петля:** `build_argilla_review.py` → `load_to_argilla.py` → ревью в UI → `export_from_argilla.py`
  (→ `gold.refined.jsonl`). Локальный сервер: `C:\Git\_scratch\argilla` (UI `localhost:6900`).
- **Методологическое замечание:** majority-of-3 gold вводит в заблуждение (flash+lite разделяют биасы, поэтому
  он завышает lite 95 % / flash 90 % / nano 81 %). Человеческая адъюдикация 48 расхождений схлопнула разрыв
  почти до паритета — доверять только `gold_industry` (human-adjudicated).
- **nano — плохой референс:** concordance «vs nano» занижает реальную близость; истинную точность дают только
  размеченные вручную сиды.

---

## 3. Сравнение моделей — качество

### 3.1. 48-acct balanced (v7, 5 повторов, majority vote) — `fsmfit-v5-3a-audit/model-comparison.md`

| модель (v7) | accuracy | FP (гомоним остался в 3A) | FN | recall | precision | нестаб. /48 |
|---|---|---|---|---|---|---|
| gpt-4.1-nano (prod) | 83 % | 6 | 2 | 92 % | 79 % | 5 |
| gpt-4.1-mini | 90 % | 3 | 2 | 92 % | 88 % | 1 |
| **gemini-2.5-flash-lite** | **94 %** | **2** | 1 | **96 %** | **92 %** | 2 |

Вердикт: **Flash-Lite — лучший вариант** (выше mini по качеству, по цене nano). Ранг: Flash-Lite > mini > nano.

### 3.2. Concordance nano vs flash-lite (100-acct recurring-offer cohort, prompt v7)

NB: это concordance к nano-как-референсу, НЕ accuracy. No-thinking: TIER 86 %, INDUSTRY 92 %, OFFER 78 %.
Большинство расхождений на флагах — `labour_billing` (nano поголовно ставит 1 на cleaning/lawn, gemini
консервативен) и `on_site_work`, где **nano даёт false-negative** на очевидной on-site работе (адреса в
позициях) → gemini здесь более промпт-верный, не «переусердствует». thinking@512 не чинит инфляцию тира —
улучшает только labour_billing и чуть industry (92→95 %) ценой ~×2.

---

## 4. Сравнение моделей — цена и надёжность

### 4.1. Стоимость на gold (per 1k accounts) — `bq-batch-fsm-fit/eval/README.md`

| Модель / режим | $/1k | надёжность |
|---|---|---|
| gpt-4.1-nano (тёплый кэш ~64 %) | **~$0.17** | clean |
| gpt-4.1-nano (cold) | ~$0.32 | clean |
| gemini-2.5-flash-lite + thinking 512 | **$0.48** | 0 fails / 120 |
| gemini-2.5-flash thinking-off (budget 0) | ~$1.04 | parse-fail на части промптов |
| gemini-2.5-flash thinking-on | **$5.57** | clean |

Gemini 2.5 — *thinking*-модель: flash тратит ~1800 «thoughts»-токенов, биллящихся как output по высокой ставке
(~80 % стоимости) на задаче, не требующей рассуждений. nano не-thinking (~85 токенов ответа) + кэширует ~64 %
префикса. `thinking_budget: 512` на flash-lite — sweet spot (дёшево + надёжно).

### 4.2. flash-lite × thinking_budget sweep — путь **in-BQ `AI.GENERATE`** (120 acct)

⚠️ **Важно: это in-BQ `AI.GENERATE`-surface**, не прямой Vertex API. Именно здесь `budget=0` ломается. На
прямом Vertex API (§4.3) flash-lite без thinking работает чисто — не путать.

| budget | parse-fails | avg think tok | $/1k | industry acc |
|---|---|---|---|---|
| 0 | **51/120** | 0 | $0.37 | 75 % (выживших) |
| **512** | 0 | 383 | **$0.46** | 81 % |
| 1024 | 0 | 736 | $0.60 | 79 % |
| 2048 | 0 | 1764 | $1.01 | 87 % |
| dynamic (−1) | 2 | 2841 | $1.44 | 82 % |

`0` сломан (43 % parse-fails) **на in-BQ-пути**; `512` — оптимум; `2048` даёт лучшую точность, но ×2 и в пределах шума.
**Гоча:** минимум для flash-lite = 512; значение ниже (напр. 100) молча игнорируется → fallback в dynamic
(~1500 think-токенов, ~$0.88/1k). «Дешёвого 100-токенового thinking» на flash-lite не существует.

### 4.3. Прямой Vertex API: flash-lite без thinking + явный кэш (v7, 100-acct cohort) — scratchpad `fsmfit-price-bench/`

**Это рекомендуемый surface (см. TL;DR 4a).** flash-lite через прямой Vertex API по умолчанию идёт **без
thinking** (`thoughtsTokenCount=0` на всех 100, parse-fail НЕ наблюдался) → дёшево и чисто.

Байт-идентичный вход обеим моделям, реальный usage → $/1k:
- **gpt-4.1-nano $0.286/1k vs gemini-2.5-flash-lite $0.566/1k** (gpt ≈ ×2 дешевле; industry agreement 92 %).
- Причина при равных ставках ($0.10/$0.025 cached/$0.40 за 1M): OpenAI явным `prompt_cache_key` кэширует ~63 %
  входа, у Gemini *неявный* кэш в Vertex для flash-lite фактически НЕ включается (`cachedContentTokenCount=0`
  на 83/99 параллельно и 0/20 последовательно). Лечится **явным Vertex `CachedContent`** (region-bound,
  us-central1) → кэш 100 % префикса детерминированно.
- **Cache-vs-cache (правильные cached-ставки):** gpt-4.1-nano $0.219–0.274/1k (шумно, implicit-кэш OpenAI зависит
  от прогретости) vs gemini-flash-lite $0.266/1k → **фактический паритет**. Остаточный разрыв теперь в output
  (Gemini эмитит ~67 % больше выходных токенов), не в кэше.
- Хранение Vertex CachedContent = $1.00/1M tok/час → наш 3758-tok кэш ≈ $2.74/мес 24/7, на непрерывном
  5-мин тике пренебрежимо.

### 4.4. Thinking-лестница для flash-lite (явный кэш, 100 acct)

OFF=$0.266/1k (~паритет с nano) | budget 512 → ~385 think tok → **$0.417/1k (~×2)** |
dynamic(-1) → ~2476 think tok → **$1.247/1k (~×5.2)**. thinking биллится по output-ставке и затмевает ответ.
Вывод: на прямом Vertex API thinking — **неверный рычаг**: OFF уже даёт хорошее качество за паритетную цену,
а budget 512 не чинит инфляцию тира (см. §4.5) и удваивает цену.
Caveat: страшилка «thinking нужен для качества» (parse-fail + недодетекция on-site при budget=0) установлена на
gemini-2.5-**flash** / in-BQ-пути, НЕ на flash-lite через прямой API — там OFF работает чисто.

### 4.5. Качество flash-lite БЕЗ thinking (concordance к nano, 100-acct cohort v7) — `QualityReport`

NB: concordance к nano-как-референсу (не accuracy; gold-точность даёт только размеченный вручную gold — см. §0/§2). **NO-THINKING:** TIER 86 %,
INDUSTRY 92 %, OFFER 78 %. Разбор реальных расхождений (`bench-disagreements.txt`):
- бóльшая часть флаговых расхождений — `labour_billing`, где **тир одинаков** (nano поголовно ставит 1 на
  cleaning/lawn, gemini консервативен) — несущественно;
- реальные тир-флипы, где gemini выше, — это **false-negative nano на `on_site_work`** (nano ставит 0 на
  очевидной on-site cleaning с адресами/«AirBNB clean», нарушая собственное правило промпта «адрес = on-site»);
  gemini корректно ставит 1 → **gemini промпт-вернее**, не «переусердствует»;
- gemini даже исправил ошибку индустрии (NDIS support: nano=home_theater, gemini=other).
- **Ни одного кейса, где gemini был бы явно неправ.**

**thinking@512 НЕ улучшает тир/offer** (on_site_work идентичен, всё ещё никогда `none`) — лечит только
labour_billing concordance + чуть industry (92→95 %), ценой ×2 и 1 потерянного аккаунта (output-truncation).
Поэтому для паритета с nano по тиру/offer thinking бесполезен. Артефакт: `bench-quality.csv`.

---

## 5. Эволюция и оценка промпта (v5 → v6 → v7)

- **Аудит после v5 (102 acct)** — `fsmfit-v5-3a-audit/README.md`: genuine 56 (55 %), borderline 32 (31 %),
  **false_positive 14 (14 %)**. Среди score ≥0.95 — 43 % всё ещё borderline/FP (score неоткалиброван).
  Корень: правило v5 «не дефолти в other» затаскивало out-of-scope (auto detailing, прачечная, оптовая) в 3A.
- **Cohort-wide audit** — `cohort-wide-audit.md`: v3 FP ~1.3 % (2/150), v5 FP 14 %; оценка ~29 FP + ~160 borderline
  на 1705 активных подписок.
- **v6 eval (на 102 FP-кейсах v5)** — `v6-eval-results.md`: держит 50/56 genuine, сбрасывает 14/14 FP, 16/32 borderline.
- **v6 на полном когорте (1705)** — `v6-full-cohort-run.md`: сбрасывает 143 (8.4 %), оставляет 1562 (91.6 %).
  Drop-rate по предыдущей версии: v3 7.2 %, v4 10.2 %, **v5 21.3 %** (подтверждает, что v5 натаскал гомонимов).
- **v7 на Claude-судье (48 acct)** — `v7-ab-results.md`: v7=100 %, v5=98 %, v6.2=94 %. ⚠️ **Ceiling-effect
  артефакт** — судья слишком силён; валиден только относительный ранг.
- **v7/v5 на РЕАЛЬНОЙ prod-модели (nano, 48 acct)** — `nano-ab-real-results.md`: v5 81 % → v7 83 % (маржинально);
  v7+mini = 90 %/precision 88 %. **Вывод: тир модели — главный рычаг, не промпт.** Всегда A/B на prod-модели.
- **Best practices** — `prompt-refinement-best-practices.md`: few-shot > hard-negatives; позитивная процедура >
  стены ограничений; evidence-gates; ≥10 повторов для валидации.

---

## 6. Качество 3A-классификации (ручная адъюдикация) — `Local.Docs/features/FS-1241/3a-classification-quality.md`

Вопрос: «утекают» ли lawn-care аккаунты в `landscaping` (и lawn/cleanup в `cleaning`)?

- **Regex-оценка утечки завышена** («40 % landscaping → lawn, 22 % без design», «утечка в cleaning») — артефакт
  тегирования (слово `maintenance`/`cleanup` засчитывалось как lawn-сигнал).
- **Argilla-адъюдикация 65 contested:** nano = **59/65 = 90.8 %** на самых сложных кейсах.
  `cleaning_has_lawn` 20/20 (нулевая реальная утечка), `landscaping_has_lawn` 28/30, `lawn_has_design` 11/15.
- 6 ошибок **симметричны** (lawn→landscaping 3 vs landscaping→lawn 2) — пограничный шум, не однонаправленная утечка.
- **Промпт-A/B (позитивная переписка границ + few-shot):** net-zero с регрессией контроля (39 acct, 1 на вызов).
- **business_name «strong» A/B:** OLD 53/65 = NEW 53/65, net-zero, 3 флипа. **Не переусиливать business_name.**
- **Вывод: не тюнить промпт под 3A-границу** — реальная ошибка низкая и несистематическая.

---

## 7. Нюансы и гочи (ground для будущих прогонов)

- **Недетерминизм nano велик:** один и тот же промпт+вход даёт разные вердикты (4–5/48 флипают между
  идентичными прогонами). Один проход не авторитетен; majority-vote ≥3 для пограничных. mini почти стабилен.
- **Не батчить много аккаунтов в один classifier-промпт** — кросс-контаминация причин между аккаунтами
  (143-acct-per-call дал галлюцинации). Классифицировать по одному (как prod) или малыми батчами.
- **Для аудита брать полный набор позиций** (`ai_analysis_us.invoices.item_names`), не усечённый `top_item_names`.
- **gpt-4.1-mini** — крупнейший доступный рычаг точности (FP 6→3, precision 79→88 %, стабильность 5→1),
  ценой ×4 листинга; FSM-fit периодический батч → дельта вероятно приемлема.
- `~0.3–0.5 %` ответов nano обрезаются на `$.specialization` ~255 байт (взаимодействие с `maxLength:60` в strict-схеме).

---

## 8. Индекс артефактов

### Бенчмарки и сравнения моделей
- **`Investigations/web-1525-fsmfit-seed/` (★ latest)** — трудный seed 236, 3-way nano/flash-lite/claude-gold:
  `README.md`, `compare3.json` (industry+флаги), `scheduling-v8-test.md` (переопределение scheduling),
  `compare_scheduling.json`, `flashlite-improvement.md`, `gold_seed.jsonl`, Argilla-наборы
- `Investigations/fsmfit-v5-3a-audit/model-comparison.md` — nano vs mini vs flash-lite (v7, 48 acct)
- `Investigations/fsmfit-v5-3a-audit/nano-ab-real-results.md` — v5/v7/mini на реальном nano
- `Investigations/bq-batch-fsm-fit/eval/README.md` — bake-off на gold (140), цена + thinking sweep + качество
- scratchpad `fsmfit-price-bench/` — воспроизводимый прайс-бенч (v7, кэш, thinking-лестница, QualityReport)

### Оценка промпта
- `Investigations/fsmfit-v5-3a-audit/v7-ab-results.md` — v5/v6.2/v7 на Claude-судье (⚠️ ceiling effect)
- `Investigations/fsmfit-v5-3a-audit/v6-eval-results.md`, `v6-full-cohort-run.md`, `v6-validation-combined.md`,
  `v6.1-homonym-rules.md`, `v6-prompt-and-guard.md`, `v6_beforeafter.md`
- `Investigations/fsmfit-v5-3a-audit/prompt-refinement-best-practices.md`
- Тексты промптов: `v6_prompt.txt`, `v6.2_prompt.txt`

### Ручные аудиты
- `Investigations/fsmfit-v5-3a-audit/README.md` — аудит 102 acct после v5
- `Investigations/fsmfit-v5-3a-audit/cohort-wide-audit.md` — v3-sample (150) + полный v5-когорт
- `Investigations/fsmfit-v5-3a-audit/audit_all102.md`, `sample50_detail.md`, `diffs-manual-check-and-noise.md`
- `Local.Docs/features/FS-1241/3a-classification-quality.md` — leak-investigation + Argilla 65

### Эталоны и Argilla
- `Investigations/bq-batch-fsm-fit/eval/gold.jsonl` (140, канон), `gold.refined.jsonl`, `gold.full140.jsonl`
- `Investigations/bq-batch-fsm-fit/eval/gold_3a.jsonl` (65 contested), `gold_inputs.csv`, `invoice_counts.sql/json`
- Скрипты: `build_argilla_review.py`, `load_to_argilla.py`, `export_from_argilla.py`,
  `load_3a_contested.py`, `export_3a_contested.py`, `append_3a.py`, `apply_recurring_rule.py`
- `_stats.json` / `_stats.refined.json` / `_stats_3a.json` — сводные метрики

### Данные результатов (JSON)
- `Investigations/fsmfit-v5-3a-audit/verdicts.json` (102 адъюдикации), `all102.json`, `v6_results.json`,
  `v6_all1705_relabel.json`, `drops_fulldata.json`, `v3sample.json`, `run15_{A,B,C}.json`

### Документация и планы
- `Tofu.AI.Backend/Docs/features/bq-batch-fsm-fit/plan.md` (+ `plan-ru.md`) — LLM в BigQuery (`AI.GENERATE`)
- `Local.Docs/features/WEB-1523-segmentation/analyses/fsm-fit/{training,scoring,prompt,analytics-events,industry-expansion}.md`
- `Local.Docs/features/FS-1241/{README,top-items-3a-industries,recurring-pattern-funnel}.md`
- `Tofu.AI.Backend/Docs/features/WEB-1555/{impl-design,bq-migration-spike,bq-tables-build-plan}.md`
