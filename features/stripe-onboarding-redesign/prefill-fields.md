# Префилл: поля, источники, нюансы

Пофайловая карта того, что мы можем положить на Stripe Account при создании: откуда берём данные, есть ли они у нас вообще и что в каждом поле неочевидно. Родительский док: [README.md](README.md); воронка на проде — [prod-funnel.md](prod-funnel.md); семантика требований — [stripe-requirements.md](stripe-requirements.md).

> **Разметка источников.** `[тест]` — проверено на тестовой Connect-платформе спайком [`Investigations/stripe-onboarding-prefill`](../../../Investigations/stripe-onboarding-prefill/README.md) (2026-07-15) · `[прод]` — замер на 21 489 live-аккаунтах · `[дока]` — цитата из документации Stripe · `[код]` — прочитано в исходниках · `[инференс]` — вывод, а не измерение · `[ресёрч]` — унаследовано из [research.md](research.md), **мной не проверялось**.

Напоминание, которое красит всю таблицу: **окно префилла закрывается первым Account Link или Account Session**. Всё, что ниже, должно лечь на аккаунт до его выпуска.

## Данные у нас есть

| Поле Stripe | Наш источник | Нюанс |
|---|---|---|
| `individual.first_name`<br>`individual.last_name` | `Account.Contacts.Name`, `Tofu.Auth User.Name` `[код]` | **Обе — одна строка**, деления нет нигде. См. «Имя» ниже |
| `individual.email` | `Contacts.Email`, `Tofu.Auth User.Email` `[код]` | Не путать с верхнеуровневым `email` `[тест]`. См. «Два email» |
| `individual.phone` | `Contacts.Phone` `[код]` | Stripe сам нормализует в E.164 `[тест]`. См. «Телефон» |
| `business_profile.mcc` | `BusinessProfile.Industry`, 26 значений `[код]` | Валидируется по списку Stripe `[тест]`. См. «Industry → MCC» |
| `business_profile.product_description` | из ниши / `Industry` | Требования к содержанию — см. «Описание» |
| `country`, `business_type` | константы `US` / `individual` | Единственные безопасные: **не** отключают networked onboarding `[дока]` |

## Данных у нас нет

| Поле Stripe | Что с ним | Нюанс |
|---|---|---|
| `business_profile.url` | **мы его не храним** — но у бизнесов он есть | 99.6% подключённых сайт указали `[прод]`. Посылка «сайта нет ни у кого» из [research.md](research.md) неверна. См. «Сайт» |
| `individual.dob` | нужен сбор на клиенте | Токенизации нет — пройдёт через бэкенд открыто `[тест]` |
| `individual.address.*` | `Contacts.Address` **не подходит** `[код]` | Free-text и это **бизнес**-адрес, а Stripe нужен структурированный домашний. См. «Адрес» |
| `individual.ssn_last_4` | нужен сбор на клиенте | Достаточно последних 4 цифр `[тест]`. См. «SSN» |
| `individual.id_number` | полный SSN | Нужен **только** при эскалации `[тест]`. См. «SSN» |
| `tos_acceptance.date/ip` | недоступно | Только на application-модели, которую мы отвергли `[дока]` |
| `external_account` | банк | Пред-прикрепляется токеном `btok_`, требование снимается полностью `[тест]` — но реквизитов у нас нет, а Stripe даёт instant-connect через Link |

## Сайт (`business_profile.url`) — что указывают те, кто дошёл

**Посылка ресёрча «сайта у нас нет → официальный путь `product_description`» неверна** `[прод]`. Первая половина верна только про **наше хранилище**. Замер по всем подключённым аккаунтам за историю (22 066):

| | аккаунтов | доля |
|---|---:|---:|
| **указали `url`** | **22 044** | **99.9%** |
| свой сайт | 13 802 | 62.6% |
| **Instagram** | 3 547 | **16.1%** |
| **Facebook** | 3 122 | **14.2%** |
| Wix / GoDaddy / Squarespace | 518 | 2.3% |
| TikTok / LinkedIn / Google / Yelp / Thumbtack / Nextdoor | ~940 | 4.3% |
| **наш домен (`tofu.com`, `app.tofu.com`)** | **93** | 0.4% |

