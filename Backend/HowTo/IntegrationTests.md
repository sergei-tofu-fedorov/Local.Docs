# How to Work with Integration Tests (Backend)

Scope: overview of how backend integration test projects are structured, how shared fixtures/mocks work, and how to add new tests. This guide is service-agnostic and applies to any `<Service>.IntegrationTests` project in this backend.

## 1. When to Use Integration Tests

Use an integration test project when you need to:
- exercise the API end-to-end via HTTP (controllers + middleware + DI + database);
- verify behaviour that spans multiple services or infrastructure pieces (auth, payments, email, queues, etc.);
- assert that API contracts and serialization match what clients or external systems expect.

Prefer:
- unit tests for isolated logic;
- narrower “in-repo” integration tests (for example, `<Service>.Tests.Integration`) for scenarios that don’t require a full HTTP pipeline or real infrastructure.

## 2. Typical Project Structure

A typical `<Service>.IntegrationTests` project contains:

- `Setup/` – shared test infrastructure:
  - a global fixture (one per test run) that boots a test web host and initializes shared resources (database, external endpoints, etc.);
  - a `WebApplicationFactory`-style host wrapper that configures DI overrides and test configuration;
  - a base test class that all tests inherit from (provides HTTP client, typed API clients, DI scope, timeout token, logger);
  - a central “mock setup” class with helpers for configuring external dependencies;
  - shared assertion helpers for common response and error patterns.

- `Clients/` – typed HTTP clients:
  - interfaces describing API endpoints for the service under test (and sometimes supporting services);
  - a small factory that creates Refit (or similar) clients bound to the test host’s `HttpClient`;
  - optional shared serializer settings so tests use the same JSON formatting as production.

- `TestData/` – test data builders:
  - one provider per domain area (accounts, invoices, subscriptions, payouts, users, etc.);
  - AutoFixture-based helpers to create realistic entities with sensible defaults and easy overrides;
  - a central test fixture for global randomization/configuration.

- `Tests/` – actual scenarios:
  - grouped by feature or API surface, for example:
    - `Tests/Controllers`
    - `Tests/Repositories`
    - `Tests/Payments`
    - `Tests/Serialization`
    - other feature-specific folders as needed;
  - all tests derive from the base integration test class.

## 3. Test Lifecycle and Fixtures

The integration test lifecycle typically looks like this:

1. **Global fixture** starts the test web host:
   - configures test-specific settings (database name, test secrets, external endpoints);
   - registers mockable services and replaces external clients with test doubles.
2. **Base test class** (per test class):
   - exposes a shared `HttpClient` bound to the in-memory server;
   - exposes typed API clients through properties (built via the client factory);
   - exposes the central mock-setup object and a per-test DI scope;
   - provides a cancellation token with a reasonable timeout for each test.
3. **Each test**:
   - configures mocks via dedicated `Setup*` helpers on the central mock-setup type;
   - optionally seeds data using `TestData` providers and repositories;
   - calls API endpoints through typed clients from `Clients/`;
   - asserts responses using shared assertion helpers and response extension methods.

This keeps host startup and wiring in one place while letting individual tests focus on scenario setup and behaviour checks.

## 4. Mocks and External Dependencies

External dependencies (auth, payments, email, queues, gRPC, storage, etc.) are configured through a central mock-setup type in `Setup/`:

- It holds strongly-typed mocks for external clients/services.
- It exposes focused `Setup*` methods per dependency, for example:
  - `SetupGetAuthenticatedUserInfo(...)`
  - `SetupMissingClaims(...)`
  - `SetupPaymentProviderAuthenticate(...)`
  - and similar scenario-oriented helpers.

Guidelines:
- Prefer calling these helpers from tests instead of constructing mocks ad hoc.
- When a new external dependency must be mocked:
  - add a new field/property to the central mock-setup type;
  - add small, scenario-focused `Setup*` methods instead of large, generic ones;
  - keep behaviour realistic and reusable across tests.

## 5. Writing New Integration Tests

When adding a new integration test for a backend service:

1. **Choose the folder**:
   - controller-level behaviour → `Tests/Controllers`;
   - repository/infrastructure → `Tests/Repositories`;
   - feature-specific flows (payments, onboarding, invitations, etc.) → a dedicated feature folder.
2. **Inherit from the base integration test class**:
   - use the shared `HttpClient` and typed API clients;
   - use the exposed DI scope to resolve repositories or services when needed.
3. **Configure test behaviour**:
   - use `TestData` providers to create realistic inputs;
   - use central mock-setup helpers to define external system responses;
   - seed database or other storage through repositories as needed;
   - seed domain entities via **public factory methods** (e.g., `InvitationToken.Create`,
     `entity.AddChild(…)`) — never call `internal` constructors or static methods
     from integration tests; this avoids `InternalsVisibleTo` leaking domain internals
     to test projects and keeps tests coupled to the public contract only.
4. **Assert results**:
   - unwrap HTTP responses into envelope/DTO types via shared extensions;
   - use common assertion helpers for error codes and shapes;
   - add scenario-specific assertions close to the test.

Following this pattern keeps integration tests consistent across services, minimizes boilerplate, and makes it easier to evolve infrastructure and mocks without rewriting every test. 

