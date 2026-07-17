# /tests Skill - Quick Reference

Refactor or write unit/integration tests following project conventions.

## Workspace Note

This skill is registered at `C:\Git\Work\Backend\` (workspace root). The workspace contains multiple independent backend repos as siblings (`Invoices.Backend/`, `Tofu.Invoices.Backend/`, `Tofu.Auth.Backend/`, `Tofu.Common.Backend/`). The skill operates **within a single target repo at a time** — it never crosses repo boundaries (each repo has its own git history and test projects). Default target is `Invoices.Backend` (BFF, main repo).

## Commands

| Command | Description |
|---------|-------------|
| `/tests refactor <path>` | Refactor existing test file |
| `/tests unit <source>` | Write unit tests for a source file |
| `/tests integration <endpoint>` | Write integration tests for an endpoint |
| `/tests sync [branch]` | Detect branch changes, write missing unit + integration tests |

## Examples

```bash
# Refactor existing test file
/tests refactor Invoices.Backend/Src/Invoices.Tests/Domain/Models/JobTests.cs

# Write unit tests for a class
/tests unit Invoices.Backend/Src/Domain/Models/Order.cs

# Write unit tests specifying test project
/tests unit PaymentService in Invoices.Tests

# Write integration tests for a controller
/tests integration OrdersController

# Write integration tests for specific endpoint
/tests integration POST /api/v1/orders
```

## Sync Operation

`/tests sync` enters the target repo, runs `git diff master...HEAD`, classifies changes by layer, and writes tests:

| Layer | Example paths (within repo) | Test type |
|-------|----------------------------|-----------|
| Domain | `Tofu.*/Domain/**`, `Jobs.Domain/**` | Unit tests |
| Application | `Api/Controllers/**`, `Api/Services/**` | Integration tests |
| Infrastructure | `Implementation.*/**` | Integration tests |
| DTOs/Models | `Api/Dto/**`, `Contracts/**` | Skipped (tested via consumers) |

Unit tests are for **domain logic only**. Application-layer services, controllers, and infrastructure are covered by integration tests.

```bash
# Sync against master (default) — runs in default repo (Invoices.Backend)
/tests sync

# Sync against a specific branch
/tests sync develop
```

## Naming Conventions

**Test Classes:** `{ComponentName}Tests`
```
OrderTests, AccountControllerTests, PaymentServiceTests
```

**Test Methods:** `{Method}_{Scenario}_{Expected}`
```csharp
Create_WithValidInput_ReturnsNewOrder()
Update_WhenNotFound_ThrowsException()
GetAll_WithFilter_ReturnsFilteredResults()
```

**Variable Names:** Use descriptive names, never `sut`
```csharp
// Good: descriptive names
var job = CreateJob();
var _orderService = new OrderService(mockRepo.Object);

// Bad: generic sut
var sut = CreateJob();  // Don't do this
```

## Test Structure

```csharp
public class OrderServiceTests
{
    #region Behavior Group

    [Fact]
    public void Process_WithValidOrder_ReturnsSuccess()
    {
        // Arrange
        var orderService = CreateOrderService();

        // Act
        var result = orderService.Process(order);

        // Assert
        result.Should().Be(expected);
    }

    #endregion

    #region Factory Methods

    private static OrderService CreateOrderService() => new();

    #endregion
}
```

## Testing Stack

- **xUnit** - `[Fact]`, `[Theory]`, `[InlineData]`
- **FluentAssertions** - `result.Should().Be(expected)`
- **Moq** - `new Mock<IService>()`
- **AutoFixture** - `[AutoData]`

## Running Tests

```bash
# From inside the target repo (e.g., Invoices.Backend/Src):
dotnet test

# Run specific test project
dotnet test path/to/TestProject

# Run specific test class
dotnet test --filter "FullyQualifiedName~OrderTests"

# Run specific test method
dotnet test --filter "FullyQualifiedName~OrderTests.Create_WithValidInput"
```
