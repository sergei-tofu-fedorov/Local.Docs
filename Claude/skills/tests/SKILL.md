---
name: tests
description: Write or refactor unit/integration tests for the backend repos, following project conventions (xUnit, Moq, AutoFixture, FluentAssertions). Invoke for "write tests for X", "refactor this test file", "add coverage for my changes", or "test this endpoint"; ops: refactor | unit | integration | sync (detect changed code and fill the test gaps).
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Workspace Layout

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling git repos:

| Folder | Purpose |
|--------|---------|
| `Invoices.Backend/` | BFF — main repo, default target |
| `Tofu.Invoices.Backend/` | Invoices backend service |
| `Tofu.Auth.Backend/` | Auth backend service |
| `Tofu.Common.Backend/` | Shared backend library |

When this skill is invoked, first determine which repo the user is working in:
- If the current working directory is **inside** one of the repos, paths are relative to that repo (use as-is).
- If the current working directory is the **workspace root** (`Backend/`), prepend the repo folder name to all paths (e.g., `Invoices.Backend/Src/Invoices.Api/Controllers/...`).
- For `git diff` operations: run `git` commands inside the relevant repo (e.g., `cd Invoices.Backend; git diff master...HEAD --name-only`) — each repo has its own history.

If the user does not specify a repo and the working directory is the workspace root, default to `Invoices.Backend` (the main repo).

## Overview

| Operation | Usage | Description |
|-----------|-------|-------------|
| **refactor** | `/tests refactor <path>` | Refactor existing test file(s) |
| **unit** | `/tests unit <source-path>` | Write unit tests for a source file |
| **integration** | `/tests integration <endpoint>` | Write integration tests for an API endpoint |
| **sync** | `/tests sync [branch]` | Detect code changes and write missing tests |

If no operation is specified, infer from arguments or ask the user.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| **Line wrap** | 130 | Max line length before wrapping |

## Testing Stack

| Library | Purpose |
|---------|---------|
| **xUnit** | Test framework (`[Fact]`, `[Theory]`, `[InlineData]`) |
| **FluentAssertions** | Assertions (`result.Should().Be(expected)`) |
| **Moq** | Mocking (`new Mock<IService>()`) |
| **AutoFixture** | Test data (`[AutoData]`) |

## Naming Conventions

- **Test class:** `{ComponentName}Tests` (e.g., `JobTests`, `OrderServiceTests`)
- **Test method:** `{Method}_{Scenario}_{ExpectedBehavior}`
- **Variables:** Never use `sut`/`_sut`. Use descriptive names: `_jobService`, `_orderRepository`, `job`, `order`
- **File location:** Mirror source structure (e.g., `Domain/Models/Job.cs` → `Domain/Models/JobTests.cs`)

## Execution Flow

### 1. Parse the Operation

- `sync` → sync operation
- `refactor` → refactor operation
- `unit` → unit test operation
- `integration` → integration test operation
- Test file path → assume refactor
- Source file path → assume unit

### 2. Discover Test Projects

Search for `*.csproj` containing "Test" or "Tests" **within the target repo only** (do not cross repo boundaries — each backend repo has its own test projects). User must specify target test file, test project, or source file.

### 3. Execute the Operation

#### Operation: `refactor`

1. Read the target test file(s)
2. Analyze: regions, naming, duplication, Arrange/Act/Assert structure
3. Ask user what to refactor (if not specified)
4. Apply changes following principles:
   - Two regions: Tests + Helper Methods (no functionality-based regions)
   - Extract repeated setup to `Create*` factory methods
   - Use `[Theory]` with `[InlineData]` for parameterized cases
5. Run tests to verify

#### Operation: `unit`

1. Read the source file
2. Find matching test project (`ProjectName` → `ProjectName.Tests` or `ProjectName.UnitTests`) **within the same repo**
3. Check if test file exists (ask if adding or replacing)
4. **Look at existing tests** in target project to discover local patterns
5. Create tests with: regions, factory methods, Arrange/Act/Assert structure
6. Run tests to verify

#### Operation: `integration`

1. Find integration test project (contains "Integration" in name) **within the target repo**
2. **Discover existing patterns:** base class, fixtures, API clients, test data providers
3. Read the controller to understand endpoints
4. Create tests following discovered patterns
5. Run tests to verify

#### Operation: `sync`

Automatically detect code changes on the current branch and write both unit and integration tests where needed.

