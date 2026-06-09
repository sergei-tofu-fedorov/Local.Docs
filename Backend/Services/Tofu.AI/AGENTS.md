Tofu.AI Backend Service
=======================

This folder contains backend documentation for the Tofu.AI service (AI analyses + investigations).

Contents
--------

- Investigations module — domain structure, `investigations` Postgres schema, runtime flows, endpoints, configuration:
  - `Backend/Services/Tofu.AI/Investigations.md`

Related docs elsewhere
----------------------

- Analyses module (FSM-fit pipeline) service layout: `features/WEB-1523-segmentation/implementation/service.md`
- Data stores (BigQuery `ai_analysis_v2`, Postgres `tofu_ai`, GCS chat context): `Backend/Storage/AGENTS.md`
- Investigations feature plan + research (plan-time view): `features/FS-1111/`

Local rules
-----------

When adding service-specific rules for Tofu.AI (validation rules, DTO mapping notes,
error-handling conventions, etc.), add separate Markdown files in this folder and
link them from this `AGENTS.md`.
