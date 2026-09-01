---
name: specify
description: Defines feature specifications for Colors of Meaning using spec-driven development. Produces structured requirements with user stories, acceptance criteria, hexagonal layer impacts, and testing strategy. Use when the user describes a new feature, enhancement, or behaviour change.
disable-model-invocation: true
allowed-tools: Read Write Bash
arguments: feature-description
argument-hint: "[feature-description]"
---

# Specify

Define feature specifications before implementation. This follows a spec-driven development approach where requirements are fully articulated before any code is written.

## Usage

`/specify <feature-description>`

## Process

1. **Read the project CLAUDE.md** (`.claude/CLAUDE.md`) to understand current architecture, layer boundaries, and coding standards.

2. **Identify affected hexagonal layers** — which of domain, application, infrastructure, interface, or shared will this feature touch?

3. **Produce a specification document** saved to `.specs/<feature-name>/SPEC.md` with this structure:

```markdown
# Feature: <name>

## Overview
One-paragraph summary of the feature and its value.

## User Stories
- As a <role>, I want <goal> so that <benefit>
- ...

## Acceptance Criteria
- [ ] Given <context>, when <action>, then <outcome>
- ...

## Hexagonal Layer Impact

### Domain Layer (`src/colors_of_meaning/domain/`)
New or modified entities, value objects, repository interfaces (ABC), domain services.
List files that change or are created.

### Application Layer (`src/colors_of_meaning/application/`)
New or modified use cases and application services.
List files that change or are created.

### Infrastructure Layer (`src/colors_of_meaning/infrastructure/`)
New or modified adapters: ML color mappers, compression baselines, distance calculators (`ml/`); dataset adapters (`dataset/`); embedding adapter (`embedding/`); evaluation classifiers and metrics (`evaluation/`); visualization (`visualization/`); persistence, observability, health checks.
List files that change or are created.

### Interface Layer (`src/colors_of_meaning/interface/`)
New or modified FastAPI controllers, CLI commands, Pydantic DTOs.
List files that change or are created.

### Shared Layer
Any cross-cutting concerns: configuration, resilience patterns, formatters.

## API Contracts
Define any new or modified FastAPI endpoints.
Include request/response Pydantic DTO shapes.

## CLI Impact
Describe any new or modified Click/tyro CLI commands and their arguments.

## Dependency Injection
New Lagom container registrations needed.
Which abstract interfaces map to which concrete implementations.

## Observability
Required structured logging (with correlation-id), metrics, and tracing additions.

## Open Questions
List any ambiguities or decisions that need resolution.
```

4. **Cross-reference** the spec against existing specs in `.specs/` for consistency and conflicts.

5. Present the spec for review before proceeding to `/plan`.

## Additional resources

- For architecture rules and coding standards, see [CLAUDE.md](../../CLAUDE.md)
- For scaffolding new features, see [hexagonal-architecture-scaffolder](../hexagonal-architecture-scaffolder/SKILL.md)