**Треть мерчантов проходит с соцпрофилем** — 6 681 работающий аккаунт на Instagram или Facebook, из них `url` в `past_due` только у **девяти** (99.87% успеха). Никакого сайта у них нет и не требуется.

**Вывод для копирайта** `[инференс]`: спрашивать надо не «Your website», а **«где вас можно найти в интернете»** — с примерами: Instagram, Facebook, Google-профиль, Thumbtack. Люди это дают. Проблема не в отсутствии веб-присутствия, а в названии поля: сейчас его пропускают **93% начавших** `[прод]`, и 564 аккаунта стоят мёртвыми с `url` как единственной просрочкой (см. [prod-funnel.md](prod-funnel.md), вывод 3).

### Наш домен: 93 работающих аккаунта `[прод]`

Люди уже вписывают его сами — от растерянности. Все **93** — `charges_enabled=true`, 88 с включёнными выплатами, **`url` в `past_due` — у нуля, url-ошибок — ни одной**. Форматы: `https://tofu.com` (24), `tofu.com` (21), `app.tofu.com` (16), варианты с `www` и капсом; **лишь 4** указали персональную страницу вида `tofu.com/invoices/{id}` или `/estimates/{id}`.

Контроль: всего наш домен указали 163 аккаунта, из них подключились 93 (**57%** против 48% у всех, кто открыл форму) — то есть это не токсичное значение.

**Но подставлять его автоматически — не решение** `[дока]`. У `url` десять кодов ошибок, и первый бьёт прямо сюда:

| код | описание |
|---|---|
| `invalid_url_denylisted` | «Generic business URLs aren't supported» |
| `invalid_url_website_business_information_mismatch` | «The business information on your website must match the details you provided to Stripe» |
| `invalid_url_website_incomplete` | «Your website seems to be missing some required information» |
| `invalid_url_website_inaccessible` / `_empty` / `_geoblocked` / `_password_protected` | сайт недоступен / пуст / заблокирован / под паролем |
| `invalid_url_web_presence_detected` | «Because you use a website, app, social media page… you must provide a URL» |
| `invalid_url_format` | «URL must be formatted as https://example.com» |

Голый `tofu.com` — ровно то, что Stripe называет generic URL платформы. Что 93 аккаунта прошли, значит лишь, что проверка **пока** не придирается; гарантии нет. Плюс подводный камень `[дока]`: **не все URL-ошибки чинятся через API** — часть требует переписки с саппортом, то есть тихая проблема превратится в застрявший аккаунт, который мы сами разблокировать не сможем.

