# /feature — implementation discipline rules

Apply these while implementing a feature (step 6 of the canonical workflow), before `/feature lint` and `/feature review`.

## Testing requirement (every implementation)

For any feature that adds or changes runtime behavior in a backend repo, the implementation is **not done** until at least **one integration test** covering the new behavior has been added in that repo's functional/integration test project (`tests/Tofu.Invoices.FunctionalTests`, `Invoices.Backend/Invoices.Tests.Integration`, etc. — match the existing convention). The test should exercise the real boundary the feature defines (gRPC handler, REST endpoint, queue consumer) end-to-end, not just the inner service unit.

After writing the new test(s), invoke the **`/tests` skill** on the changed test files to refactor them in line with project conventions (naming, fixtures, AutoFixture usage, async patterns, `FluentAssertions`, etc.) before considering the feature ready for `/feature lint` and `/feature review`.

Skip this step only when the change is documentation-only or a pure config edit. Never skip "because the unit tests cover it" — the integration test is the contract proof.

## Implementation comments (every implementation)

While implementing a feature, add a **short single-line comment** to any line of code that expresses **non-obvious business logic** — a domain rule, hidden invariant, intentional asymmetry, or cross-system contract a reader cannot infer from the code itself. Default is no comment; the trigger is *"would a competent engineer reading this in six months wonder why?"*.

**Style** — match `Invoices.Backend/CLAUDE.md`:
- Single-line `// rationale` for inline notes; `/// <summary> ... </summary>` for member docs (single-line preferred per the project standard).
- Explain the **why**, not the **what**. Code already says what.
- One sentence, one line. Long explanations belong in the plan doc, not in source.
- Reference the ticket only when the rule originated there (e.g., *"INVC-3608: legacy product-key behavior"*); otherwise cite a peer line/method (`see ProductsRepository.cs:204`).

**Comment-worthy:**
- Domain rules invisible in code structure — *"FS and IM apps see only owner/admin accounts."*
- Hidden invariants the reader could violate — *"Caller must validate signature before parsing — payload is untrusted until then."*
- Intentional null/empty tolerance preserving prior behaviour — *"`null` returns `false` to preserve `IsOwnerOnlyProduct` semantics."*
- Cross-system contracts not visible locally — *"iOS ≤ v3.4 expects this field as a string; do not narrow."*
- Order-of-operations that looks reorderable but isn't — *"Resolve `ClientId` before authorising — auth check needs the parent."*
- Workarounds for known framework / library quirks — *"EF Core 8 cannot translate `.Any(...)` over composite key here; expand to subquery."*
- Asymmetric behaviour between code paths that look the same — *"Worker path skips status check; manager path enforces it."*

**Skip:**
- Standard CRUD shapes, idiomatic LINQ, pattern matches on enums.
- Self-documenting names (`ownedAccountIds`, `validateThenParse(...)`).
- Anything already implied by `[Required]`, `[MinLength]`, type, or method name.
- Restating what the next line literally says.
- `// TODO` without a name + ticket — these rot. Open a ticket or remove the line.

If a chunk of logic needs more than one comment line to be understandable, the code shape is wrong — refactor instead of stacking comments.

This is a discipline rule, not a tool gate. `/feature lint` does not enforce comment presence. `/feature review` (via `/review-gw --branch`) flags rationale gaps on changes that introduce non-obvious behaviour — that is the enforcement seam.
