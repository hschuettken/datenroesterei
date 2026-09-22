# SAC Planning Knowledge — Planning Functions, Data Actions & Advanced Formulas

> Field reference for SAC Planning, compiled from SAP Help (current at Q2 2026 / 2026.8,
> cross-checked against older builds), SAP product blogs, SAP KBAs, and productive project
> experience. Core claims were independently verified in several review rounds; sections marked
> **[synthesis]** are well-grounded interpretation rather than verbatim doc text.
> SAC evolves quarterly — re-verify restrictions marked "currently" before relying on them.
>
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

**Modeling & planning logic** — §1 model fundamentals · §2 data actions · §3 embedded steps ·
§4 copy / cross-model copy / conversion · §5 advanced formulas · §6 allocations ·
§7 multi actions · §8 performance · §9 pitfalls · §10 classic → new model type ·
§11 production example · §12 field-tested gotchas · §12a asymmetric reporting ·
§13 authoring a data action end to end

**Companion files** — **`SAC_APIS.md`** (OAuth, Data Import/Export, Content Network, SCIM, InA,
the internal REST layer, import-job automation) · **`SAC_SCRIPTING.md`** (story and
analytic-application scripting)

---

## 1. Planning Model Fundamentals

### Planning model vs analytic model
- Analytic models don't allow planning operations (data entry, version management). Planning
  models add the required structure for these: a **planning date dimension** and a **version
  dimension** are mandatory.
- **Leaf-level storage**: planning models store data only at the lowest level (leaf) of each
  dimension hierarchy — one fact row per booked combination of leaf members. Parent members
  show aggregated child values. Data entered on a parent is **automatically disaggregated**
  to leaf members.
- Values not yet assigned to a specific leaf land on the **unassigned member (`#`)** that most
  planning dimensions carry. This is the natural source for allocations (see §6).

### The two import model types (both current, neither deprecated)
| | "Model" (new, measure-based) | "Account model" (classic) |
|---|---|---|
| Fact row | multiple measure values per row | exactly one measure (`SignedData`-style) |
| Account dimension | **optional** | **mandatory** (accounts carry the semantics) |
| Advanced Formulas | `[d/Measures]` is addressable like a dimension | everything keyed by account |
| Currency | multi-currency via conversion steps | conversion steps **not supported** |
| Cross-model copy | cannot bridge to account models (see §4.2) | cannot bridge to measure models |

Account models are NOT deprecated as of Q2 2026 (SAP KBA 3707921), but new development
favors the measure-based model type.

### Versions: public vs private
- **Public versions** are shared, live in the model's fact table, and have Version History
  (revertible changes). Editing a public version happens in *edit mode* (a private delta until
  published).
- **Private versions** are user-scoped sandboxes; they get published to a public version to
  become shared.
- Data actions run against either a public or a private version of the target model — the
  version is supplied at runtime via the **`TargetVersion` parameter**, never hardcoded in
  most step types (the version dimension is special-cased throughout, see §5.4).

---

## 2. Data Actions — the Container Object

**What they are.** Data actions are SAC's planning tool for structured changes to model data,
including copying data between models. They are *designed by modelers, executed by planners*.

**Four trigger paths:**
1. A **data action trigger** widget in a story / analytic application
2. **Calendar** scheduling
3. A **script object** in an analytic application (`DataAction` API)
4. As a **step inside a multi action** (§7)

**Parameters.** Data actions expose parameters (most importantly `TargetVersion`, plus
member/number dynamic parameters) that are filled at runtime by the planner, the trigger
configuration, or the calling multi action. Embedded data actions can be reused with
different dynamic parameter values per use.

### 2.1 The seven step types
1. **Copy** — copy between member sets within one model
2. **Cross-model copy** — copy from a source model into the target model
3. **Allocation** — run structured (legacy) allocations as a step
4. **Conversion** — currency conversion (the ONLY step type that converts; measure models only)
5. **Advanced formulas** — the scripting step (§5)
6. **Fact deletion** — declarative fact delete: dimension filters + Delete Mode (Delete Facts /
   Delete Zeros / Set Facts to Zero). A relatively recent step type (SAP Help "Add Steps to
   Your Data Actions"); `DELETE()` in Advanced Formulas remains the tool for calculated scopes.
7. **Embedded data action** — call another data action as a step

### 2.2 Transaction semantics — the key architectural constraint
The data action engine allows exactly **one target model and one target version** per data
action. All steps run in **a single transaction**:
- Any step failure **rolls back ALL changes** (all-or-nothing).
- Version History shows **one revertible entry** for the entire data action run.
- Publishing can only happen at the end, on that one version.

Need multiple versions, multiple models, mid-sequence publishing, or predictive steps?
That's a **multi action** (§7) — different engine, per-step commit.

---

## 3. Embedded Data Action Steps

- An embedded step is a **reference** to another data action; it always runs on the **same
  target version** as the parent (no separate `TargetVersion`).
- Multi-level nesting is allowed; **cycles are not** (a data action can never end up embedded
  within itself).
- The same embedded action can be reused multiple times with different dynamic parameter
  values per use.
- **Not a substitute for multi actions**: embedded actions still operate on a single version
  and can only publish at the end of the whole operation.

---

## 4. Copy, Cross-Model Copy & Conversion Steps

### 4.1 Copy step
- Copy rules map source member sets → target member sets, with filters and aggregation options.
- **Version handling**: the version dimension appears only in the *Filters* section (to fix a
  *source* version). With no version filter, data is copied **within the target version only**
  (set by `TargetVersion`).
- **No currency conversion ever** — values are copied as-is. Cross-currency copies require a
  dedicated conversion step.

### 4.2 Cross-model copy step
- Source-version filter is **mandatory**.
- **Cannot bridge account models ↔ measure-based models.** Documented workaround: use the
  `LINK()` function in an advanced formulas step instead.
- Same "no conversion" rule as copy steps.

### 4.3 Calculated / exception-aggregation sources
Calculated accounts/measures and exception-aggregation members CAN be copy-rule sources, but:
- No ancestor/descendant of a source may also be a source; no mixing hierarchies of one dimension.
- Performance penalty — SAP: *"For fastest performance, filter out these accounts instead."*
- The restrictions lift for exception aggregation if you create **one copy rule per leaf member**
  of the exception-aggregation dimension (so no aggregation is needed).

### 4.4 Conversion step
- The only step type that performs currency conversion; applies to multi-currency
  measure-based models. **Not supported for account models.**
- Configured with conversion rules, date settings (Booking Date / Fixed Date) and category
  settings (Dynamic / Fixed / Specific rate categories).

---

## 5. Advanced Formulas — the Scripting Language

### 5.0 The mental model: it is NOT an imperative language

This is the part that trips up everyone coming from ABAP/JS/SQL — and from BPC FOX. SAP
itself calls Advanced Formulas **"a declarative programming language, like SQL"** (Koerner,
SAP). The execution model, verified against SAP Help "Understand General Rules for Advanced
Formula Calculations" and SAP's "Advanced Formulas — how they work":

- **Every statement executes against a *scope* — a set of dimension-member tuples (data
  slices)** — not against a single row. `DATA() = RESULTLOOKUP() * 1.1` is implicitly "for
  every booked slice in the current scope, write value × 1.1". No visible loop; the engine
  iterates the tuple set for you.
- **RESULTLOOKUP does NOT aggregate over unmentioned dimensions — the opposite of BPC FOX.**
  FOX aggregates first, then calculates; SAC keeps every existing data slice separate and
  **calculates first, aggregates after**. SAP's canonical example: adding 20 to a value that
  exists on 2 Entity slices yields +40 in total in SAC (per-slice) where FOX yields +20
  (aggregate-then-add). Cross-dimension aggregation must be requested explicitly via
  `AGGREGATE_DIMENSIONS` (which writes the aggregate to `#` unless redirected with
  `AGGREGATE_WRITETO`).
- **Only existing fact records participate: `Null + 1 = Null`.** The engine is
  **fact-data-driven** by default — it operates on booked records only, and an empty source
  cell produces *no write*, not 0 (see §5.3). It switches to **master-data-driven** execution
  (generating member combinations, potentially exploding) only in three cases: **assignment
  of constants**, **asymmetric formulas** that duplicate one source value across many targets,
  and **the ELSE clause of an IF** (always master-data-driven). This switch is THE
  performance lever (§8).
- **The base scope is the full cartesian product** of all leaf members and measures in the
  model (excluding calculated members). A bare `DATA() = 100` with no MEMBERSET writes to
  *every* combination — SAP's example model (5 measures × 200 accounts × 150 sales offices ×
  48 products × 120 dates) gets **864 million cells** written by that one line. Constants
  force master-data-driven mode; always scope them.