**Step 1: Detect changes**
1. `cd` into the target repo (e.g., `cd Invoices.Backend`) — each repo has independent git history
2. Run `git diff master...HEAD --name-only` (or specified base branch) to get changed files
3. Filter to source files only (exclude test files, docs, configs)
4. Run `git diff master...HEAD` on each changed file to understand what changed

**Step 2: Classify changes by layer**

Classify each changed file into one of these layers (paths are relative to the target repo root):

| Layer | Path patterns | Test type |
|-------|--------------|-----------|
| **Domain** | `Tofu.*/Domain/**`, `Jobs.Domain/**`, `*.Domain/**` | Unit tests |
| **Application** | `Invoices.Api/Controllers/**`, `Invoices.Api/Services/**`, `*.Application/**` | Integration tests |
| **Infrastructure** | `Invoices.Implementation.*/**`, `*.Infrastructure/**` | Integration tests |
| **DTOs/Models** | `Invoices.Api/Dto/**`, `Invoices.Api/Models/**`, `*.Contracts/**` | Skip (tested via consumers) |

**Important:** Unit tests are for **domain logic only** — pure business rules, domain models, value objects, domain services. Do NOT write unit tests for application-layer services (e.g., `JobDetailsService`, `ClientsService`), controllers, or infrastructure. Those are covered by integration tests.

**Step 3: Check existing test coverage**
1. For each changed file, search for existing tests that cover it (within the same repo)
2. Read the existing test files to understand current coverage
3. Read the changed source files and their diffs to understand new/modified behavior
4. Identify **gaps** — new methods, new branches, changed behavior not yet tested

**Step 4: Write tests**
1. Write unit tests for domain layer gaps (follow `unit` operation flow)
2. Write integration tests for application/infrastructure layer gaps (follow `integration` operation flow)
3. Apply all rules from the Rules section below (same as `refactor` operation)
4. If adding tests to existing test files, respect and follow the file's existing patterns

**Step 5: Refactor written tests**
After writing tests, apply the same quality pass as the `refactor` operation:
- Correct region structure
- Extract repeated setup to `Create*` factory methods
- Use `[Theory]` with `[InlineData]` where appropriate
- Follow naming conventions, readability rules, and assertion guidelines

**Step 6: Verify**
1. Build the test projects
2. Run all new and existing tests to ensure nothing is broken

**Integration Test Philosophy:**
- Focus on **application layer testing** and **component interaction**, not exhaustive case coverage
- Unit tests cover edge cases and variations; integration tests verify the system works end-to-end
- Example: If updating a job generates events, don't test every status transition
  - Instead: verify that ONE case correctly generates events AND they can be retrieved via endpoints or stored in database
- Test the **happy path** and **critical failure modes** only
- Verify data flows correctly through the stack (API → Service → Repository → Database)

## Test Structure

- **Unit tests:** Two sections only - `#region Tests` and `#region Helper Methods`
- **Integration tests:** Use endpoint-based regions (e.g., `#region GET /api/worker/visits`, `#region POST /api/jobs`) + `#region Helper Methods`
- **Do not** create regions by functionality (e.g., no `#region Events`, `#region Validation`)
- Follow Arrange/Act/Assert pattern
- Keep tests focused on single behaviors
- Prefer `[Theory]` + `[InlineData]` over multiple similar `[Fact]` tests
- Omit trivial/obvious test cases that add little value (e.g., idempotency checks like "delete twice still deleted")

## Integration Tests vs Unit Tests

| Aspect | Unit Tests | Integration Tests |
|--------|------------|-------------------|
| **Scope** | Single class/method | Full request flow |
| **Coverage** | All edge cases & variations | Representative scenarios |
| **Mocking** | Heavy (isolate unit) | Minimal (real components) |
| **Speed** | Fast | Slower (DB, network) |
| **Purpose** | Verify logic correctness | Verify components work together |

### Integration Test Guidelines

1. **Don't duplicate unit test coverage** - If unit tests cover 10 status transitions, integration tests need only 1-2
2. **Verify the integration points:**
   - Data persists correctly to database
   - Events are generated and retrievable
   - API responses match expected format
   - Components communicate correctly
