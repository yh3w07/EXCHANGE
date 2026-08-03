# Claude Code Task: Prepare Existing NSW for External Code Review

## 1. Purpose

An initial NSW implementation already exists in the company RD environment.

Do **not** redesign NSW or start a new implementation for this task. Prepare a complete review handoff so another coding agent can:

1. understand the current implementation;
2. reproduce its intended behavior using synthetic data;
3. review architecture and Tcl correctness;
4. identify missing cases;
5. refactor, strengthen, or replace the implementation if necessary.

All NSW Tcl source files are required, but source code alone is insufficient. The additional information below is mandatory because behavior not represented in code cannot be reconstructed reliably.

## 2. Security Boundary

- Follow company classification and export-approval procedures.
- Do not include real LIBs, real constraints, project names, hostnames, usernames, internal paths, or design identifiers unless explicitly approved for release.
- Use stable synthetic identifiers when examples are required.
- Preserve structural relationships during anonymization: hierarchy depth, bus indices, wildcard patterns, collection cardinality, clock relationships, and Tcl control flow.
- Do not build or use unapproved transfer mechanisms.
- Preparing this package does not constitute export approval.

## 3. Required Package

Prepare the following structure:

```text
NSW_REVIEW_HANDOFF/
├─ HANDOFF_MANIFEST.md
├─ FILE_INVENTORY.tsv
├─ LOAD_AND_RUNTIME.md
├─ ARCHITECTURE.md
├─ API_AND_BEHAVIOR.md
├─ MAPPING_MODEL.md
├─ ASSUMPTIONS.md
├─ KNOWN_ISSUES.md
├─ OPEN_DECISIONS.md
├─ SECURITY_REVIEW.md
├─ src/
│  └─ all NSW Tcl source files
├─ examples/
│  └─ synthetic Tcl/SDC examples
├─ tests/
│  ├─ mock/
│  └─ primetime/
└─ evidence/
   ├─ TEST_SUMMARY.md
   └─ sanitized test outputs
```

Do not omit helper, bootstrap, configuration, compatibility, logging, or test scripts. A wrapper file without the scripts it sources is not a complete handoff.

## 4. Source Inventory

Create `FILE_INVENTORY.tsv` with one row per file:

```text
relative_path    purpose    sourced_by    dependencies    internal_or_exportable
```

Also record:

- current Git commit or internal revision;
- file SHA-256 values;
- generated files versus maintained source files;
- deprecated files still used by existing flows;
- required load order;
- files intentionally excluded from the handoff and why.

## 5. Load and Runtime Information

Document the following in `LOAD_AND_RUNTIME.md`.

### 5.1 Environment

- PrimeTime release actually tested.
- Operating system and shell used to launch PrimeTime.
- Tcl/PrimeTime startup scripts relevant to NSW.
- Required application variables.
- Required packages or internal Tcl libraries.
- Whether NSW also runs in Design Compiler or only PrimeTime.

### 5.2 Entry Point

Provide the exact synthetic load sequence, for example:

```tcl
source ./src/nsw.tcl
nsw::configure ...
source ./examples/synthetic/block_constraint.tcl
```

Document:

- main NSW entrypoint;
- source order;
- initialization command;
- required environment/global variables;
- BLK, Partition, and TOP context selection;
- scenario/mode initialization;
- current design/current instance requirements;
- behavior when NSW is sourced more than once.

### 5.3 Native Command Dispatch

Explain exactly how wrappers reach original PrimeTime commands:

- command renaming;
- namespace alias;
- dispatch table;
- recursion prevention;
- command restoration/unload behavior.

## 6. Architecture Description

In `ARCHITECTURE.md`, describe the code that exists today, not the architecture that would be ideal.

Include:

- module boundaries;
- shared global state or namespaces;
- execution context storage;
- option parsing;
- object resolution;
- clock mapping/lineage;
- MBFF mapping;
- library-vendor mapping;
- hierarchy mapping;
- native dispatch;
- error handling;
- tracing/logging;
- configuration loading;
- test hooks or mocks.