- **Dimension matching is by-dimension, not by row.** In
  `DATA([d/Account]="B") = RESULTLOOKUP([d/Account]="A")`, every dimension you do NOT mention
  is matched member-by-member, slice-by-slice between source and target. Mention a dimension
  on either side and you pin/retarget it (asymmetric formula → duplication, master-data-driven).
- **Multiplying two `RESULTLOOKUP`s joins on the shared unpinned dimensions**: only slices
  with matching points-of-view multiply.
- **Writes are scope-cleans, not row-updates.** `DATA()` first *clears the entire target scope*,
  then writes results (§5.6). Two consecutive `DATA()` to the same POV: the second wins
  entirely. Accumulation requires `DATA.APPEND`.
- **Leaf-level only**: calculations run only on leaf members without account formulas.
  Calculated members can be *read* (never written) via RESULTLOOKUP/LINK when
  `CONFIG.READ_CALCULATED_MEMBER_VALUES` is ON — supported on HANA Cloud tenants only.

Think "SQL `UPDATE ... SELECT` over a cube with implicit join on unmentioned dimensions",
not "for-loop over records" — and forget FOX's aggregate-first habit.

### 5.1 Script structure, execution order & scoping model
```
1. CONFIG.*                      ← must come first
2. Variable declarations         ← VARIABLEMEMBER, FLOAT, INTEGER
3. MEMBERSET statements          ← step-wide scope
4. Instructions (sequential)     ← IF / FOREACH / FOR / DATA / DELETE / …
```
- **Read-after-write is guaranteed**: each line inherits the calculation results of previous
  lines. SAP's canonical example: with a=100, b=5, after `DATA(b)=RESULTLOOKUP(a)`, the line
  `DATA(c)=RESULTLOOKUP(b)*2` yields **200, not 10**. Same applies to VARIABLEMEMBER virtual
  members (written by one statement, read by the next; their data vanishes when the data
  action finishes).
- **Across steps**: data action steps execute sequentially, each calculating on the previous
  step's result; data is published to the version only **after ALL steps complete**.
- **Three-level scoping model** (SAP Help, verbatim concept): from broadest to most specific —
  1. **MEMBERSET scope** (step-wide, replaces the base scope per dimension),
  2. **condition scope** (IF / FOREACH; IF filters apply to everything between IF and ENDIF
     regardless of MEMBERSET),
  3. **statement scope** (members inside DATA/RESULTLOOKUP).
  **More specific scope OVERRIDES broader scope, and scopes need not intersect** — a MEMBERSET
  on account Salaries can be redirected to Onboarding Expenses inside an IF. So IF/statement
  scope is an *override/redirect*, not merely a narrowing filter.
- Dimensions not constrained anywhere default to *all leaf members* (base scope = cartesian
  product, §5.0) — scope hygiene is the #1 performance lever (§8).
- Syntax for master data: `[d/Dim]`, `[d/Dim].[p/Property]`, `[d/Dim].[h/Hierarchy]`,
  `[d/Measures]` (measure models). External/dynamic parameters: `%ParamName%`.

### 5.2 CONFIG settings
| Setting | Effect |
|---|---|
| `CONFIG.GENERATE_UNBOOKED_DATA = ON\|OFF` | Default **OFF**. See §5.3 — the single most important switch. |
| `CONFIG.FLIPPING_SIGN_ACCORDING_ACCTYPE = ON\|OFF` | Default OFF. ON: respect account type signs (INC/EXP debit/credit) in calculations — critical for P&L math. |
| `CONFIG.TIME_HIERARCHY = FISCALYEAR\|CALENDARYEAR` | Time granularity basis; user-managed date dimensions support only CALENDARYEAR. |
| `CONFIG.HIERARCHY [Model] = [d/Dim].[h/Hier]` | Use a non-default hierarchy (optional `INCLUDE_MEMBERS_NOT_IN_HIERARCHY`). For linked models: `MODEL [Name] HIERARCHY = … ENDMODEL`. |
| `CONFIG.TIME_ZONE_OFFSET = n` | −23..+23; shifts the UTC base for `TODAY()`. Must precede all instructions. |
| `CONFIG.READ_CALCULATED_MEMBER_VALUES = ON\|OFF` | Default OFF. ON: calculated members/measures become readable via RESULTLOOKUP/LINK (never writable). **HANA Cloud tenants only** (not HANA 2.0). |

### 5.3 Booked vs unbooked — `CONFIG.GENERATE_UNBOOKED_DATA`
- **OFF (default):** `RESULTLOOKUP`-based copies transfer **only booked data**. An empty
  source cell leaves an existing booked *target* value **unchanged** — a classic gotcha when
  "copying" a sparse version over a dense one leaves stale target values behind.
- **ON:** unbooked source cells are treated as **0** and will overwrite booked target cells
  (unbooked targets still stay unbooked). Costs performance — the engine materializes the
  cross-join of the scope.
- `CARRYFORWARD` always treats unbooked as 0 regardless of this setting.

### 5.4 MEMBERSET — step scope
```
MEMBERSET [d/Dim] = "Member"
MEMBERSET [d/Dim] != "Member"                       // exclusion
MEMBERSET [d/Dim] = ("M1", "M2")
MEMBERSET [d/DATE] = "201701" TO "201712"           // ranges
MEMBERSET [d/PRODUCT].[p/FACTOR] = 1                // attribute filter
MEMBERSET [d/Dim] = [d/Other].[p/Attr]              // attribute-driven
```
- Scopes the **entire step**.
- **The Version dimension can NEVER appear in MEMBERSET** — version is special-cased and set
  by the `TargetVersion` parameter. (`RESULTLOOKUP` may still *read* `[d/Version]="public.X"` —
  public versions only.)
- Member selectors usable in scope/conditions:
  - `BASEMEMBER([d/Dim], "Parent" [, "Parent2"…])` — all leaves under parent(s); respects
    `CONFIG.HIERARCHY`; date dims need the full hierarchical path
    (`BASEMEMBER([d/Time], "[2017].[20173].[201709]")`); accepts `%params%`.
  - `ELIMMEMBER([d/Dim], M1, M2 [, attr])` — IC elimination member under first common parent;
    defaults to `[p/ELIMINATION]="Y"`; only valid inside `DATA()`; no external params.

### 5.5 Variables
```
VARIABLEMEMBER #tmp OF [d/Account]    // virtual member, '#'-prefixed, dimension-bound
FLOAT   @f                            // scalar, default 0.0
INTEGER @i                            // scalar, default 0, ±2,147,483,647
```
- `VARIABLEMEMBER` creates a **virtual member** for intermediate cube values — *currently*
  usable **only inside `DATA` and `RESULTLOOKUP`**. Name length limits: 256 chars (SAC dims),
  32 (BPC-imported), 6/8 (date dims month/day granularity).
- `@` scalar variables are case-insensitive; INTEGER cannot be assigned directly to `DATA`.
- All declarations go after CONFIG, before instructions.

```
VARIABLEMEMBER #sumOfSales OF [d/Account]
DATA([d/Account] = #sumOfSales, [d/Product] = "#") = RESULTLOOKUP([d/Account] = "SALES")
IF RESULTLOOKUP([d/Account] = #sumOfSales) > 1000 THEN
    DATA([d/Account] = "REBATE") = RESULTLOOKUP([d/Account] = "SALES") * 0.1
ENDIF
```

### 5.6 DATA / DATA.APPEND / DELETE — writing
```
DATA([d/Dim] = "Member", …) = <expression>
DATA.APPEND([d/Dim] = "Member", …) = <expression>      // needs ≥1 dimension
DELETE([d/Dim] = "Member", …)                          // clears facts in scope
```
- **`DATA` first CLEANS the entire target scope, then writes.** Consecutive `DATA` writes to
  the same POV overwrite each other — last one wins:
  ```
  DATA([d/FLOW]="TOTAL") = RESULTLOOKUP([d/FLOW]="OPENING")   // 50
  DATA([d/FLOW]="TOTAL") = RESULTLOOKUP([d/FLOW]="DELTA")     // overwrites → 30
  DATA([d/FLOW]="TOTAL") = RESULTLOOKUP([d/FLOW]="OTHER")     // overwrites → 20  ⇒ TOTAL = 20
  ```
- **`DATA.APPEND` accumulates** (adds to whatever is there) — same three statements with
  `.APPEND` yield `TOTAL = 100`. Use it whenever several writes target one POV (aggregating
  a dimension away, summing flows, …).
- Version dimension is **not allowed** in the `DATA()` target definition (TargetVersion rules).
- `DELETE` accepts dimension filters and attribute filters, supports
  `DELETE([d/Measures]="M1")`; **no variable members**; **not supported on BPC-imported models**.

### 5.7 RESULTLOOKUP — reading
```
RESULTLOOKUP()                                  // whole current scope
RESULTLOOKUP([d/Account] = "PRICE")             // pin a dimension
RESULTLOOKUP([d/Date] = PREVIOUS(1))            // time-shifted read
```
- Returns the **post-aggregation booked data set** for the given POV; unmentioned dimensions
  follow the current scope and match member-by-member against the write target.