3. **One test per integration scenario** - Avoid parameterized tests with many cases
4. **Test observable outcomes** - Focus on what can be verified via endpoints or database queries
5. **Keep integration tests minimal** - They're expensive to run and maintain
6. **Use Test Data Providers** - Prefer shared `Test*Provider` classes over private factory methods
   - Providers are reusable across test classes (e.g., `TestClientsProvider`, `TestInvoicesProvider`)
   - Add new parameters with default values when needed - don't mutate returned objects
   - Bad: `var client = TestClientsProvider.CreateClientDto(); client = client with { Info = ... };`
   - Good: `var client = TestClientsProvider.CreateClientDto(name: "Test", phone: "111-111-1111", address: "123 St");`

## Rules

### Assertions

- If assertion takes more than 1 line AND can be reused across multiple tests → extract to a private method
- Name assertion methods clearly: `AssertJobIsCompleted(job)`, `AssertOrderHasItems(order, expectedCount)`
- Place assertion helpers in `#region Helper Methods` (or `#region Assertion Helpers` if split from factory methods)
- **Use object properties, not repeated literals** - When asserting that data was persisted/returned correctly, reference the source object's properties instead of repeating string values
  - Bad: `AssertJobClientInfo(job, expectedName: "John", expectedPhone: "111-1111")` (duplicates Arrange values)
  - Good: `AssertJobClientInfo(job, clientRequest.Info)` (references the source object)
  - This ensures assertions stay in sync with test data and reduces duplication
- **Prefer object parameters over many scalar parameters** in assertion helpers
  - Bad: `AssertClientInfo(job, name, phone, email, address)` - many parameters to pass
  - Good: `AssertClientInfo(job, expectedClient)` - pass the whole object for comparison

### Factory & Helper Methods

- Use default values for all parameters → only test-relevant params are passed, making intent clear
- Example: `CreateJob(status: JobStatus.Completed)` - reader knows status is what matters for this test
- Provide sensible defaults that represent a valid "happy path" state
- Default values should reflect the **natural behavior**, not test convenience
  - Example: `CreateJob(clearEvents = false)` - natural state is events exist after creation
  - Even if most tests pass `clearEvents: true`, the default stays `false`
- Extract default values to `const` or `static readonly` fields at class level with `Default` prefix
- For often repeated test values (e.g., `var visitId = Guid.NewGuid()`) → create class-level fields with `Test` prefix
- If multiple values needed → use number suffix: `TestVisitId1`, `TestVisitId2`
- **Important:** Keep `Default*` (for factory defaults) and `Test*` (for test values) separate - they must not intersect
- **No duplication:** Use helper method parameters instead of duplicating logic in tests
  - Good: `CreateJob(clearEvents: true)`
  - Bad: `CreateJob()` followed by `job.ClearDomainEvents()`

### Comments

- **Avoid comments** - well-named tests and methods should be self-documenting
- **Only use comments** for explaining complex business logic or non-obvious test flows
  - Good: `// InProgress status requires user to manually confirm completion via ManualStatus override`
  - Bad: `// Create a job` or `// Assert the result`
- If you need a comment to explain what code does → rename the method or variable instead
- FluentAssertions `because` parameter is preferred over comments for explaining assertions

### Readability

- If an operation looks complex (even if one line) → extract to private method or extension
- Example: `job.DomainEvents.OfType<JobDomainEvent>().ToList()` → `GetDomainEvents(job)` or `job.GetDomainEvents()`
- **Variables for clarity:** It's OK to introduce variables used only once if they explain test intent
  - Good: `var nonExistentVisitId = Guid.NewGuid();` - name explains the test scenario
  - Good: `var overdueDate = DateTime.UtcNow.AddDays(-1);` - clarifies what the value represents
  - Inline only when the meaning is obvious: `await JobsClient.DeleteAsync(job.Id)` - no variable needed
- For method calls with multiple parameters inside collections → extract the element to a variable
  - Good: `var visit = CreateVisitInput(id: TestVisitId, status: VisitStatus.Scheduled);` then `CreateJob(visits: [visit])`
  - Bad: `CreateJob(visits: [CreateVisitInput(id: TestVisitId, status: VisitStatus.Scheduled)])`
- For DateTime: use `DateTime.Parse("2024-01-15 10:00")` not `new DateTime(2024, 1, 15, 10, 0, 0, DateTimeKind.Utc)`
- If same value used in both Arrange and Assert → extract to variable for clarity and maintainability
- Goal: test code should read like a specification, not implementation details

## Notes

- Always discover existing patterns before writing new tests
- Read source/test files before making changes
- Run tests after creating or refactoring
- Match namespace structure of source project
- Each backend folder is an **independent git repo** — never cross repo boundaries when discovering tests, running git, or building. Stay within the target repo.
