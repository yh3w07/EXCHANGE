# Claude Code Task: NSW Initial Implementation

## 1. Objective

Implement a working v0.1 of **NSW (NVT SDC Wrapper)** inside the company RD environment.

NSW is a PrimeTime runtime portability layer. The same Block-level Tcl/SDC source must remain maintainable and usable at Block, Partition, and Top hierarchy while handling clock, hierarchy, synthesis, MBFF, and library-vendor differences.

The Block constraint remains the single source of truth. Preserve dynamic Tcl usage such as `if`, `foreach`, `proc`, variables, collections, and PrimeTime queries.

## 2. Security Boundary

- Company LIBs, real constraints, design names, hierarchy names, logs, and mapping tables must remain inside RD.
- Do not upload or copy company data to GitHub or any external location.
- Generic core code may be prepared for export only if company policy permits it.
- Any exportable example or test must use stable synthetic names and contain no recoverable company identifiers.
- Do not implement covert or unapproved data-transfer mechanisms.
- Produce separate internal and export-review packages. Export still requires the normal company approval process.

## 3. Required Discovery Before Coding

Inspect the RD environment and record findings in `docs/RD_DISCOVERY.md`:

1. Locate existing implementations and usage of:
   - `nvt_get_pins`
   - `nvt_get_cells`
   - other `nvt_*` constraint wrappers
2. Find representative Block SDC entrypoints and sourced helper Tcl files.
3. Inventory actual call shapes, including options, wildcards, filters, collections, loops, and procedures.
4. Identify PrimeTime release and Tcl environment.
5. Identify how BLK, Partition, and TOP execution context is currently selected.
6. Identify available sources of MBFF mapping:
   - naming convention
   - mapping file
   - PrimeTime attributes
   - synthesis reports
7. Identify vendor-library pin-role information and relevant PrimeTime/lib attributes.
8. List all assumptions and unknowns. Do not silently guess behavior.

`RD_DISCOVERY.md` is internal-only unless it has been independently sanitized and approved.

## 4. Architecture

Use runtime wrappers; do not create a compiler that regenerates a separate plain SDC as the primary flow.

```text
Block Tcl/SDC
    -> NSW command adapter
    -> execution context
    -> object/clock resolver
    -> command-specific policy
    -> native PrimeTime command
```

Implement these modules:

### 4.1 Execution Context

Store at least:

- execution level: `BLK`, `PARTITION`, or `TOP`
- current Block/Partition instance
- hierarchy stage
- scenario/mode when relevant
- trace level
- strictness policy

Do not require every Block SDC command to contain `$whole_chp`-style conditionals.

### 4.2 Object Resolver

Provide one shared resolver used by all query and constraint wrappers.

Supported object classes for v0.1:

- cell
- pin
- clock

Resolver results must classify each mapping as:

```text
EXACT
EXPANDED
COLLAPSED
SUBSTITUTED
MISSING
AMBIGUOUS
NON_PORTABLE
```

Preserve PrimeTime collections. Do not treat opaque collections as ordinary Tcl strings unless a documented PrimeTime API explicitly converts them.

### 4.3 Clock Lineage Registry

Represent relationships independently from output clock names:

```text
local clock -> parent/master clock(s) -> generated clock(s) -> root clock(s)
```

- Naming prefixes are labels, not identity.
- Support one local clock mapping to multiple Top clocks.
- Support composed hierarchy mapping: `BLK -> Partition -> TOP`.
- Do not require a repeated `-top_list` on every command. A per-command override may be supported, but the normal source is the shared registry.

### 4.4 Command Adapters

Each adapter must:

1. Parse only its own NSW metadata and documented native options.
2. Preserve native argument values and order where semantically relevant.
3. Delegate object resolution to the shared resolver.
4. Apply command-specific expansion rules.
5. Call the original PrimeTime command.
6. Produce a structured trace record.

Do not apply a generic Cartesian product to `-from`, `-through`, and `-to` collections.

### 4.5 Native Dispatch

- Preserve access to the original PrimeTime commands without recursive wrapper calls.
- Keep dispatch logic centralized.
- Validate command availability at startup.
- Re-sourcing NSW must be idempotent or fail with a clear error.

## 5. v0.1 Command Scope

Implement only the following initial vertical slice:

```text
nvt_get_cells
nvt_get_pins
nvt_get_clocks
nvt_create_clock
nvt_create_generated_clock
nvt_set_false_path
nvt_set_case_analysis
```

If an established internal API already exists, preserve compatibility where practical and document deviations in `docs/COMPATIBILITY.md`.

Do not implement additional wrappers unless they are required by the selected v0.1 testcases. Record other commands in `docs/UNSUPPORTED.md`.

## 6. MBFF Requirements

MBFF resolution must be bit-aware. A separator-only implementation is insufficient.

The internal model must support relationships equivalent to:

```text
logical register   physical cell   logical pin   physical pin
REG_A[0]           MBFF_001        D             D0
REG_A[1]           MBFF_001        D             D1
REG_A[0]           MBFF_001        Q             Q0
REG_A[1]           MBFF_001        Q             Q1
REG_A[*]           MBFF_001        CK            CP
```

Handle and test:

- bit reordering
- shared clock/reset/set pins
- one-to-many replication
- many-to-one collapse
- duplicate-object removal
- missing bit mapping
- ambiguous mapping

Do not infer bit ordering from names when authoritative mapping data exists.

## 7. Cross-Library Requirements