- Each `RESULTLOOKUP` is a **database read — the dominant performance cost** (§8).
- Version reads: public versions only, no private versions.
- Multiplication of multiple `RESULTLOOKUP`s joins on matching POVs of shared dimensions.

### 5.8 IF / ELSEIF / ELSE — scope filters, not branches
```
IF [d/Account].[p/ACCTYPE] = ("AST","LEQ") AND RESULTLOOKUP([d/Account]="PRICE") > 0 THEN
    …
ELSEIF @amount > 100 THEN
    …
ELSE
    …
ENDIF
```
- Conditions: dimension filters, property filters, cell-value filters (`RESULTLOOKUP(…) > 0`),
  scalar variables, `%params%`, time functions (`DAY([d/Date]) > 15`), `ATTRIBUTE(…)`,
  member selectors (`BASEMEMBER`), `!= NULL`; combinable with AND/OR.
- **Semantics (verified):** IF is *condition scope* (§5.1) — its filters apply to all
  statements between IF and ENDIF regardless of MEMBERSET, and can override/redirect the
  MEMBERSET scope, not just narrow it. Since 2021.02, `ELSEIF` excludes the scope already
  consumed by previous branches; `ELSE` gets what's left.
- **The RESULTLOOKUP-condition transformation (counterintuitive, verified):** an IF condition
  containing a `RESULTLOOKUP` is rewritten at runtime into **member-ID filters on the
  dimensions NOT specified in that RESULTLOOKUP** (member-ID sets derived from existing fact
  data). Consequence: **the MORE dimensions you put into the condition's RESULTLOOKUP — the
  more restrictive it looks — the MORE data the branch actually affects**, because fewer
  remaining dimensions get filtered. Plan conditions accordingly.
- **ELSE is always master-data-driven** (§5.0) — it generates member combinations rather than
  reading booked facts. A large ELSE scope is expensive; filter it down.
- Restrictions: no comparing two identical time functions; no nested time functions
  (`DAY(LAST())` invalid); measure filters with OR unsupported; mixing measure and non-measure
  filters disables ELSEIF (measure-based models); non-numeric comparisons like
  `IF [d/DATE] > "2019-03-15"` invalid.

### 5.9 FOREACH / FOREACH.BOOKED / FOR / BREAK — explicit iteration
```
FOREACH [d/Date]                          // every leaf member, ASC default
FOREACH [d/Date].[p/Year] DESC            // grouped by attribute value
FOREACH.BOOKED [d/Customer], [d/Date]     // only combinations with booked data
FOR @i = 1 TO @n STEP 1 … ENDFOR          // scalar counter loop (INTEGER)
```
- `FOREACH` repeats the enclosed statements **once per member (or member combination)** in
  scope — needed ONLY when an iteration depends on results of the *previous* iteration
  (running balances, depreciation schedules). Otherwise a plain `DATA()=RESULTLOOKUP()` does
  the same work set-based and far faster (§8).
- Attribute iteration groups members sharing the attribute value; members without a value
  drop out of scope.
- `FOREACH.BOOKED` skips empty combinations — documented performance optimization.
- Loop cap: **no documented hard iteration limit** (the 10,000 in KBA 3658925 is an example
  iteration count, not a limit; the AF Reference Guide states none). `BREAK` exits the
  innermost loop.
- Example (self-referential, genuinely needs the loop):
  ```
  INTEGER @UsefulLife
  @UsefulLife = ATTRIBUTE([d/Equipment].[p/Useful_Life])
  FOR @counter = 1 TO @UsefulLife
      DATA([d/Account]="Depreciation_Exp", [d/Date]=NEXT(@counter)) =
          RESULTLOOKUP([d/Account]="Equipment_Cost") / @UsefulLife
  ENDFOR
  ```

### 5.10 LINK — reading other models
```
DATA([d/Account]="Revenue") =
    LINK([Sales], [d/Measures]="Quantity", [d/Version]="public.Plan01") *
    LINK([Sales], [d/Measures]="Price",    [d/Version]="public.Plan01")
```
- Reads from a **linked model** inside an advanced formulas step — and is the documented
  workaround for cross-model copies between account and measure models.
- Requirements on the linked model: same currency-conversion setting, identical date
  granularity, fiscal-year settings aligned; user-managed date dim must cover all default
  model members.
- Filters: **version is REQUIRED** (`[d/Version]="public.X"`); measure models need a single
  measure pinned; linked-only dimensions need one member pinned (or mapped via a default-model
  property, e.g. `DATA([d/Account_Fin] = [HR].[d/Account_HR].[p/GL_Acc]) = LINK([HR], …)`);
  shared dimensions either define or omit (then matched member-by-member).
- Scope the linked model with a `MODEL [Name] … MEMBERSET … AGGREGATE_DIMENSIONS … ENDMODEL`
  block.

### 5.11 CARRYFORWARD — balance carry-forward without loops
```
MEMBERSET [d/DATE] = "201901" TO "201912"
DATA() = CARRYFORWARD([d/FLOW], "OPENING", "ENDING", "OPENING" + "CHANGE" + "OTHERS")
```
- Per period: `Closing = expression`; next period's Opening = previous Closing — the whole
  chain in one statement, replacing a FOREACH over dates.
- Args: flow dimension, opening member, closing member, calc expression (flow members with
  `+`/`-` only), optional 5th arg = target member (default: closing member).
- Date scope must be **consecutive** (`TO` ranges; member lists with gaps invalid).
- Always treats unbooked as 0. No external parameters in the member arguments.
- Works on `[d/Measures]` too (different exception-aggregation types per measure, e.g. FIRST
  for opening / LAST for closing).

### 5.12 ATTRIBUTE & time functions
- `ATTRIBUTE([d/Dim].[p/Attr] [, "Member"])` — numeric attributes only; without a member it
  returns attribute values for all scoped members (summed if assigned to a scalar); not usable
  in MEMBERSET.
- `NEXT(n[,gran[,date]])` / `PREVIOUS(…)` — time offsets, usable in MEMBERSET ranges and POVs.
- `TODAY()` (respects `CONFIG.TIME_ZONE_OFFSET`), `FIRST()`, `LAST()`, `PREYEARLAST()` —
  not usable in MEMBERSET; no nesting of time functions.
- `DAY|WEEK|MONTH|YEAR|PERIOD(date)` — numeric parts; `PERIOD()` returns a member;
  `DAYSINMONTH/DAYSINYEAR` for proration:
  `RESULTLOOKUP() * DAY([d/Date]) / DAYSINMONTH([d/Date])`.
- `DATERATIO(start, end, period)` — overlap fraction of a period;
  `DATEDIFF(d1, d2, gran, CalendarDiff|Floor|Ceiling)`.

### 5.13 AGGREGATE_DIMENSIONS / AGGREGATE_WRITETO
```
AGGREGATE_DIMENSIONS [d/CostCenter]
AGGREGATE_WRITETO   [d/CostCenter] = "#"
```
- Pre-aggregates dimensions before calculation (sum over them); each aggregated dimension in
  the default model needs an `AGGREGATE_WRITETO` leaf target (often `#`).
- Cannot aggregate versions or measures; aggregated dimensions can then NOT appear in
  `DATA`, `RESULTLOOKUP`, `DELETE`, `ATTRIBUTE`, `CARRYFORWARD`, `LINK`.
- Inside a `MODEL … ENDMODEL` block, aggregates linked-model dimensions (no WRITETO needed).

### 5.14 Numeric and conversion functions

The reference guide documents a set of scalar functions that are easy to overlook because most
advanced-formula examples never leave addition and multiplication:

| Group | Functions |
|---|---|
| Sign / magnitude | `ABS` |
| Logarithms & powers | `LOG` (natural), `LOG10`, `POWER`, `SQRT` |
| Rounding | `ROUND` (to a given precision), `FLOOR`, `CEIL`, `TRUNC` |
| Remainder | `MOD` |
| Type conversion | `FLOAT(…)`, `INT(…)` |

Two practical notes. **Rounding is a modelling decision, not a display decision** — if the plan
is published to a system that reconciles to the cent, round in the formula rather than relying on
the story's formatting, or the sum of the displayed rows will not equal the displayed total.
And **`INT` truncates rather than rounds**, so `INT(x + 0.5)` is the usual idiom when you want
commercial rounding of a positive number — or simply use `ROUND`.

> **Reading the reference guide.** SAP documents the syntax in a BNF-style notation:
> `< >` encloses a syntactic element, `::=` defines it, `[ ]` marks optional parts, `{ }` groups
> or repeats, `|` separates alternatives. Worth knowing before looking a signature up, because
> the guide gives the grammar rather than worked examples.

