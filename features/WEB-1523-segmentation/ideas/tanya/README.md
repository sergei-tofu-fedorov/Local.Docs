# Quality flags for AI Detection v4

- Add detection of the **"missed-visit" pattern** in notes as an explicit signal. Currently it's baked into the LLM evidence via "recurring", but the model doesn't distinguish *leakage* (a visit that should have happened and didn't) from normal recurring activity.
- Add a **`worker_count_proxy`** — have the LLM extract first names from notes. The current regex-based approach is noisy.
- Validate **status-code semantics**. Separate probe run on 50 accounts with known statuses (draft vs. sent vs. paid) to confirm the mapping holds.
- Add **time-of-day of creation** as a backend metric (if available in the raw DB). This unlocks the evening/weekend pain point from the original spec, which is missing today.

---

**Overlap with Misha § C.** Items 1, 2, and 4 here are substantially the same signals already captured in [`../misha/README.md`](../misha/README.md) § C *Pain signals — separate analysis_type, NOT FSM-fit* (`notes_mention_callback`, `notes_mention_workers`, `evening_invoice_ratio`, `weekend_invoice_ratio`). The scoping question — *ship pain signals in v1 alongside FSM-fit, or land them in v2 as a separate `analysis_type`?* — is open as **EQ-3** in the same doc. Defer doc surgery here until EQ-3 resolves. Item 3 (status-code probe) is a one-off validation activity, no doc changes needed.