Use semantic pin roles as the primary model:

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

Vendor synonym tables such as `CK <-> CP` may be used as fallback configuration, not as the only source of truth.

Where possible, validate:

- positive-edge versus negative-edge behavior
- set/reset polarity
- flip-flop versus latch
- functional versus scan/test pins
- integrated clock-gating pin roles

Keep real vendor mappings in an internal configuration layer, separate from exportable core code.

## 8. Error and Trace Model

Every nontrivial operation must emit a structured internal trace containing:

```text
NSW version
test/call ID
source file and line when available
wrapper command
execution context
original selector or collection summary
mapping status
input count
resolved count
native command count
policy decision
error/warning code
```

Use stable error codes, for example:

```text
NSW-CTX-xxx
NSW-PARSE-xxx
NSW-RESOLVE-xxx
NSW-CLOCK-xxx
NSW-DISPATCH-xxx
NSW-UNSUPPORTED-xxx
```

Provide separate outputs:

- full internal trace, which may contain company data and stays in RD
- sanitized summary, which contains counts, statuses, and synthetic/stable identifiers only

Unknown, ambiguous, or semantically unsafe behavior must not silently pass.

## 9. Required Tests

### 9.1 Pure Tcl / Mock Tests

Create tests that do not require company data or a PrimeTime license for:

- argument parsing
- context selection
- mapping composition
- MBFF exact/expanded/collapsed cases
- vendor semantic-role substitution
- duplicate removal
- missing and ambiguous policies
- trace and error-code generation
- wrapper re-source behavior

### 9.2 PrimeTime Integration Tests

Create `tests/primetime/run_all.tcl` that runs inside RD PrimeTime and tests:

1. Native BLK pass-through.
2. BLK-to-TOP one-to-many clock mapping.
3. Generated-clock master/source expansion.
4. MBFF bit-specific D/Q mapping.
5. Shared MBFF clock-pin collapse.
6. Cross-library clock-pin substitution.
7. `set_false_path` endpoint mapping without unsafe Cartesian expansion.
8. `set_case_analysis` pass, skip, conflict, and missing-object behavior.
9. Empty collection behavior.
10. Re-sourcing NSW.

Each test must have an explicit expected result and must return pass/fail without requiring manual log interpretation.

## 10. Synthetic Exportable Examples

Create synthetic examples that reproduce the structure of real use cases without company identifiers:

```text
examples/synthetic/
├─ dynamic_block_constraint.tcl
├─ mbff_mapping.csv
├─ vendor_pin_mapping.csv
├─ hierarchy_mapping.csv
└─ expected_behavior.md
```

Sanitization requirements:

- Use consistent pseudonyms.
- Preserve hierarchy depth and relationships.
- Preserve bus indices, escaping, wildcards, regexp, and separators.
- Preserve collection cardinality.
- Preserve Tcl control flow and option order.
- Do not include comments or paths that reveal projects, users, vendors, or products.

## 11. Repository Layout

Recommended layout:

```text
nsw/
├─ README.md
├─ DESIGN.md
├─ ASSUMPTIONS.md
├─ CHANGELOG.md
├─ src/
│  ├─ nsw.tcl
│  ├─ core/
│  ├─ resolver/
│  ├─ clock/
│  └─ adapters/
├─ config/
│  └─ schema/
├─ tests/
│  ├─ mock/
│  └─ primetime/
├─ examples/
│  └─ synthetic/
├─ docs/
│  ├─ RD_DISCOVERY.md
│  ├─ COMPATIBILITY.md
│  └─ UNSUPPORTED.md
└─ tools/
   ├─ run_mock_tests.tcl
   └─ make_export_review_package.tcl
```

Do not place internal vendor mappings, real constraints, or real logs in the exportable repository tree.

## 12. Deliverables

Produce:

1. Working NSW v0.1 source.
2. Pure Tcl/mock test suite.
3. PrimeTime integration test suite and result summary.
4. Synthetic examples.
5. Architecture and compatibility documentation.
6. Explicit assumptions and unsupported-case list.
7. Internal full test report.
8. Separate export-review package containing only generic code and synthetic data.

Before preparing the export-review package, scan it for:

- company/project names
- internal hostnames and paths
- usernames and email addresses
- library/vendor names that are not approved for release
- real cell, instance, pin, clock, and hierarchy names
- copied proprietary documentation
- real constraint fragments

## 13. Acceptance Criteria

v0.1 is complete only when:

- The same synthetic dynamic Block constraint runs in BLK and TOP contexts.
- Native PrimeTime commands remain reachable and are not recursively wrapped.
- PrimeTime collections are preserved correctly.
- MBFF bit mapping and shared-pin collapse pass integration tests.
- Cross-library semantic pin substitution passes integration tests.
- One-to-many clock/generated-clock handling passes integration tests.
- Missing and ambiguous mappings produce deterministic policies and stable codes.
- All supported wrappers have mock and PrimeTime tests.
- Unsupported behavior is explicit rather than silently guessed.
- Export-review package contains no company-confidential data.

## 14. Final Report Format

At completion, provide:

```text
Implementation status:
PrimeTime version tested:
Supported commands:
Mock tests: passed/total
PrimeTime tests: passed/total
Known failures:
Assumptions requiring human confirmation:
Unsupported cases:
Compatibility deviations:
Export-review package path:
Export scan result:
```

If any requirement is unclear, inspect the actual RD usage first. Record unresolved points in `ASSUMPTIONS.md`; do not invent behavior.