---

## 6. Allocations

Two delivery mechanisms; the data-action step is the strategic one:
- **Legacy allocations app** ("allocation processes") — being phased out long-term.
- **Allocation step in a data action** — references a structured (legacy) allocation built on
  the data action's default model; SAP's stated standard going forward.

### 6.1 Structure
- An **allocation process** is a container of **allocation steps**; each step fixes its
  **source dimension** and **target dimension** (most settings immutable after creation —
  plan the step before creating it).
- A step needs **at least one source, one driver, and one target dimension**.
- Each step holds **allocation rules** with three components:
  - **Source members** — members of the source dimension holding the value to allocate
    (parents allowed);
  - **Driver** — an account, a measure, or measures-and-accounts; driver values determine the
    proportional split among targets;
  - **Target members** — recipients; multiple per rule.
- **Direct Assignment**: pick it as the rule's driver (or paste `_DIRECT_` into the driver
  cell) to route the entire source value to a single leaf target member — e.g. audit members.

### 6.2 Run-time behavior (the part that bites)
- **Source values live on the unassigned (`#`) member** of the target dimension and are
  **moved off it (consumed)** by the run. Enabling **Keep Source** leaves them on `#`
  (copy semantics, good for audit). Note: `#` is *implicitly* the source pool — it is NOT a
  selectable source member in the rule (a widely repeated claim that did not survive
  verification; KBA 2840982 documents a 2019.15 defect where selecting `#` as source wasn't
  recognized).
- **Target data is ADDITIVE by default** — re-running accumulates extra value on targets.
  **Overwrite Target** zeroes the target members **once at step start** (not per repetition
  in multi-repetition steps), making the allocation replace instead of accumulate.
- **Keep Source + Overwrite Target together = idempotent step**: re-runnable without
  depleting sources or double-counting targets. Edge case (KBA 2936022): if `#` itself is
  among the rule's *targets*, Keep Source is ignored (source gets zeroed) — exclude `#`
  from targets.
- **Drivers and reference dimensions**: drivers are broken down by the model's time
  granularity; **Reference Dimensions** under *Driver Context* (Date is the default) refine
  the driver breakdown further so allocations respect period/dimension boundaries instead of
  averaging across them.
- **Version-pinned drivers**: there is NO native "reference version" field in allocation
  rules. The documented mechanism for driver values from a fixed version (independent of the
  target version) is a **calculated account using a LOOKUP function pinned to that version**,
  used as the rule's driver.
- For **reallocation steps**, Keep Source means source members retain their original values
  *plus* anything allocated to them as targets.

### 6.3 Restrictions & permissions
- Account dimension can't be a target (it carries the drivers); date dimensions have no `#`
  member, so they're only available as a target when reallocating from the same date dimension.
- In the data-action step you can add member/parameter filters, but NOT on the account
  dimension at step level; planners can't add filters at run time.
- Typical uses: indirect cost allocation (IT/admin/facilities → departments, products),
  disaggregating high-level plan values to leaves.
- Permissions: planning admin / modeler / planner-reporter create & manage; planning users
  (incl. viewers) with read+execute on steps, processes, model & data can run them.

---

## 7. Multi Actions — the Orchestration Layer

Multi actions chain **data action steps, version management (publish) steps, predictive
steps, data locking steps, data import steps, and API steps** across **multiple models and
multiple versions**, from a single trigger (story/analytic app widget, or Calendar).

### 7.1 Transaction semantics — the contrast that decides everything
| | Data action | Multi action |
|---|---|---|
| Engine | data engine | planning process engine |
| Targets | 1 model, 1 version | many models, many versions |
| Commit | one transaction, all steps | **each step commits separately** |
| On failure | everything rolls back | later steps don't run; **completed steps stay** |
| Version History | one entry for the whole run | one revertible entry **per data action step** |
| Publish | only at the end | **mid-sequence** publish steps |

### 7.2 The six step types (from SAP Help "Automate a Planning and Predictive Workflow…")

Failure rule for ALL step types, verbatim: *"If there's an error while running a step, the
following steps won't run. The previous steps will still take effect."* No rollback, no
compensating actions, **no retry mechanism** — design every step to be safely re-runnable.

1. **Data action step** — runs a data action with fixed or parameter-driven values. Three
   publish options: *Do not publish* / *Publish and fail if there are warnings* (fails on
   data locks/restrictions) / *Publish and ignore warnings* (publishes unaffected data,
   discards restricted data). Optional "use recommended planning area if target version
   isn't in edit mode". **Gotcha (verbatim): "All of your unpublished changes to the target
   version will be published, even if they weren't part of the data action."** Auto-publish
   applies to public versions only; private versions and BPC write-back models need manual
   publication.
2. **Version management step** — publishes a specified version (fixed public version or
   parameter-driven). Publishing a private version publishes its *source public version*
   instead.
3. **Predictive step** — runs a time-series-forecast predictive scenario: retrains the model
   and writes forecasts to a version (no auto-publish). Optional "Save Forecast Values for
   Past Periods" (slower). Only time-series scenarios based on planning models.
4. **Data locking step** — sets lock state (**Open / Locked / Restricted** = lock-owners-only)
   on a dimension-filtered slice of a model. Model must have data locking enabled.
5. **Data import step** — runs an import job from Data Management (Import Model Data or
   Import Master Data). NOT supported: job groups, export jobs, local-file-imported models,
   and Concur/ERP/Fieldglass/Dataset/Salesforce sources.
6. **API step** — calls an external HTTPS endpoint (POST only) via an HTTP API connection.
   JSON body with parameter insertion (incl. `.baseMembers` expansion); custom headers limited
   to `Prefer: respond-async` and `X-*` keys. Synchronous or asynchronous result handling:
   expects HTTP 202 (in progress) / 200 (success) / 4xx–5xx (error), with optional JSON body
   evaluation (`jobId`, `status` = DONE/FAILED/IN_PROCESS, `message`). This is the hook for
   triggering Datasphere task chains, CPI flows, etc.

### 7.3 Decision rule (SAP's documented table)
- Run a data action repeatedly on the same version, then publish → either works.
- Multiple target **versions** → multi action.
- Multiple target **models** → multi action.
- **Publish between** data actions → multi action.
- **Predictive** refresh workflow → multi action.

### 7.4 Predictive planning integration
- Multi actions are THE integration point: one run can (1) prepare inputs via data actions,
  (2) **refresh the time-series-forecasting predictive model**, (3) write refreshed forecasts
  back into the story version.
- Predictive steps require predictive-scenario permissions (Predictive Content Creator /
  Predictive Admin; BI Admin and Planning Admin inherit Predictive Admin).
- Predictive steps do not exist in plain data actions.

---

## 8. Performance Best Practices

1. **RESULTLOOKUP is the main cost driver** — each call is a database read. Factor algebra to
   minimize calls:
   `RESULTLOOKUP("A")*(RESULTLOOKUP("B")+RESULTLOOKUP("C")+RESULTLOOKUP("D"))`
   — 4 reads instead of 6 for the expanded form.
2. **Avoid FOREACH unless iteration N depends on iteration N−1.** Replacements, in order:
   - plain `DATA() = RESULTLOOKUP()` (set-based, no loop) when iterations are independent;
   - `CARRYFORWARD` for additive period-over-period flows;
   - `FOREACH.BOOKED` to skip empty combinations;
   - `BREAK` to exit early;
   - nest `FOREACH` inside `IF`, not `IF` inside `FOREACH`.
3. **Check the Estimated Function Scope**: after validating the script, hover over `DATA`,
   `RESULTLOOKUP`, `LINK`, `CARRYFORWARD`, or `DELETE` in the editor → member counts per
   dimension. Restrict every dimension you can. Caveat: the estimate ignores fact-data-dependent
   filters (IF value filters, variable/number comparisons) — real scope can be smaller;
   `ATTRIBUTE` and date functions show single-dimension scope only.
4. **Scope hygiene**: MEMBERSET every dimension that matters; an unconstrained dimension means
   "all leaves". Watch the implicit ELSE scope in IF blocks.
5. **Leave `CONFIG.GENERATE_UNBOOKED_DATA` OFF** unless you specifically need zero-fill
   semantics — ON materializes the scope cross-join.
6. In copy steps, **filter out calculated / exception-aggregation accounts** unless needed.

---

## 9. Common Pitfalls (field checklist)

- **Stale target values after a "copy"**: with `GENERATE_UNBOOKED_DATA` OFF, unbooked source
  cells don't clear booked target cells. Either `DELETE` the target scope first, or switch the
  CONFIG on for that step.
- **`DATA` overwrites, it doesn't add** — accumulating writes silently keep only the last one.
  Use `DATA.APPEND` (and remember APPEND needs ≥1 dimension in its target).
