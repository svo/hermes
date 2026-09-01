---
name: plan
description: Creates a technical implementation plan from a Colors of Meaning feature specification. Produces a step-by-step plan organized by hexagonal architecture layers, with an ordered task list and testing strategy. Use after /specify has produced a SPEC.md.
disable-model-invocation: true
allowed-tools: Read Write Bash
arguments: spec-name
argument-hint: "[spec-name]"
---

# Plan

Create a technical implementation plan from a feature specification. This bridges the gap between "what" (the spec) and "how" (the code).

## Usage

`/plan <spec-name>`

Where `<spec-name>` matches a directory under `.specs/`. The argument is available as `$spec-name`.

## Process

1. **Read the spec** at `.specs/$spec-name/SPEC.md`.

2. **Read the project CLAUDE.md** (`.claude/CLAUDE.md`) to understand architecture rules, layer boundaries, and coding standards.

3. **Scan the existing codebase** — identify files to edit (prefer editing over creating), existing patterns to follow, and `__init__.py` files that may need updating.

4. **Produce a plan document** saved to `.specs/$spec-name/PLAN.md` with this structure:

```markdown
# Plan: <feature-name>

## Implementation Strategy
High-level approach and key architectural decisions.
Identify which existing files to modify vs. new files to create.

## Layer Changes

### Domain Layer (`src/colors_of_meaning/domain/`)
- New or modified entities and value objects (`model/`)
- New or modified repository interfaces using ABC (`repository/`)
- New or modified domain services (`service/`)
- Ensure no imports from application, infrastructure, or interface

### Application Layer (`src/colors_of_meaning/application/`)
- New or modified use cases (`use_case/`)
- New or modified application services (`service/`)
- Dependencies received via constructor injection
- Ensure no imports from infrastructure or interface

### Infrastructure Layer (`src/colors_of_meaning/infrastructure/`)
- ML adapters: color mappers, compression baselines, distance calculators (`ml/`)
- Dataset adapters, embedding adapter, evaluation classifiers, visualization (`dataset/`, `embedding/`, `evaluation/`, `visualization/`)
- Repository implementations (`persistence/`)
- Health checks (`system/`)
- Observability: structured logging with correlation-id, metrics, tracing (`observability/`)
- Implements domain interfaces

### Interface Layer (`src/colors_of_meaning/interface/`)
- FastAPI controllers with route definitions (`api/controller/`)
- Pydantic DTOs for all request/response shapes (`api/data_transfer_object/`)
- Click/tyro CLI commands (`cli/`)
- Uses Depends() with Lagom for dependency injection

### Shared Layer (`src/colors_of_meaning/shared/`)
- Configuration changes
- New resilience patterns or formatters

## Dependency Injection
- New Lagom container registrations
- Abstract-to-concrete mappings
- Test container overrides

## Task List

Ordered list of implementation tasks. Each task should be independently committable.
Follow inside-out order: domain → application → infrastructure → interface.

1. [ ] domain: <task description>
2. [ ] application: <task description>
3. [ ] infrastructure: <task description>
4. [ ] interface: <task description>
5. [ ] tests: <task description>
...

## Testing Strategy
- One assertion per test, using assertpy (`assert_that`)
- Test names follow `test_should_<behaviour>_when_<condition>` pattern
- Unit tests per layer with mocked dependencies
- Architectural tests to validate layer boundaries (pytest-archon)
- CDCT tests for any service integrations
- Verify with `tox` (not pytest directly) — enforces all 8 quality gates
- Target: 100% coverage

## Observability Plan
- Structured log entries with correlation-id
- Metrics to collect (counters, gauges, histograms)
- Tracing decorators for use cases

## Risks and Mitigations
- Risk: <description> → Mitigation: <approach>
```

5. **Validate** the plan against the spec — confirm all acceptance criteria are covered by at least one task.

6. Present the plan for review before implementation.

## Additional resources

- For the spec this plan is based on, see `.specs/$spec-name/SPEC.md`
- For architecture rules and coding standards, see [CLAUDE.md](../../CLAUDE.md)
- For scaffolding guidance, see [hexagonal-architecture-scaffolder](../hexagonal-architecture-scaffolder/SKILL.md)
