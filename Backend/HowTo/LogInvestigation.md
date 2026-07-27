Investigating a log-borne backend error
=======================================

How to get from one red row in Cloud Logging to a named mechanism, cheaply and in the right order.
Field paths, selectors and the container-to-repo table are single-sourced in
[`Claude/skills/gcp/references/gcp-logs.md`](../../Claude/skills/gcp/references/gcp-logs.md);
this guide is the order in which to use them.

The ladder
----------

Each rung is one bounded query. Climb only as far as the question needs — most
investigations end on rung 2 or 3.

| # | Rung | What it answers |
|---|------|-----------------|
| 0 | Read the container name off the evidence | which service, which repo, what to scope by |
| 1 | Find the error row, projecting `trace` | the anchor: exact timestamp, actor, trace id |
| 2 | Pull the whole trace | causality across services in one request |
| 3 | Read the rows **around** the error inside that trace | why it failed, not just that it failed |
| 4 | Widen to the actor's neighbourhood | what the user was doing before and after |
| 5 | Aggregate over days | blast radius, first-seen, trend |
| 6 | Open the owning repo | the code path, the commit, the fix |

**Source code is the last rung, not the first.** Logs carry the runtime values that
decide which branch actually ran; a repo carries everything that *could* run, which is a
far larger space to search. Arriving at the code with a container, an exception type and
the runtime values turns the code step from an exploration into a lookup.

Rung 0 — the container is a routing key
---------------------------------------

A screenshot, an alert or a pasted row almost always names the container. That single
token both scopes every query below and selects the repo for the code step
(`auth-api` → `Tofu.Auth.Backend`, `invoices-api` → `Invoices.Backend`, `tofu-invoices-api`
→ `Tofu.Invoices.Backend`; full table in the reference linked above).

An error in one container regularly originates in another, so treat the container as
"where it surfaced", not "who is at fault".

Rung 1 — the anchor row
-----------------------

Scope by container, match the message text, and project `trace` alongside it. The row
carries the trace in ready-to-paste form, so this step also produces the next one.

```bash
gcloud logging read 'resource.labels.container_name="auth-api" AND "but trying to register with email"' \
  --project=inv-project --limit=3 --freshness=14d \
  --format='csv[no-heading,separator="|"](timestamp,jsonPayload.properties.TraceId,trace)'
```

Rung 2 — the whole trace
------------------------

No `logName` pin: one trace spans the load balancer and every container the request
touched, in order.

```bash
gcloud logging read 'trace="projects/inv-project/traces/<TRACE_ID>"' \
  --project=inv-project --limit=100 \
  --format='csv[no-heading,separator="~"](timestamp,resource.labels.container_name,severity,jsonPayload.message)'
```

Shape it first when the trace is noisy — which containers and loggers took part:

```bash
  --format='csv[no-heading,separator="|"](resource.labels.container_name,logName,severity)' | sort | uniq -c | sort -rn
```

Rung 3 — read the neighbours, not the error
-------------------------------------------

The line that names the cause is frequently an INFO row one tick earlier: a claims dump,
a resolved config value, the branch that was chosen. An error message states the failure;
its neighbours state why. Skipping this rung is the most common reason an investigation
ends in "we cannot tell from the logs" and escalates to a code hunt it did not need.

Rung 4 — the actor's neighbourhood
----------------------------------

Same account or device, an absolute window of tens of minutes around the anchor,
read forward in time.

```bash
gcloud logging read 'jsonPayload.properties.AccountId="<id>" AND timestamp>="2026-07-21T00:26:17Z" AND timestamp<="2026-07-21T01:26:17Z"' \
  --project=inv-project --order=asc --limit=200 \
  --format='csv[no-heading,separator="|"](timestamp,resource.labels.container_name,jsonPayload.properties.RequestPath,jsonPayload.properties.StatusCode)'
```

Rung 5 — blast radius
---------------------

Only now go wide, and only with aggregations — never an entry dump across days.

```bash
gcloud logging read 'resource.labels.container_name="auth-api" AND "but trying to register with email"' \
  --project=inv-project --limit=2000 --freshness=30d --format='value(jsonPayload.message)' \
  | grep -oE "with email '\"[^\"]+\"' but" | sort | uniq -c | sort -rn
```

Distinct actors matter more than the raw count: many rows over few users is a retry loop,
few rows over many users is breadth.

Gotchas that produce false conclusions
--------------------------------------

| Trap | What actually happens |
|------|----------------------|
| `--freshness` next to a `timestamp` filter | The flag is inert — it works only on filters **without** a timestamp. The window governs; the query is not double-bounded. |
| Times taken from a screenshot | Logs Explorer here renders UTC+3 while filters take UTC. Subtract 3 hours or you search the wrong hour and conclude "no events". |
| Filtering only on `jsonPayload.properties.*` | Without a resource selector the same filter can return zero rows. The empty result is silent and reads as "no such events". |
| Filtering by `AccountId` / `UserEmail` on auth failures | These are attached only after auth succeeds. Pre-auth failures carry neither — fall back to the container plus a tight window. |
| Trusting `StatusCode` alone on the BFF | It often returns HTTP 200 with an error envelope in `ResponseBodyText`. |
| Hitting `--limit` | Counts silently become partial. Say so in the report, or re-scope. |

Worked example — auth-api "register with email 'null'"
------------------------------------------------------

Evidence: three ERROR rows in `auth-api`, message
`User with external ID '…' already exists in database with email '…' but trying to register with email 'null'`.

| Rung | Result |
|------|--------|
| 0 | Container `auth-api` → repo `Tofu.Auth.Backend`, and every query below is scoped to it |
| 1 | Anchor row carries `trace=projects/inv-project/traces/eedbdc97…` |
| 2 | 8 rows across the load balancer, `invoices-api` and `auth-api` |
| 3 | The INFO row one tick before the error reads `ProviderId:'anonymous'` — **this identified the token shape**, which the error row alone could not |
| 4 | The account's surrounding hour shows a Stripe web checkout followed by a cancellation flow |
| 5 | 44 occurrences / 26 distinct users over 30 days; one user with 9 hits is a retry loop; one `@privaterelay.appleid.com` address proves a second token shape also occurs |
| 6 | Only then the repo: `UserRegistrationService.cs` logs and returns an error sentinel, the caller returns without setting the authenticated-user context, and the next accessor call raises an authentication exception mapped to 401 |

The conclusion the ladder produced: this is not a cosmetic duplicate-registration warning.
The trace shows `auth-api` answering 401 and `invoices-api` reporting "Unable to authenticate
user with authentication API" on `/api/authenticate/auth` — the user cannot sign in at all.
That framing came from rungs 2 and 3; the code step only confirmed the path.
