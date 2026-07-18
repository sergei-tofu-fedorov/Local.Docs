# FSM-fit classifier — validation on 200 manually-labelled prod accounts (2026-06-30)

| Model | Industry acc | NOT-FSM-fit P / R | Flag macro-F1 (5 reliable¹) |
|---|---|---|---|
| prod-nano (v3, current prod) | 64.0% | 69% / 18% | 0.513 |
| nano (v7, re-run) | 67.5% | 54% / 77% | 0.574 |
| flash-lite (no calibration) | 82.5% | 72% / 70% | 0.639 |
| **flash-lite + calibration (final)** | **~86%¹** | **81% / 69%** | **0.721** |
| claude (reference) | 89.0% | 87% / 89% | 0.685 |

¹ flash-lite industry is noisy — Vertex temp-0 re-runs vary ~±1.5pp; practical range ~86–87%.
Flag macro-F1 over 5 flags; `contract_based_billing` excluded as noisy in human labelling.

**Outcome:** calibrated **flash-lite beats claude on flags (0.721 vs 0.685)** and is far ahead of nano; claude leads industry (89% vs ~86%). Confirms the prod **nano → flash-lite** switch.

**Method:** 200 industry-diverse prod accounts, all 24 industries; human gold via Argilla (industry + 6 FSM flags + FSM-fit yes/no). flash-lite calibration: fixed labour under-flag, complex over-flag, materials/products → `other`, non-FSM → empty flags, name-when-items-thin, narrowed CCTV → security_alarm.

**Attached:** `fsm-fit-judge-diverse-gold-2026-06-30.zip` (gold labels, per-account model votes, full scores).