- **Version in the wrong place**: MEMBERSET on Version → invalid; `DATA([d/Version]=…)` →
  invalid; version comes from `TargetVersion`; `RESULTLOOKUP` can read other *public* versions
  only; cross-model copy *requires* a source-version filter.
- **One data action ≠ multi-version workflow**: needing to publish mid-stream or touch a second
  version/model means a multi action, not embedded data actions.
- **Multi action failures don't roll back completed steps** — design steps to be re-runnable.
- **FOREACH**: no documented hard iteration limit (see §5.9); performance scales with the
  iteration count — KBA 3658925 works through an example of 10,000 iterations vs. 500 with
  attribute grouping. Attribute-grouped FOREACH drops members without the attribute from scope.
- **VARIABLEMEMBER only works inside DATA/RESULTLOOKUP** (currently) — not in DELETE, IF
  dimension filters, etc.
- **No DELETE on BPC-imported models.**
- **Account ↔ measure model bridge**: cross-model copy refuses; only `LINK()` works.
- **Conversion**: copy steps never convert currency; conversion steps don't exist for account
  models.
- **Time functions**: no nesting, most not allowed in MEMBERSET, `PERIOD()` returns a member
  not usable in MEMBERSET.
- **CARRYFORWARD needs a gapless date scope** and ignores `GENERATE_UNBOOKED_DATA` (always
  treats unbooked as 0).
- **A "more specific" IF condition affects MORE data**: an IF on `RESULTLOOKUP` becomes
  member-ID filters on the dimensions *not* in the lookup — adding dimensions to the
  condition's RESULTLOOKUP widens, not narrows, the affected set (§5.8).
- **Unscoped constants explode**: `DATA() = 100` without MEMBERSET writes the full cartesian
  product of all leaf members × measures (864M cells in SAP's example) — constants,
  asymmetric formulas, and ELSE all switch the engine to master-data-driven mode.
- **Don't expect FOX behavior**: RESULTLOOKUP keeps data slices separate (no implicit
  aggregation over unmentioned dimensions); use `AGGREGATE_DIMENSIONS` when you actually
  want a sum, and remember it writes to `#` unless redirected via `AGGREGATE_WRITETO`.
- **Multi action data-action step with auto-publish publishes EVERYTHING** unpublished on
  the target version — including changes that weren't part of the data action (§7.2).
- **Allocations accumulate by default** — re-runs double-count unless *Overwrite Target* is
  set; the idempotent pattern is Keep Source + Overwrite Target, but it breaks if `#` is
  among the rule's targets (KBA 2936022).
- **A raw parameter with an empty value collapses to the default member (`#`), not to "all"** —
  wrap it in `BASEMEMBER` or accept silent scope loss (§12).
- **A data action can complete successfully and write nothing** when the target version lacks the
  date properties its MEMBERSET reads (§12).
- **The private-version limit is a planning-area problem**, not a filter or data-volume problem —
  the planning area has to be set on the table (§12).
- **Calculated members are evaluated after aggregation**, so inverse formulas are only correct at
  cell level; store the figures and compute on entry instead (§12).
- **A member with a formula refuses every write** — import and data action alike (§12).
- **The row limit of a captured analytical query defaults low**, and a result landing exactly on
  the limit is truncated, not complete (`SAC_APIS.md` §4).

---

## 10. Classic Account Model → New Model: Status & Migration

*(Direct read of SAP Help "Migrate From a Classic Account Model to a New Model Type" +
KBA 3707921; no independent corroboration was found, so treat this section as
single-source.)*

- **No deprecation** of classic account models as of Q2 2026 (KBA 3707921); no stated
  timeline or mandatory migration. SAP positions the measure-based type as offering "much
  more possibilities and flexibility" (accounts + multiple measures in one model).
- **Migration tool**: a *"Migrate to New Model Type"* button in the Modeler.
  **The migration cannot be undone.**
- **Blockers** — migration refuses if the model has **dependent objects** or **currency
  conversion turned on** (disable first; the new model is created with conversion off and
  currency measures must be reconfigured manually).