**Честный вариант — персональная страница**, как у тех четверых: `tofu.com/invoices/{id}`. Формулировка Stripe — *«presence on the web that shows what you are accepting money for»* — описывает именно её. Так же выкручивается [Sharetribe](https://www.sharetribe.com/help/en/articles/9453619-troubleshoot-stripe-errors), подставляя URL маркетплейса. Открытые вопросы: есть ли у веб-линка стабильный per-account адрес (`WebLinkOptions.BaseHost` есть, но линк, похоже, per-invoice), и подойдёт ли он Stripe — обе их support-страницы на этот счёт отправляют в саппорт: *«If you do not have a website or presence on the web that shows what you are accepting money for, contact support»*.

> ⚠️ **`example.com` подставлять нельзя.** Это `invalid_url_denylisted` + заявление от имени пользователя, что у бизнеса есть сайт, которого нет. M2 в ТЗ — ровно этот сценарий, уже случившийся с пользователями вручную: placeholder → аккаунт «Incomplete».

> `[ресёрч, не проверено]` В [research.md](research.md) сказано, что слабый или фейковый URL хуже честного описания, и упомянуты ~5 диспутов `url_inquiry.form`. Кода `url_inquiry.form` в `requirements.errors` по всем 21 489 аккаунтам **нет вовсе** `[прод]`.

## Нюансы

### SSN: последних 4 цифр достаточно

Главное, что стоит знать до продуктового решения: **полный SSN не нужен**. Если на аккаунте есть имя, DOB и адрес, то `individual.ssn_last_4` закрывает требование целиком — `individual.id_number` в `currently_due` не появляется, `verification.status` уходит в `pending`.

Проверено и обратное: если послать `ssn_last_4` на **пустой** аккаунт (без имени/DOB/адреса), Stripe не может провести верификацию и требует уже **полный** `id_number`. То есть частичный префилл делает хуже, чем никакого: просим у пользователя данные и всё равно получаем эскалацию.

Полный SSN остаётся сценарием эскалации: если верификация не прошла, Stripe добавит `individual.id_number` в требования позже, и это надо уметь обработать (ремедиация через повторный вход в форму).

Если полный SSN всё же понадобится — его можно не показывать бэкенду: publishable-ключом создаётся PII-токен (`pii_…`), он принимается вместо номера в `individual[id_number]`. Проверено: `id_number_provided: true`. Для `ssn_last_4`, DOB и адреса токенизации нет.

Обратно Stripe номер не отдаёт никогда — только флаги `ssn_last_4_provided` / `id_number_provided`.

### Описание: API его не валидирует

`[тест]` API принимает и короткое: `Handyman` (8 символов) проходит без ошибки.

`[ресёрч]` Ограничение ≥10 символов и ошибка валидации — это находка коридорного теста M3 из ТЗ; **сам я форму на этом не проверял**. Сопоставление двух фактов даёт `[инференс]`: валидация живёт в форме, а не в API, и префилл от неё не спасает — короткое описание доедет до формы и пользователь упрётся в ошибку там.

`[дока]` Отдельно и важнее длины — требование к **содержанию**, если описание идёт вместо сайта: «must detail the type of products being sold, **as well as the manner in which the business charges its customers**». То есть шаблон обязан называть и что продают, и как берут деньги: «On-demand home repair, billed to clients after each job», а не «Handyman».

Вывод `[инференс]`: длину и содержание проверяем на своей стороне до отправки.

### Имя: одна строка у нас, две у Stripe

Ни `Account.Contacts.Name`, ни `User.Name` в Auth не разделены на имя и фамилию — Stripe требует `first_name` и `last_name` отдельно.

**Чем оплачивается ошибка деления.** Никакой документ при этом не загружается: Stripe сверяет введённые данные со своими источниками — «Stripe might be able to verify an account by **confirming some or all of the keyed-in data provided**» ([identity-verification](https://docs.stripe.com/connect/identity-verification)). Каких именно источников — доки не называют. Практически имя должно совпадать с юридическим именем человека в официальных записях.

Если сверка не сошлась, пользователь **не видит ошибки на экране**: аккаунт уходит с кодом `verification_failed_keyed_identity` (152 случая на проде), и Stripe просит скан документа **асинхронно, днями позже**, когда человек давно закрыл приложение. То есть неверное деление оплачивается не мгновенной валидацией, а тихим запросом фото через неделю.

Автоматическое деление по пробелу ломается на составных фамилиях, отчествах и на тех, кто вписал в поле название бизнеса. Варианты: спросить два поля на клиенте, либо делить и обязательно показывать результат на подтверждение.

> ⚠️ Формулировка «данные должны совпадать с гос. документами» — это копирайт **Kickstarter** ([help](https://help.kickstarter.com/hc/en-us/articles/115005139673), цитата в [research.md](research.md#L262)), а не требование Stripe. Как коучинг для экрана S2 она хороша, но выдавать её за правило Stripe нельзя: документа в 99.2% случаев не существует.

### Два email

`individual.email` — это KYC-поле, его читает форма. Верхнеуровневый `email` — справочное поле объекта Account: *«It's not used for authentication and Stripe doesn't market to this field»*. Значения не перетекают ни в одну сторону: задали только верхнеуровневый — `individual.email` остаётся в `currently_due`; задали только `individual.email` — `account.email` остаётся пустым. Для C2/M1 нужен **только** `individual.email`.

### Телефон

Stripe нормализует сам при `country=US`: `(555) 123-4567`, `555-123-4567` и `+1 555 123 4567` одинаково сохраняются как `+15551234567`. Отвергается только заведомый мусор (`12345` → «not a valid phone number»). Наш free-text `Contacts.Phone` можно слать как есть.

### Адрес

`Contacts.Address` не годится по двум причинам сразу: это одна строка, а Stripe нужен структурированный (`line1` / `city` / `state` / `postal_code`); и это адрес бизнеса, тогда как при `business_type=individual` поле `individual.address` — **домашний** адрес представителя. Подстановка бизнес-адреса вместо домашнего — это готовый провал верификации.

### Industry → MCC

Industry в форме Business details — это `business_profile.mcc`. Валидный код снимает требование. Stripe проверяет коды по своему списку: `9999`, `0000`, `abcd` отвергаются с «Not a valid merchant category». Предложенный маппинг всех 26 наших индустрий — в `INDUSTRY_MCC` (`wwwroot/index.html` спайка), все коды в нём приняты. **Какой код положен какому ремеслу — решение продукта и комплаенса**: форма прямо пишет, что выбор индустрии обслуживает risk and compliance obligations. Спорные места — `painting`, `pool_spa_service`, `junk_removal`, `security_alarm`.

### Префилл ≠ поле исчезло

Заполненное Stripe не спрашивает, но показывает на подтверждение перед принятием ToS — это видно на живой форме: префилленный `product_description` приезжает в текстовое поле редактируемым. Полностью поле пропадает, только когда уже **верифицировано**, а верификация асинхронная и на момент выпуска линка ещё `pending`.

### Точка невозврата — выпуск линка, а не финиш формы

`[дока]` Правило сформулировано прямо ([standard-accounts](https://docs.stripe.com/connect/standard-accounts)):

> After you create an **account link** on a Standard account, you won't be able to read or write Know Your Customer (KYC) information. **Prefill any KYC information before creating the first account link.**

И про объём остатка:

> After you create an Account Link or Account Session, **only a subset of company/business information is returned** for accounts where `controller.requirement_collection` is `stripe` (то есть Standard и Express).

`[тест]` Контрольный замер — два одинаковых аккаунта, одному выпустили линк, другому нет:

| поле | до линка | после линка | после завершения онбординга |
|---|---|---|---|
| `individual.first_name` / `last_name` / `email` | читается | читается | читается |
| `individual.phone` | читается | **исчез** | исчез |
| `business_profile.product_description` | читается | **исчез** | исчез |
| `individual.dob` / `address` / `verification` | читается | — | исчез |

`[прод]` Подтверждение на масштабе: в полной выгрузке `individual.phone`, `dob` и `address` отсутствуют у **всех** аккаунтов — линк выписан каждому, иначе он бы не попал в онбординг.

**Практический вывод.** Доступ закрывается **раньше, чем кажется**: не «пока пользователь не закончил — можно дописать», а «выписали ссылку — всё». Поэтому весь префилл обязан лечь в `PreAuth`, досылать через `accounts/update` уже поздно. И обратное: сменил пользователь email или имя у нас в приложении — пересинхронизировать в Stripe мы уже не сможем.

### Любое `individual.*` отключает networked onboarding

Плата за префилл: предложение переиспользовать существующую legal entity («3 клика», банк копируется) исчезает для тех, у кого Stripe уже есть — по данным Stripe, это 1 из 6. Не дисквалифицируют только `business_profile`, `business_type` и `country`. Развилка «две кнопки» в [README.md](README.md) — предложение снять это противоречие, пока не принятое.
