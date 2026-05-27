Backend Persistence Docs Template
=================================

Use this file as a compact guide for documenting persistence for all backend
services. The goal is: **short text, but complete coverage of all stored
entities, their fields, and relations**.

Principles
----------

- Each service must document every persisted entity (table/collection/document).
- For every entity, list **all fields** with type, nullability, and key/index
  information.
- For every relation, describe cardinality and ownership (who owns the schema).
- Keep prose minimal; use tables and lists so the whole document stays compact.

Per‑Service Section
-------------------

For each backend service create a section:

- Service name and repository link.
- Primary data stores (SQL / NoSQL / other).
- High-level notes about data ownership (what this service owns vs. reads).

Example:

- `Tofu.Invoices` – owns invoices and estimates schema, uses SQL + MongoDB.

Per‑Entity Template
-------------------

For every persisted entity in a service, use this structure:

1. **Entity name** (and physical name: table/collection).  
2. **Fields table** – one row per field:

   | Field        | Type        | Null | Key/Index           | Description                    |
   | ------------ | ----------- | ---- | ------------------- | ------------------------------ |
   | Id           | uuid        | No   | PK, clustered       | Technical identifier           |
   | CustomerId   | uuid        | No   | FK Customers(Id)    | Link to owning customer       |
   | Status       | string(32)  | No   | index (Status)      | Business status                |
   | CreatedAt    | datetime    | No   |                     | UTC creation timestamp         |

3. **Relations** – list all relations from this entity:
   - FK to `<OtherEntity>` (1:N / N:1 / N:N, required/optional).
   - Cascading rules (delete/update) if important.

Relations Overview
------------------

At the end of each service section, add a compact graph-style overview:

- `<EntityA> (1) ── (N) <EntityB>` – ownership and cascade rules.
- Note cross-service dependencies only at a high level (for example,
  `Invoices.Invoice.CustomerId -> Auth.Customer.Id (read‑only)`).

How to Use This Template
------------------------

- Every backend service must have its own `Backend/Services/<ServiceName>/Persistence.md`
  file that follows this structure.
- Keep service‑specific details in `Backend/Services/<ServiceName>/Persistence.md`
  (and link it from the service `README.md`).
- Use this `Backend/Persistence.md` as a shared pattern and, if needed, as an
  index linking to deeper per‑service persistence docs.