- **Not migrated / manual rework:**
  - **Stories** built on the classic model are not migrated — they must be adjusted to the
    new model.
  - **MS Office add-in workbooks** — the model must be re-inserted (and SAP *Analysis for
    Office* doesn't support measure-based models at all).
  - **Import/export jobs** — old jobs are incompatible with the new model type and must be
    recreated; future-dated job schedules don't carry over (history stays viewable).
- **Keep a classic model** when: it can't be migrated yet, it uses **BPC import data
  connections**, or it's wired into Office add-in workbooks you can't rework.
- For new implementations the practical default is the measure-based model (conversion steps,
  multi-measure facts, `[d/Measures]` in Advanced Formulas) unless a BPC/AfO constraint
  forces the classic type. **[synthesis]**

---

## 11. Production-confirmed example (anonymized)

A single-step prefill data action from a productive planning implementation, **lightly
anonymized from a production capture** — dimension and member names replaced, one literal
replaced by a parameter. The shape and the constructs are the shipping original; treat the
identifiers as illustrative. It shows the documented rules holding up in real code:

```
CONFIG.TIME_HIERARCHY = CALENDARYEAR
CONFIG.GENERATE_UNBOOKED_DATA = OFF
MEMBERSET [d/Measures] = "Value"
MEMBERSET [d/Date]     = [d/Version].[p/DATE_FROM] TO [d/Version].[p/DATE_TO]
MEMBERSET [d/Channel]  = %Channel%
MEMBERSET [d/Customer] = BASEMEMBER([d/Customer], %Customer%)
MEMBERSET [d/Product]  = BASEMEMBER([d/Product], %Product%)
MEMBERSET [d/Scenario] = %TargetScenario%
MEMBERSET [d/Account]  = ("GROSS_SALES","LIST_PRICE")
IF DATEDIFF([d/Date], %lastActualMonth%, "MONTH") <= 0 THEN
    DATA() = RESULTLOOKUP([d/Scenario] = %ScenarioSource%)
ENDIF
```
What it demonstrates: **CONFIG block first**; **`GENERATE_UNBOOKED_DATA = OFF` explicitly
set** (§5.3); **Version never in MEMBERSET — it's the `TargetVersion` parameter** while a
version *property* (`[d/Version].[p/DATE_FROM]`) legitimately drives a Date range (§5.4);
**`BASEMEMBER([dim], %param%)`** for parent→leaf scoping with prompts; **`IF … DATA() =
RESULTLOOKUP(…)`** as a scenario/version copy gated by `DATEDIFF`; and the account-based model
shape (`[d/Measures]="Value"` + account members carrying the semantics). Internally a data
action is a `PLANNINGSEQUENCE` object (multi action = `MULTIACTIONS`).

---

## 12. Field-Tested Gotchas Beyond the Docs

Hard-won lessons from productive planning implementations. All generalized — none of these
depend on a specific customer setup.

### Master data & hierarchies

- **Never use `#` (unassigned) as a node in a parent-child hierarchy.** `#` works as a flat
  "unassigned" bucket, but as soon as it appears as a *parent* in a parent-child hierarchy,
  hierarchy processing breaks in non-obvious ways (fact loads reject rows, drill-downs
  misbehave). Model an explicit `NOT_ASSIGNED` leaf under a real root node instead.
- **The cross-hierarchy leaf rule blocks fact loads silently-ish:** a member that is a
  *parent in ANY parent-child hierarchy of the dimension* cannot be booked ("must be leaf
  node in hierarchy"). If a member must be bookable in hierarchy A but is a node in
  hierarchy B, hierarchy B has to go (or become an attribute-based view). Check ALL
  hierarchies of a dimension before designing the booking grain.
- **Model renaming:** models CAN be renamed since the Files-area rework (older KBAs claiming
  otherwise are stale) — only the technical ID is fixed at creation.

### Imports

- **Incomplete "Sort Key" (mapping grain) in an import job = silent data loss with 0
  rejects.** If the mapped columns don't cover the full grain of the source, rows collapse
  by last-one-wins and nothing flags it. Always map the complete key.
- Unmapped import columns land on `#` — a sudden surge of `#` values after an import is a
  mapping symptom, not a data symptom.
- **Master data before facts, always.** SAC accepts a fact row only if every dimension key
  already exists as a member. Load all dimensions first. Otherwise the refresh reports success
  and inserts **0 rows** — green job, no rejects, no data.
- **In the fact mapping step, the Version target defaults to a fixed value** (typically
  `public.Actual`). If you do not explicitly remap it to your version column, the whole load
  lands in Actuals. The proof that it is column-mapped rather than constant is a column
  validation call on Version — or, more simply, checking where the rows ended up.
- **Import mode is not readable from the deleted-row count when the target was already empty.**
  A run showing `deletedCount 0` proves nothing about whether the job replaces or appends. Where
  it matters, clear the target version deliberately before a reload — an aborted run otherwise
  leaves partial data that the next run adds to rather than replaces.
- **A member carrying a formula is a calculated member and refuses all writes** — neither import
  nor data action can post to it. Before turning an account into a calculated one, redirect the
  load views to a stored account and remove it from every `MEMBERSET` that writes to it.
- Facts can only post to **stored leaf** members: `Cannot use calculated measure` and
  `Member does not exist` are the two rejects that account for most "the load ran but the number
  is missing".

### Stories & data actions

- **The story filter bar silently scopes data-action triggers.** A data action fired from a
  story runs against the *filtered* context — a leftover page/story filter can shrink an
  initialization run by orders of magnitude with no warning. Before wiring a
  prefill/init/release trigger, check the filter bar state, and prefer explicit MEMBERSETs
  over relying on story context.
- **The story designer and the data-action editor cache the definition from the moment they were
  opened.** After any change made outside the editor, reload the tab — and be aware that a save
  from the stale tab **overwrites** the outside change.
- **Two table features that get declared "impossible" and are not.** A **threshold** is measure
  + ranges + *filter*: the filter block of the dialog is pre-filled with the coordinates of the
  clicked cell, and each line is a multi-select over the members of that axis — so a traffic
  light can be limited to individual column members (e.g. only the two deviation columns). And
  **number scaling exists** — Format panel, all the way down under *Number format*: scaling
  (thousand / million / auto), scaling format, decimals; its scope is a *region* (data area,
  header area, table), not a row, so a per-row scaling à la BEx cell scaling has no counterpart.
  Zero/NULL suppression sits in the "…" menu of the Rows/Columns section header. Rule: scroll
  the panel to the end and read the whole dialog before telling anyone "SAC can't".
- **`#` combinations CAN be blocked in validation rules.** The option "Define unassigned
  members manually" (Validation Rules) makes any combination with the unassigned node invalid
  unless explicitly defined. It was removed from one knowledge base twice because a search did
  not find it — a "not found" from a search endpoint against a single-page-app help site is not a
  refutation. The `NOT_ASSIGNED` leaf pattern above is for *hierarchy* nodes, not for this.
- **The data-action scripting agent** (natural-language intent as a comment → generated script)
  is released, but in many tenants simply **not activated**, because activation hangs on the
  tenant's AI terms — check that before any "it doesn't work" diagnosis. It generates a
  proposal without seeing the result data; there is no test-against-the-cube loop. Treat its
  output as a draft and verify it against the numbers yourself.

### Advanced formulas — syntax and parameter rules that are not in the reference

**Syntax**

| Rule | Symptom when violated |
|---|---|
| Inequality is **`!=`**, not `<>` | syntax error on that line |
| **One statement per line** — no wrapped expressions | a single line break produces a *cascade* of follow-up errors on every line after it; the real error is the first one, the rest is noise |
| `IF <condition> THEN … ENDIF` as the statement form | — |
| `//` comments are allowed | — |

**Parameter hierarchy level — two rules that constrain each other**

1. A parameter used **raw** in a MEMBERSET (`MEMBERSET [d/Dim] = %P%`) must have hierarchy level
   **`LEAF`** *or* be wrapped in `BASEMEMBER([d/Dim], %P%)`.
   > *Wrong hierarchy level: "%P%". Please set the hierarchy level to "Leaf" or use the parameter
   > in the BASEMEMBER function.*
2. Level `LEAF` **excludes the "All Members" selection**.
   > *You can't set a parameter of "Leaf" hierarchy level to allow the "All Members" selection.*
3. **Flat dimensions** (no hierarchy) must stay on `ANY` — `LEAF` is invalid there and reports
   only indirectly: *"There are some errors with the used parameter. Go to the parameter view to
   fix them."*

| Dimension | Approach | Why |
|---|---|---|
| hierarchical, input may happen on nodes | `BASEMEMBER(…)`, level `ANY`, All Members **yes** | the only combination that gives both: a node selection resolves to its leaves *and* an empty parameter means "everything" |
| hierarchical, always leaf-level | raw, level `LEAF`, All Members **no** | e.g. scenario, date |
| flat | raw, level `ANY` | `LEAF` is invalid there |

**⚠️ The empty parameter — silent data loss.** This is the single most expensive gotcha in this
document:

- `BASEMEMBER([d/Dim], %P%)` with an empty `%P%` = **all base members**. Well-behaved.
- A **raw** `%P%` with an empty value = the dimension's **default member**, which is usually `#`.

A parameter that is not wrapped in `BASEMEMBER` therefore **narrows silently**. In one productive
initialization run this quietly reduced the scope to the unassigned member and dropped a
nine-figure amount, with no error and a successful run status.

**Further behaviour worth knowing before designing a data action**

- **`MEMBERSET` defines the write region, `DATA()` restrictions do not.** Reading across
  versions and scenarios works fine; *widening* the MEMBERSET to two scenarios validates cleanly
  in the editor and then fails at runtime with "validation errors". Reach outward with
  `RESULTLOOKUP`, not by widening the write scope.
- **`MEMBERSET [d/Date] = [d/Version].[p/DATE_FROM] TO [d/Version].[p/DATE_TO]` reads properties
  of the TARGET version.** If they are not maintained there, the date range is empty and the
  action **completes without error and writes nothing** — the most common cause of "it ran, but
  there's nothing there".
- **Nested sequences are separate objects.** A step of type nested sequence points at another
  data action that has to be read separately; cross-model `LINK` logic in particular tends to
  hide one level down.
- **A prefill that reads a hardcoded scenario (e.g. `"#"`) only works if the reference version is
  a load version.** Imports land on the unassigned scenario; planned versions carry their data on
  the planning scenarios. Point the reference at a planning version and the prefill reads
  nothing — and a preceding `DELETE()` will have cleared the target first.

### Calculated accounts vs. a data-action chain

An **inverse formula** lets a calculated account stay writable: the user types into the
calculated member and SAC back-solves a stored one. It is **not a separate field** — it goes into
the same *Formula* column of the dimension editor, after a vertical bar:

```
<forward formula> |INVERSE(<target account> := <expression>)
```

for example `[VALUE]/[PRICE] |INVERSE([PRICE] := [VALUE]/[QTY])`.

**Calculated members are evaluated AFTER aggregation**, which is why an inverse formula
is only correct at cell level: on any aggregate
the denominator sums along with everything else and the result is nonsense — in one case a factor
of over a hundred, because the price aggregated across two further dimensions.

The load-bearing design is to **store all three figures** and let exactly one data action
recompute on entry, triggered from `onAfterDataEntryProcess`. That gives you three things a
calculated member cannot: you know *which* field the user typed (so the ambiguity of the inverse
formula disappears), the scope comes from the changed cells and is therefore minimal and fast,
and nothing is divided at runtime so the aggregation trap is gone. A useful side effect is that
the `*_LOAD` / `*_REF` shadow accounts — which only ever existed because the real accounts were
calculated and the load needed a writable target — become unnecessary.

Consequence to plan for: whatever is no longer produced by a formula must now be **copied**.
Every data action that passes planning data along needs the new accounts in its `MEMBERSET`.

### The private-version limit — it is a planning-area problem

**Symptom.** A data action triggered from a story aborts after one to three seconds:

> *Initiating changes to the public version "X" failed … Private version can't be created because
> number of copied rows exceeds the maximum supported number of … rows.*

**Cause.** Data actions never write directly to a public version. SAC creates a private working
copy, writes there and publishes. How large that copy becomes depends on the **planning area** —
and the planning area must be set **on the table**, not only on the data-action widget. Without
it SAC has nothing to bound the copy with and materializes the entire version.

**Two dead ends that cost a lot of time:**

1. **Narrowing the story filter does not help.** It reduces the scope of the *data action*, not
   of the private copy. A run with the smallest possible filter fails identically — which makes
   it the fastest test of whether the planning area is taking effect at all.
2. **Clearing data out of the version helps only in appearance.** It halves the full copy and
   buys exactly one more run; the next one hits the wall again. A data volume is never the cause.

**The rule:** the limit never hits the copied scope, always the materialization. The lever is the
planning area — not the filter and not the data.

Don't be misled by scenario counts either: a version with sixteen scenarios can run while one
with two fails, if the sixteen are narrow frozen snapshots.

**Diagnostics:** the job monitor lists only "Failed" without detail and a story script sees only
a generic error status. The readable message is in the HTTP response — and the request does not
carry "dataaction" in its path, so filter on the status code or on the presence of error details
in the body, not on the URL.

### The story scripting language is a subset

| Not available | Instead |
|---|---|
| object literals / maps (`var m = {"a": []}; m[k]`) | primitives and typed array utilities only; replace "collection per key" with several passes |
| defining functions inside an event handler | helpers belong in a **script object** — and script objects are **per story**, so a helper in one story does not exist in another |
| `getMembers` on a plain file data source in some story types | go through the widget's data source instead |

**`onAfterDataEntryProcess(cells, effectiveContext)`** is the hook that makes entry-driven
calculation possible: each `cells[i]` carries `newValue`, `oldValue` and `context`, and the
context is read like a selection (`cells[i].context["<DimensionId>"]`). ⚠️ Hierarchical
dimensions return the **full member path** (`[DIM].[HIER].&[KEY]`) — the bare key has to be cut
out of the last bracket pair, or the data action will not find the member. On flat dimensions the
same cut is harmless, so apply it unconditionally.

### Every number you report has a display limit

Three independent limits produced three plausible-looking wrong conclusions in a single day.
Check them in this order before a figure leaves the room:

1. **The analytical query row limit** defaults low in a captured template (`SAC_APIS.md` §4) — a result that
   lands exactly on the limit is truncated, not complete.
2. **The query grid must contain every dimension the measure varies over** (`SAC_APIS.md` §4) — otherwise
   one side of a ratio aggregates and the other doesn't.
3. **The Datasphere Data Viewer shows roughly 30 rows and 20 columns**, and ignores `ORDER BY`.
   `SELECT *` on a wide table shows a fifth of it, and the columns you are looking for may not be
   among them. Read the column count from the model first.

### Reading model data

Protocol details, pagination traps and the server-side aggregation trick have moved into
`SAC_APIS.md` §3 (Data Export Service) and `SAC_APIS.md` §4 (InA) — read those before writing any extraction code.

### Seamless planning (SAC on Datasphere)

> Full treatment — architecture, prerequisites, the restrictions that decide feasibility, sizing
> and the use-it/don't-use-it call — is in **`SEAMLESS_PLANNING.md`**. Two things belong in a
> planning modeller's head from the start: **account models are not supported** (standard /
> measure-based only), and **hierarchies are not exposed to Datasphere** and have to be rebuilt
> there.

- The binding is **inverted** relative to intuition: SAC provisions its planning tables
  *inside the Datasphere space* and exposes them back — all planning compute runs on the
  Datasphere HANA. Sizing, monitoring, and data-residency conversations belong on the DSP
  side, not the SAC side.

---

---

## 12a. Asymmetric Reporting (QRC Q2 2026) — what it is and where it stops

Not an object of its own but **three building blocks** that together yield a table whose
columns each carry their own time granularity and time window — BEx-like, without cell-level
formulas:

1. **Calculation input controls in restricted measures / cross calculations** — an input
   control (date, version, measure) drives the restriction; a *measure* input control as the base
   measure of a restriction switches e.g. local/group currency without script.
2. **Dynamic time filter "Rest of Period"** — next to "To Date" / "Current Period"; the cut-over
   date comes from a *Current Date* input control: actuals up to the date, forecast after it.
3. **Visibility filters per structure member** — Builder → structure dimension (Account,
   Measures or a cross calculation) → *Set Data Visibility per Member* → per member the visible
   hierarchy levels and totals of the inner dimension.

The typical rolling-forecast layout: columns = a measure structure (Actuals, ROY Forecast, FY
Budget, FY AC+FC, Delta) with time as the inner dimension; Actuals/Forecast at month level,
Budget at year + quarter, AC+FC at year, and
`FY AC+FC = [ActualsBOY] + [Forecast ROY] | INVERSE([Forecast ROY] := [FYStory] - [ActualsBOY])`
so the yearly column stays input-enabled.

**Rules and limits (documented):** optimized story / New Table Build Experience only. Visibility
filters are **display filters, not data filters** — aggregation is unchanged. **Not available
with SAP BW live** (visibility filters on hierarchies); HANA live needs HANA 2.0 SPS07 rev
79.09+ or HANA Cloud 2026.2+. Configure either one structure dimension *or* the inner
dimensions of an axis, not both. "Hide irrelevant members" (default on, effective only after a
visibility filter is set) hides inner members that are empty in the structure member's context.
Blending: inner dimensions of the primary model only. No nested dynamic time restrictions —
build separate restrictions.

**Findings from practice (field observations, not documented behaviour):**

- **Data entry works** — into restricted measures directly, into calculated measures only with
  `INVERSE`.
- **Only one Current-Date input control per story**, so two forecast cuts with different
  cut-over dates cannot be compared side by side.
- The year in the month header ("Jan (2026)") cannot be hidden with a native SAC time
  dimension; on a Datasphere live model it can, via the date dimension's text association.
- **Fiscal year:** users report it working correctly only with calendar year — test on fiscal
  models before promising it.
- The date dimension must sit *inside* the structure on the column axis; date above the
  measures disables the feature.
- Version-driven windows: `FIND()` over version attributes (cut-over taken from the version)
  works in forecast layouts and forecast calculations, **not in restricted measures**; no
  script API for the custom current date was found. A "start year lives on the version"
  pattern therefore ends up as calculation input controls on the restricted measures, set by
  script.
- Performance: the pattern forces many restricted/calculated measures where one measure plus
  version and an advanced filter used to do; at high volumes the intermediate calculations
  are expensive. Cell-level row×column formulas as in BEx remain impossible.

**Before committing to it in a project, check:** data source (BW is out), fiscal time, number of
measures × volume, and whether several cut-over states have to be compared.

## 13. Authoring a Data Action End to End

§5 covers the formula language. This section is the surrounding workflow — the part that decides
whether a data action is maintainable, and the order of operations that avoids the expensive
mistakes.

### 13.1 Decide the shape before you create anything

Two decisions are effectively irreversible or expensive to change later:

1. **Data action or multi action?** One target model and one target version, no mid-sequence
   publish → data action. Anything else → multi action (§7.3). Retrofitting a data action into a
   multi action means rebuilding the triggers and the parameter wiring in every story that calls
   it.
2. **Which dimensions become parameters?** A parameter is the only way a planner can influence
   scope at run time — filters in the step definition are modeler-only, and planners cannot add
   filters when they run it. Anything you might want to run "for one region" later has to be a
   parameter now.

Most allocation-step settings are immutable after the step is created (§6.1). Plan the step, then
create it.

### 13.2 Parameter design — the rules that constrain each other

The parameter object carries type, cardinality and hierarchy level, and those three interact
(full decision table in §12):

| Field | Values | Notes |
|---|---|---|
| `type` | `MEMBER` (dimension) / number / date | member parameters bind to a dimension, optionally to a hierarchy |
| `cardinality` | `SINGLE` / `MULTI` | determines the value shape: `{memberId: …}` vs `{memberIds: […]}` — singular vs plural, and they are not interchangeable |
| `hierarchyLevel` | `LEAF` / `ANY` | `LEAF` is required for a raw `%P%` in a MEMBERSET, but excludes "All Members"; flat dimensions must stay on `ANY` |
| `allowAllMember` | true / false | mutually exclusive with `LEAF` |
| `isTargetVersionParameter` | true on exactly one | the write target; **never** put the version in a MEMBERSET |
| `inputType` | `PROMPT` / fixed | prompt = the planner is asked at run time |

**The design rule that follows from all of it:** for a hierarchical dimension where input may
happen on nodes, use `BASEMEMBER([d/Dim], %P%)` with level `ANY` and All-Members enabled. That is
the only combination where a node selection resolves to its leaves *and* an empty parameter means
"everything" rather than the unassigned member (§12 — this is the silent-data-loss case).

### 13.3 Writing the steps

- Keep **one statement per line**; a wrapped expression produces a cascade of follow-up errors
  where only the first one is real.
- Put `CONFIG` first, then declarations, then MEMBERSETs, then instructions (§5.1).
- Set `CONFIG.GENERATE_UNBOOKED_DATA` explicitly rather than relying on the default — the reader
  of your script six months from now needs to know it was a decision (§5.3).
- Scope every dimension you can in the MEMBERSET. An unconstrained dimension means "all leaves",
  and the base scope is the full cartesian product (§5.0). Check the **Estimated Function Scope**
  by hovering `DATA` / `RESULTLOOKUP` after validation.
- Prefer `DELETE()` + write over relying on unbooked semantics when you mean "replace" — the
  stale-target trap in §9 is the most common correctness bug in copy logic.
- If the step needs the previous iteration's result, use `FOREACH`; otherwise don't (§8.2).

**A worked prefill, the shape most planning implementations need** — target date range driven by
version properties, actual/forecast split by a parameter:

```
CONFIG.TIME_HIERARCHY = CALENDARYEAR
CONFIG.GENERATE_UNBOOKED_DATA = OFF

MEMBERSET [d/Measures]   = "<Measure>"
MEMBERSET [d/Date]       = [d/Version].[p/Start_date] TO [d/Version].[p/End_date]
MEMBERSET [d/CostCenter] = %CostCenter%
MEMBERSET [d/Product]    = BASEMEMBER([d/Product], %Product%)

// actuals up to and including the last actual month
IF DATEDIFF([d/Date], %lastActualMonth%, "MONTH") >= 0 THEN
    DATA() = RESULTLOOKUP([d/Version] = "public.Actual")
ENDIF

// forecast beyond it
IF DATEDIFF([d/Date], %lastActualMonth%, "MONTH") < 0 THEN
    DATA() = RESULTLOOKUP([d/Version] = "public.FC")
ENDIF
```

Three things to copy from this pattern: the **date range comes from properties of the target
version**, not from the script — so a new planning version needs master data, not a code change;
`BASEMEMBER` turns a node selection into leaves; and the actual/forecast boundary is a
**parameter**, not a literal.

> ⚠️ The counter-pattern, seen in production more than once: the last actual month hardcoded in a
> story script per version (`if version === "public.Forecast1" then months = [...]`). It drifts from the
> version master data, and then locking and prefill disagree about which months are actuals — with
> no error anywhere. Read the property; never hardcode the calendar.

### 13.4 Creating and filling the object programmatically

Data actions can be created and filled through the internal REST layer (`SAC_APIS.md` §6 — read its
governance caveat first; this is build automation, not an interface). The object type is
`PLANNINGSEQUENCE`, a multi action is `MULTIACTIONS`.

```js
// read: → j.metadata.version (needed for the write), j.data.sequence
{action:'readObject', data:{p1:{type:'PLANNINGSEQUENCE', name:<objectId>, package:<pkg>},
                            p2:false, p3:{bIncludeAdditionalData:true}}}
// write
{action:'updateObject', data:{p1:{type:'PLANNINGSEQUENCE', name:<objectId>, package:<pkg>},
                              p2:<objectVersion>, p3:<sequence>}}
```

`sequence` carries `parameters[]` and `planningSteps[]`:

```json
{"id":"<uuid>","name":"<step name>","description":"","stepType":"SCRIPT",
 "panelType":"TEXTUAL","scriptContent":"<advanced formula source>"}

{"displayKey":"Product","displayName":"Product","inputType":"PROMPT",
 "cubeId":"<modelId>","dimensionId":"<DIM>","hierarchyName":null,
 "hierarchyLevel":"ANY","allowAllMember":true,"type":"MEMBER","cardinality":"MULTI",
 "value":{"memberIds":[],"hierarchyName":null},"isTargetVersionParameter":false}
```

Four practical notes:

- **`name` is the object ID, not the readable name.** The readable name lives in the metadata.
- **The package differs by object age and tenant.** Objects created through today's UI land in the
  tenant namespace; older ones may sit elsewhere. The wrong package returns "not found or you do
  not have permissions" — an authorization-looking message for a path problem (`SAC_APIS.md` §6).
- **There is no reliable listing endpoint** for these objects. The pragmatic way to get an ID is
  to open the object once in the UI and read it from the URL fragment
  (`…#/dataaction&/da/PLANNINGSEQUENCE:<package>:<objectId>`).
- **Nested steps are separate objects.** A step of type nested sequence carries only a reference;
  read the referenced `PLANNINGSEQUENCE` separately or you will miss an entire piece of logic —
  cross-model `LINK` steps in particular like to hide there.

### 13.5 Validating and debugging

**API writes bypass validation.** `updateObject` does not check the formula; only the editor does.
So the loop is: write → **reload the tab** → let the editor validate → read the messages. A stale
editor tab is worse than useless: saving from it **overwrites** your API change.

Editor messages are visible list entries that **begin with the line number**, which makes them
worth harvesting rather than transcribing:

```js
for (const el of document.querySelectorAll('[class*="rror"],[class*="essage"],li,tr')) {
  if (!el.offsetParent) continue;
  const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
  if (/^\d+\s/.test(t)) console.log(t);   // "10 <DIM>: Wrong hierarchy level: ..."
}
```

Filter out your own `//` comment lines first, or you will find your own text.

**When a run reports failure without a readable reason** — the job monitor shows only "Failed" and
a story script sees only a generic error status — the real message is in the HTTP response body.
Note that the request does not carry "dataaction" in its path, so filter on the status code or on
the presence of error details, not on the URL (§12, private-version limit).

### 13.6 A test protocol that catches the silent failures

Data actions fail quietly more often than they fail loudly. Before declaring one finished:

1. **Run it on a slice you can count by hand** and compare against the source, at the same grain.
2. **Check that it wrote at all.** "Completed successfully" is compatible with zero writes —
   empty date range from missing version properties, a parameter that collapsed to `#`, a MEMBERSET
   that excluded everything (§12).
3. **Run it twice.** Additive logic (`DATA.APPEND`, allocations without Overwrite Target) doubles
   on the second run. If re-running is not idempotent, say so in the description.
4. **Run it from the story trigger, not only from the editor** — the story's filter bar scopes it
   (§12), and the planning-area/private-version limit only shows up on the story path.
5. **Check the target version, not just the target model** — a mis-set target version writes
   plausible numbers into the wrong place, and nothing flags it.

---

## 14. Sources

Primary (SAP Help, verified current at Q2 2026 / 2026.8):
- Get Started with Data Actions for Planning — help.sap.com `2850221adef14958a4554ad2860ff412`
- Add Steps to Your Data Actions — `a27d8405ac9b4e7bb8e50e8e70ba18a2`
- Adding a Copy Step — `b5720be6f2ed41178762973df9e4af16`; Cross-Model Copy — `694a8e81205245a19d78d8b1acdffbba`
- Adding an Embedded Data Action Step — `121b544d5e2440a4b2ef3bd09d6a7fa8`
- Adding an Allocation Step (Legacy) — `87a9cca86cb546bf99b6b43131934d50`; Learn About Allocations — `2eb9dbe056684f15bd850fab9e16dfe5`; Set Up Your First Allocation Process — `72233dce8086416189a936ceee1194ac`; Creating an Allocation Step — `3be4906c44404109ad285fa320d121f8`; allocation step options (Keep Source / Overwrite Target / Direct Assignment / Driver Context) — `674398eba6414902961dc24074776b27`
- Understand General Rules for Advanced Formula Calculations — `766b9da1890d431ca29927daee4811b4` (read-after-write, three-level scoping, base scope, FOX contrast)
- Advanced Formulas Reference Guide (PDF) — help.sap.com/doc/`5516580733124039b673c530125771b3`
- Measures in SAC Models / Restrictions — `22af95d0151c4946b132d4e904b1e32a`; Migrate From a Classic Account Model to a New Model Type — `70913db112d44591a28514544871692f`
- About Script Formulas and Calculations in Advanced Formulas — `afe93e3cf1414a7b8419baad11cc066e`
- Optimize Advanced Formulas for Better Performance — `fa558b0ff273475c8f3cfa0053a5d89e`
- Automate a Planning and Predictive Workflow Using Multi Actions — `b1a98c566bc64ce78871ee3c0b559d6f`
- Learn About Planning Model Data — `bc9f0eb2da1848dd9d3925ec29337e9f`
- Configure Data Visibility in Tables (New Table Build Experience) — `b2d6dd66647c4555b939e0934b6400e6`
  (2026.15); SAP Community blog "Asymmetric reporting layout" (May 2026) incl. its comment thread
- Validation rules — "Define unassigned members manually" — `e275adffd7f14151a97721d83f4a865c` (Q3 2026)
- SAP KBA 3658925 (AF performance), KBA 3707921 (account models not deprecated),
  KBA 2936022 (Keep Source ignored when # is in targets), KBA 2840982 (#-as-source not
  recognized, 2019.15)

Secondary:
- SAP blog: "See How SAP Analytics Cloud Multi Actions Change the Way That You Do Planning" (2021, transaction semantics — corroborated against current help)
- SAP blog: Hartmut Koerner, "Advanced Formulas — how they work" (2021, fact- vs
  master-data-driven execution, IF-condition transformation, FOX contrast — canonical but
  note: these internals are NOT in the official function reference, so SAP could change them
  without contradicting its docs)
- SAP Community: "A Deep Dive into Classic Account Model and New Model"; "Optimizing SAP Analytics Cloud: Best Practices and Performance"; "How to consume Calculated Member in Advanced Formulas"

Refuted during verification — commonly repeated claims that did NOT hold up:
- "Source values that can't be allocated stay on `#`, and a source with no driver values
  allocates back to itself."
- "`#` can be selected as the source member in an allocation rule's source part."

Open questions (still unresolved after two rounds):
- Within a SINGLE DATA statement, self-reference semantics and how AGGREGATE_DIMENSIONS
  interacts when multiple source tuples map to one target cell.
- How Reference Dimensions (Driver Context) interact with multi-repetition advanced
  allocation steps and the once-per-step Overwrite Target zeroing.
- Feature-parity matrix / migration roadmap detail beyond §10 (no roadmap claim survived
  verification; §10 is a direct single-source read).
