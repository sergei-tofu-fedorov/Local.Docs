Invoices.Backend – DTO and Enum Rules
=====================================

DTO Validation
--------------

- Do not use legacy `ValidateModel()` helpers in controllers.
- Prefer FluentValidation or Data Annotations combined with the built‑in
  ASP.NET Core model validation pipeline.

Enums and DTOs
--------------

- When exposing enums via JSON:
  - use string representations where possible;
  - configure converters such as:
    - `Newtonsoft.Json.JsonConverter(typeof(StringOnlyEnumConverter))`, or
    - `System.Text.Json.Serialization.JsonConverter(typeof(JsonStringEnumConverter))`.
- For BFF enums, along with string enum conversion attributes, also use
  `[EnumMember(Value = "...")]` to serialize enum values as camelCase.
- Keep enum types and their JSON behaviour documented in one place to avoid
  mismatches between services.