Provide a short call flow for each wrapper family:

```text
nvt_command -> parser -> resolver -> policy -> native PrimeTime command
```

If the actual flow differs, document the actual flow.

## 7. Public API and Behavior Contract

Create `API_AND_BEHAVIOR.md`.

### 7.1 Command Inventory

List every implemented public command:

| NSW command | Native command | Status | Used by real flow | Test coverage |
|---|---|---|---|---|
| `nvt_get_pins` | `get_pins` | implemented | yes/no | test IDs |

Use explicit status values:

```text
IMPLEMENTED
PARTIAL
EXPERIMENTAL
DEPRECATED
STUB
```

### 7.2 Exact Calling Interface

For every command, provide:

- exact syntax;
- NSW-specific options;
- supported native options;
- positional arguments;
- accepted input types: string, Tcl list, PrimeTime collection, object;
- return type;
- error behavior;
- BLK behavior;
- Partition behavior;
- TOP behavior;
- backward-compatibility requirements.

### 7.3 Command Behavior Table

For every implemented wrapper, fill in:

| Condition | Expected action | Current implementation | Notes |
|---|---|---|---|
| BLK context | pass/map/etc. | current behavior | |
| TOP context | pass/map/etc. | current behavior | |
| empty collection | warning/error/skip | current behavior | |
| missing mapping | warning/error/fallback | current behavior | |
| ambiguous mapping | warning/error/expand | current behavior | |
| one-to-many | expand/union/reject | current behavior | |
| many-to-one | collapse/deduplicate/reject | current behavior | |
| duplicate result | retain/deduplicate | current behavior | |

Do not write only what the current code happens to do. Distinguish intended behavior from current behavior.

## 8. Mapping Model

Create `MAPPING_MODEL.md` describing all mapping inputs and their precedence.

### 8.1 Hierarchy Mapping

Document:

- BLK to Partition mapping;
- Partition to TOP mapping;
- whether mappings compose across multiple levels;
- port versus instance-pin handling;
- flatten, uniquify, rename, and replicated-object handling;
- expected behavior when hierarchy mapping is incomplete.

### 8.2 Clock Mapping

Document:

- local clock to TOP clock mapping;
- one-to-many master clocks;
- generated-clock source/master mapping;
- root clock tracking;
- clock naming rules;
- duplicate-name handling;
- mapping source: manual list, automatic discovery, or both;
- precedence between automatic and manual data.

### 8.3 MBFF Mapping

Document:

- mapping source;
- MB separator rules;
- logical register to physical MBFF mapping;
- D/Q bit mapping;
- bit reorder behavior;
- shared clock/reset/set handling;
- replicated registers;
- duplicate collection handling;
- missing/ambiguous mapping policy.

Provide a synthetic example equivalent to:

```text
logical register   physical cell   logical pin   physical pin
REG_A[0]           MBFF_001        D             D0
REG_A[1]           MBFF_001        D             D1
REG_A[0]           MBFF_001        Q             Q0
REG_A[1]           MBFF_001        Q             Q1
REG_A[*]           MBFF_001        CK            CP
```

### 8.4 Cross-Library Mapping

Document semantic roles and actual matching logic:

```text
clock
data
q
qbar
set
reset
scan_in
scan_enable
gate_enable
test_enable
```

State whether mapping uses:

- static synonym tables;
- `ref_name` or `lib_cell`;
- lib-pin attributes;
- timing arcs/functions;
- naming heuristics;
- fallback search.

Document validation of polarity, edge type, latch/DFF classification, and functional versus test pins.

## 9. Synthetic Usage Examples

Provide synthetic examples that preserve the shapes of real calls without company identifiers.

At minimum include:

1. Dynamic Tcl using `if`, `foreach`, `proc`, and variables.
2. `nvt_get_cells` and `nvt_get_pins` with wildcard/filter options.
3. Single-bit register mapped to MBFF D/Q pins.
4. Shared MBFF clock-pin collapse.
5. Cross-library `CK`/`CP`-style substitution.
6. BLK clock mapped to multiple TOP clocks.
7. Generated clock mapped through multiple hierarchy stages.
8. `set_false_path` using `-from`, ordered `-through`, and `-to`.
9. Missing and ambiguous object cases.
10. Empty collection behavior.

For each example provide:

```text
Test ID
Execution context
Input command
Input object count
Expected resolved objects using synthetic names
Expected mapping status
Expected native command count
Expected warning/error code
```

Code review cannot reliably infer omitted SDC usage from wrapper code. These examples are mandatory.

## 10. Tests and Evidence

### 10.1 Test Inventory

Create `evidence/TEST_SUMMARY.md`:

| Test ID | Command | Context | Purpose | Result | PrimeTime version |
|---|---|---|---|---|---|

### 10.2 Required Evidence

Provide sanitized evidence for:

- exact object resolution;
- one-to-many expansion;
- many-to-one collapse;
- duplicate removal;
- missing mapping;
- ambiguous mapping;
- MBFF bit reorder;
- cross-library substitution;
- generated-clock master/source mapping;
- re-sourcing NSW;
- native command dispatch without recursion.

### 10.3 Reproduction Commands

Provide exact commands for:

```text
mock test execution
PrimeTime integration test execution
test result collection
```

Tests must report pass/fail automatically. Do not require an external reviewer to interpret a large raw log.

## 11. Assumptions, Known Issues, and Open Decisions

### `ASSUMPTIONS.md`

List every assumption about:

- Block SDC style;
- object naming;
- PrimeTime collections;
- hierarchy;
- clock ownership;
- MBFF naming/mapping;
- vendor libraries;
- command ordering;
- re-source behavior;
- missing-object policy.

### `KNOWN_ISSUES.md`

For each issue provide:

```text
Issue ID
Affected command
Trigger condition
Observed behavior
Expected behavior
Current workaround
Test coverage
Severity
```

### `OPEN_DECISIONS.md`

Record unresolved design choices. Do not hide uncertainty in implementation comments.

## 12. Review Questions to Answer

Answer these explicitly in `HANDOFF_MANIFEST.md`:

1. What problem does the current NSW version solve successfully?
2. Which real Block flows currently use it?
3. Which public APIs must remain backward compatible?
4. Which wrappers are incomplete or known to be unsafe?
5. Which behavior depends on company-private configuration?
6. Which behavior is hard-coded?
7. Which mappings are authoritative and which are heuristics?
8. Where can a mapping silently select the wrong object?
9. Which commands can produce combinatorial expansion?
10. Which failures are currently warnings but should possibly be errors?
11. What has been tested in real PrimeTime?
12. What has only been tested with mocks?
13. What should the external reviewer fix first?

## 13. Export Review

Create `SECURITY_REVIEW.md` and scan the proposed handoff package for:

- company and project names;
- internal hostnames, paths, usernames, and email addresses;
- real hierarchy, cell, pin, clock, and net names;
- real library names or vendor data not approved for release;
- real SDC fragments;
- proprietary documentation;
- raw PrimeTime logs;
- comments containing internal details;
- Git history containing deleted sensitive data.

The exportable package should be generated from an allowlist of files. Do not copy the full internal repository and then rely only on deletion.

## 14. Final Handoff Report

At completion, report:

```text
NSW internal revision:
PrimeTime version tested:
Number of Tcl source files:
Implemented public commands:
Partial/stub commands:
Mock tests passed/total:
PrimeTime tests passed/total:
Known critical issues:
Backward-compatibility requirements:
Company-private dependencies:
Open decisions:
Export-review package path:
Security scan result:
Files excluded from export and reasons:
```

Do not modify the NSW implementation merely to make this handoff look complete. Document the current state accurately. If information is unknown, write `UNKNOWN` and explain how it can be determined.
