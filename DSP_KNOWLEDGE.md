# SAP Datasphere Knowledge — Architecture, Modeling & Field-Tested Practices

> Field reference for SAP Datasphere (DSP) development, compiled from SAP official
> documentation and productive project experience across several implementations.
> Every non-obvious behaviour documented here has been verified against a live tenant.
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

**Modeling** — §1 architecture · §2 artifact types · §3 view design patterns ·
§4 HANA SQL quirks in DSP · §5 persistence & the Data Viewer · §6 space design ·
§7 data integration · §8 performance · §9 security · §10 deployment · §11 mistakes checklist ·
§12 associations, texts, semantic types & hierarchies

**Programmatic access** — see the companion file **`DSP_PROGRAMMATIC_ACCESS.md`** —
OAuth, CLI, consumption APIs, Open SQL Schema, writing data, design-time & monitoring APIs,
transport & content packages, Datasphere ↔ SAC, browser-driven automation

---

## 1. Architecture: the 4-Layer Model

```
┌─────────────────────────────────────────────────────┐
│ Layer 4: Consumption                                │
│   SAC stories, OData clients, BI tools              │
├─────────────────────────────────────────────────────┤
│ Layer 3: Semantic / Business Layer                  │
│   Analytic Models, KPIs                             │
├─────────────────────────────────────────────────────┤
│ Layer 2: Integration / Harmonization                │
│   Views (Fact + Dimension), Data Flows              │
├─────────────────────────────────────────────────────┤
│ Layer 1: Staging / Raw                              │
│   Replicated tables, Local Tables (no transforms)   │
└─────────────────────────────────────────────────────┘
```

SAP's guiding principle: **modular modeling** — master data modeled once, reused via
associations.

### Naming convention (layer-prefix pattern, proven in practice)

| Prefix | Meaning | Example |
|--------|---------|---------|
| `01_LT_` | Local Table (replicated) | `01_LT_KNVH` |
| `01_RT_` | Remote Table (live federation) | `01_RT_KONP` |
| `01_RF_` | Replication Flow | |
| `02_RV_` | Relational Dataset (SQL view, staging/integration) | `02_RV_CONDITIONS` |
| `02_MD_` | Master Data / Dimension view | `02_MD_D_CUSTOMER` |
| `02_HV_` | Helper / persisted view | `02_HV_PLAN_HIERARCHY` |
| `03_FV_` | Fact view (output layer) | `03_FV_PLAN_PRICES` |
| `03_MD_` | Master data view (output layer) | `03_MD_MATERIAL` |

Numbered folders per layer (`01_Inbound`, `02_Transformation`, `03_Outbound`, `99_Testing`)
keep the Data Builder navigable at scale.

---

## 2. Artifact Types & When to Use Them

### Integration / replication

| Artifact | Use when |
|----------|----------|
| **Replication Flow** | Initial + delta load from SAP ECC/S4. Auto-generates the Local Table. |
| **Data Flow** | ETL/ELT: complex transformations, file → table, filter+union patterns |
| **Local Table** | Target of replication/data flows; source of truth for raw data in DSP |
| **Remote Table** | Live federation without replication. Slow — use sparingly. |

### Views

| Artifact | Semantic usage | Use when |
|----------|----------------|----------|
| **Relational Dataset** | None | Intermediate joins/staging — no analytical consumption |
| **Fact View** | Fact | Transactional data — measurable KPIs |
| **Dimension View** | Dimension | Master data with a key |
| **Text View** | Text | Labels/descriptions for dimension keys |
| **Hierarchy View** | Hierarchy | Parent-child data for drill-down |
| **SQL View** | any | Custom SQL logic — most flexible |
| **Graphical View** | any | Visual join builder — good for simple joins, harder to debug at scale |

### Semantic layer

- **Analytic Model** — the current best practice for consumption.
- **Business Builder / Business Entities** — not the strategic path. SAP's direction for
  consumption is the Analytic Model, and new development should go there. (SAP Help still
  documents the Business Builder as a supported feature, so treat this as guidance on direction,
  not as an announced end of life — check the lifecycle status for your release before making it
  an argument in a decision paper.)
- Graphical views expose **business names**, not technical column names — in SQL on top of
  them, quote the business name exactly.

---

## 3. View Design Patterns

### Star schema (recommended)

```
Central Fact View
    ├── Dimension: Customer
    ├── Dimension: Material
    ├── Dimension: Time (date spine / calendar)
    └── Dimension: Org Unit
```

### Master data pattern

1. Replicate source tables (`01_LT_` / `01_RT_`)
2. Harmonize columns in a Relational Dataset
3. Build a Dimension View on top (semantic usage = Dimension)
4. Share the dimension to all consuming spaces — share **finished products**, not building
   blocks

### "Best record per key" (validity periods, access sequences)

```sql
SELECT * FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY <business key>
            ORDER BY <priority> ASC, DATAB DESC   -- DATAB DESC is critical!
        ) AS RN
    FROM source_view
) WHERE RN = 1
```

**Critical:** when multiple validity periods exist per key, `DATAB DESC` (valid-from,
descending) must be the tiebreaker — otherwise stale records win non-deterministically.

### Date handling (SAP sources store dates as VARCHAR `YYYYMMDD`)

```sql
WHERE DATAB <= '20260101' AND DATBI >= '20260101'   -- string comparison is correct here
-- '99991231' = open-ended validity
WHERE DATAB >= '20220101'                            -- cut off ancient records
```

---

## 4. HANA SQL Quirks in DSP (non-obvious, all field-verified)

1. **`WITH` / CTE is NOT supported.** Symptom: `Mismatched input '<' expecting 'select'` plus
   a misleading "Your model seems to be empty". Convert every CTE into an inline subquery.
2. **`LIMIT` inside `UNION ALL` legs needs parentheses** around each leg.
3. **Every `UNION ALL` leg needs column aliases** — not just the first.
4. **`SELECT *` fails on cross-space references** — always list columns explicitly.
5. **Avoid `-->` inside block comments** — the parser can misread it even within `/* */`;
   use `--` or `=>`. Symptom is the same as the CTE error.
6. **Cross-space access requires sharing, and the reference is ONE quoted identifier** —
   write `"OTHER_SPACE.OBJECT"`, not the two-part `"OTHER_SPACE"."OBJECT"`. A 404 on a
   correctly spelled reference means "not shared in Space Management", not a SQL error — so
   check the spelling first, then the share.
7. **Technical names are immutable after the first save/deploy** — plan naming upfront.
8. **No `DUMMY` table.** DSP validates every identifier against the space repository, so the
   classic HANA `SELECT 1 FROM DUMMY` fails with `Entities DUMMY cannot be found in the
   repository`. Need a one-row source for literals? Use an existing table with
   `WHERE <key> = '<known value>'`.
9. **No `VALUES` row constructor** and **no `UNPIVOT`.** Wide-to-tall conversions are written
   as *n* `UNION ALL` legs, one per source column.
10. **No `TOP n`** — `LIMIT n`. **`STRING_AGG(DISTINCT …)`** is a syntax error.
11. **`CAST(0 AS DECIMAL(31,3))` is rejected** — `Artifact "DECIMAL" has not been found`. DSP
    resolves type names as repository artifacts in this position. Write the decimal literal
    instead (`0.000`); the `UNION` result type stays `DECIMAL`.
12. **Leading zeros in SAP key fields die silently.** Manual entry and CSV/spreadsheet round-trips
    turn `000000000000014993` into `14993` — and then *no join matches*. An `INNER JOIN` to the
    master data drops the row without a trace (downstream in SAC it surfaces as a
    "member does not exist" reject). Defend in the load view:
    `LPAD(TRIM("MATNR"), 18, '0')`, regardless of how clean the source looks.
13. **`SELECT *` on a wide table hides columns** — see the Data Viewer limits in §5; read the
    real column list from the model (CSN) rather than from the preview grid.
14. **Programmatic edits to the SQL editor may not arm the Save button.** Any automation that
    sets the editor's value through its JavaScript API bypasses the UI framework's change
    tracking: the code is visibly there, `Save` stays greyed out, and nothing is persisted.
    Type through the keyboard, or go straight to `Deploy` (recent versions save+deploy in one
    step).

---

## 5. Persistence Strategy

### When to persist

- Expensive CROSS JOINs (e.g. customers × materials × months)
- Views used as sources by many downstream views
- Any view whose preview takes >30 s
- Foundation views for SAC consumption

### How

View properties → enable **Data Persistence** → schedule or run manually. Downstream
virtual views on top of a persisted view are fast.

### Anti-patterns

- Persisting staging/intermediate views wholesale (wastes quota)
- Persisting views directly on remote tables (use Replication Flow + Local Table instead)
- Ignoring quota — monitor space storage; a single wide persisted cross-join view can be
  multiple GiB

### The preview trap

- **The Data Viewer runs the real query.** Previewing a view that scans a large fact
  (tens of millions of rows) inline — especially with cross-space joins — can hang the
  whole browser tab with no recoverable spinner.
- **Deploy does NOT run the query** — it only registers the definition. A view whose
  preview would hang deploys fine: skip the preview, deploy, then validate with small
  bounded queries (`WHERE <key> = …`).
- Persist intermediates first; persistence runs server-side and never blocks the UI.

### The Data Viewer is a preview window, not a query result

Three independent behaviours, none of which announces itself. **These are observations from live
tenants, not documented product limits** — the exact row and column counts depend on the release
and on how the grid is being read (an interactive user can scroll; a virtualised grid returns far
less to anything reading it programmatically). Re-verify the numbers on your release; the
*advice* holds regardless:

| Behaviour | Effect |
|---|---|
| only a small leading slice of rows is materialised (order of a few dozen) | you see the beginning of the result set, never the whole thing |
| only a limited set of columns is shown | `SELECT *` on an 87-column table surfaces a fraction — the ones you need may not be among them |
| **`ORDER BY` does not govern what you see** | the row order in the window has nothing to do with your query |

The third is the dangerous one because it looks like a data error: a query that deliberately
sorts the interesting rows to the top still shows an arbitrary slice, and the honest reading of
that screen ("the query returns nothing") is wrong. **Steer the Data Viewer with `WHERE`,
never with `ORDER BY`**, and always hold the reported total row count against the number of
rows displayed. Repeated runs of the same query occasionally return a null count and no rows —
a busy state of the preview pane, not a SQL error. Measure twice before drawing a conclusion.

### Persistence lifecycle — what invalidates what

- **Deploying the view itself throws its persisted data away.** The task log shows
  `REMOVE_PERSISTED_DATA` immediately, and the Data Viewer silently switches back to the live
  view — numbers move without any logic change.
- **Deploying an *upstream* view does NOT invalidate it** (verified by measurement). But the
  snapshot is then stale: after any upstream data change you must re-persist, or the view keeps
  serving the old state.
- **The first `PERSIST` right after a deploy tends to fail** — reproducibly, after 5–7 seconds,
  with no detail message and no locks held. The immediate retry succeeds. The likely cause is a
  background cleanup of the previous persisted table. ⚠️ Watch the follow-up activity: a failed
  run can be followed by `CANCEL_PERSISTENCY`, which **unschedules persistence altogether**. The
  view keeps working — virtually — and you only notice when queries take minutes instead of
  seconds.
- **Check the persistence timestamp before every downstream extraction.** An extract run against
  stale persisted data is indistinguishable from a load failure: zero rejects, correct keys,
  green job, just too little data. The diagnostic signature is a *uniform factor* across all
  nodes of a distribution with unchanged proportions — the split is intact, the base is old.

---

## 6. Space Design

### Patterns

- **A — single space:** all objects in one space. Small datasets, one team, quick start.
- **B — source/semantic split (recommended default):** `DATA_SPACE` (replication +
  integration views) → share into `ANALYTICS_SPACE` (semantic layer, SAC consumption).
- **C — multi-tier (enterprise):** STAGING → INTEGRATION → SEMANTIC → CONSUMPTION spaces.

### Governance rules

- Technical names (spaces AND objects) are permanent — decide the convention first.
- Share only finished products between spaces; shared objects are **read-only** in the
  receiving space and the owner can revoke.
- Filter at the source before sharing (org-level filters etc. don't belong in every consumer).
- Cross-space joins are also a **performance** decision (see §8) — prefer building views in
  the space that owns the data and sharing the result.
- **DSP packages are single-space** — a "use case package" spanning spaces is not possible;
  model cross-space dependencies as required packages per space.

---

## 7. Data Integration

### Replication from ECC / S/4

```
Source tables → Replication Flow → Local Table (01_LT_)
```

- Initial load + delta (CDC). Map column types deliberately — SAP `DATS` arrives as VARCHAR
  unless mapped.
- Remote tables (`01_RT_`) are live federation — noticeably slow in analytical queries; use
  local replicas for anything heavy.

### ECC vs S/4HANA source differences

| Topic | ECC | S/4HANA |
|-------|-----|---------|
| FI documents | BKPF + BSEG | ACDOCA (universal journal) |
| Goods movements | MKPF + MSEG | MATDOC |
| CO documents | COBK + COEP | ACDOCA |

### BOM explosion pattern (standard SAP tables)

```sql
SELECT m.MATNR AS PARENT, p.IDNRK AS COMPONENT, p.MENGE, p.MEINS
FROM MAST m
JOIN STKO k ON k.STLNR = m.STLNR AND k.LOEKZ = ''
JOIN STPO p ON p.STLNR = k.STLNR AND p.LOEKZ = ''
WHERE m.LOEKZ = ''
-- filter STLAN (BOM usage) to the relevant usage, e.g. '5' = sales BOM
```

### Flat-to-parent-child hierarchy conversion

Flat level-column hierarchies (child + level-1-parent + level-2-parent + …) convert to
parent-child pairs by UNION ALL across the level columns — one SELECT per level, each
emitting `(child, parent, level)`.

---

## 8. Performance

- HANA's columnar store needs no manual indexes for most workloads; the levers are
  **persistence, scoping, and join locality**.
- Partition big cross joins by a time column where possible; persist the result.
- Avoid: `SELECT *` across spaces · CROSS JOIN without a downstream limiting filter ·
  remote-table access inside heavy analytical queries · multi-level virtual aggregation
  stacks (persist at least one intermediate level).
- DSP has no BW-style packet extraction — an out-of-memory on a huge join is a **design**
  problem (missing persistence/partitioning), not a sizing problem.
- 1 TB+ sources: filter by date range in the Replication Flow itself, not downstream.
- Monitor in the **Data Integration Monitor**.

---

## 9. Security & Authorization

- **Space-level access:** users see only granted spaces; roles per space (Space
  Administrator, Data Engineer, Data Modeler, Data Viewer).
- **Row-level security:** Data Access Controls (DAC) — user-specific row filters defined on
  permission entities, assigned to views/analytic models.
- **Cross-space sharing:** read-only for the receiver, revocable by the owner.
- **Design DAC together with the associations, not after them.** A dimension's DAC can be
  propagated onto a fact through the association (*Apply Dimension Data Access Controls to
  Fact*, §12.3) — which is the clean way to get one row-security definition instead of one per
  consumer. Retrofitting row security onto a model whose facts already carry joined-in
  attributes is markedly harder, so the decision belongs in the modelling phase.
- Row security is only as good as its weakest consumer: a view exposed for consumption without
  a DAC, or an Open SQL Schema database user (`DSP_PROGRAMMATIC_ACCESS.md` §1.4), bypasses it.
  Inventory who can read what through *all* the access planes, not just through the AM.

---

## 10. Deployment Workflow

### New object
1. Create the view in Data Builder, validate (0 errors)
2. Set column semantics (key / measure / dimension)
3. **Deploy** (recent DSP versions save+deploy in one step)
4. Validate with bounded queries — not with an unbounded preview (§5)

### Change to an existing view
1. Edit → Deploy → **verify the deployed timestamp** in the view properties. The deployed
   date is the reliable signal that the change is live; the editor state is not.

### Saved is not deployed
A view can exist, be valid and be visible in the Repository Explorer while never having been
deployed. Anything built on top of it then fails with `The object "<X>" has never been
deployed` — a message that sends people looking for a sharing or spelling problem. This is the
normal outcome of scripted creation paths that save without deploying (the CLI's `--no-deploy`,
or a save step that was never followed by a deploy). Check `#objectStatus` in bulk
(`DSP_PROGRAMMATIC_ACCESS.md` §2.1): `1` = deployed, `2` = redeploy needed, `0` = never
deployed.

### Testing patterns

```sql
-- Unit test: one known key
SELECT * FROM "03_FV_..." WHERE <key> = '...' AND YYYYMM = '202601'

-- Reconciliation: compare totals of two implementations for the same slice
SELECT YYYYMM, SUM(measure) FROM view_a GROUP BY YYYYMM
-- vs. the same aggregate from view_b / the source system

-- Completeness: keys missing on the other side
SELECT DISTINCT f.key FROM fact f
LEFT JOIN dim d ON f.key = d.key
WHERE d.key IS NULL
```

---

## 11. Common Mistakes Checklist

| Mistake | Consequence | Fix |
|---------|-------------|-----|
| No `DATAB DESC` in ROW_NUMBER ordering | stale validity periods win | always add it as final tiebreaker |
| INNER JOIN to a hierarchy/mapping table | unmapped keys silently vanish | LEFT JOIN + COALESCE fallback bucket |
| Missing date/zero filters on condition data | decade-old zero records contaminate averages | `DATAB >= <cutoff>` and `value > 0` |
| Renaming after first deploy | impossible — technical name is locked | plan names upfront |
| Business Builder for new builds | not the strategic path | Analytic Models (§2) |
| Remote tables in heavy queries | timeouts | replicate to Local Tables |
| Fan-out dimensions in joins (e.g. per-channel condition records) | duplicated rows per key | filter or aggregate the fan-out dimension explicitly |
| NULL-key partitions in ROW_NUMBER | NULL groups form their own partition and "win" alongside real keys | handle NULL keys explicitly downstream |
| CTE / `WITH` | parser error | inline subqueries (§4) |
| Unbounded preview on a big fact | frozen session | deploy without preview, validate bounded (§5) |
| Reading a result off the Data Viewer | it shows ~30 rows / ~20 columns and ignores `ORDER BY` | steer with `WHERE`, compare against the reported total (§5) |
| Association target not shared into the consuming space | texts/hierarchies silently don't resolve in the AM | share the whole chain; verify via `inaccessibleDependencies` (§12.0; `DSP_PROGRAMMATIC_ACCESS.md` §2.1) |
| OAuth client created with purpose *API Access* for data/modeling | 403 on everything — the token carries no DW roles | use purpose *Technical User* (headless, scoped roles) or *Interactive Usage* (acts as the human) — `DSP_PROGRAMMATIC_ACCESS.md` §1.1 |
| Trusting HTTP 200 from an API call | many failures answer 200 with an HTML login page or an ignored payload | test the response body, verify with a counted read (`DSP_PROGRAMMATIC_ACCESS.md` §1–2) |
| Lost leading zeros in SAP key fields | joins match nothing; rows disappear through INNER JOINs | `LPAD(TRIM(col), 18, '0')` defensively in the load view (§4.12) |
| Re-persisting right after a deploy | first PERSIST fails, and a follow-up can cancel persistence entirely | wait, retry once, then check the activity list (§5) |

---

## 12. Semantic Layer — Associations, Texts, Semantic Types & Hierarchies

### 12.0 The cross-space rule (read this first on any multi-space tenant)

**Every entity an association points to must be shared into the space where the consuming
Analytic Model lives.** Associations resolve at *consumption* time, so when an AM in space A
follows a fact's associations to a dimension / text / hierarchy / hierarchy-directory entity
that physically lives in space B, **all of those targets must be shared (Read) into space A** —
the whole chain, not just the first hop.

Symptoms when it's missed: keys displayed instead of descriptions, hierarchies not selectable
in the AM, `entity cannot be found in the repository`, blank texts in the SAC story. Only
deployed objects can be shared; shared objects are read-only for the receiver.

### 12.1 Semantic usage (entity level)

| Semantic usage | Purpose | Notes |
|---|---|---|
| **Relational Dataset** | generic staging / intermediate view | the default for plumbing layers; no analytical semantics |
| **Dimension** | master data: attributes + (compound) key | the thing facts associate to; carries associations to Text and Hierarchy |
| **Text** | language-dependent descriptions for a key | associated *from* a dimension (or, sparingly, from a fact) |
| **Fact** | transactional / measure data | its associations are consumed **only** by the Analytic Model |
| **Hierarchy** | external parent-child hierarchy for one dimension | associated to its dimension |
| **Hierarchy with Directory** | one or more parent-child hierarchies plus a directory of them; nodes may span several dimensions | the BW-style hierarchy — how S/4 and BW hierarchies import |
| ~~Analytical Dataset~~ | **deprecated** | replaced by Fact + Analytic Model |

Field-level **semantic types** are only offered on entities whose usage is Fact, Dimension or
Text. A fact's associations do nothing in plain view consumption — they exist to feed the
Analytic Model.

### 12.2 Semantic types (column level)

Measures: **Amount with Currency** (needs a Currency Code attribute as its unit column) and
**Quantity with Unit** (needs a Unit of Measure attribute). Attributes: Currency Code, Unit of
Measure, Language (ISO-639-1), Text, Image URL, Geolocation, Business/Calendar/System Date.

Mark the columns that identify a record as **key columns** — associations need keys on the
target. Several key columns = a compound key, which brings the representative-key rule below.

### 12.3 Associations vs joins

> A **join** combines data immediately — a one-time operation. An **association** merely
> prepares the conditions for a join that happens later. A join is one-time; an association can
> be used for any number of joins in different contexts.

- Created in the view editor's *Associations* panel or by drawing a line in the E/R model editor.
- From a fact **or** a dimension: map a source attribute to **every** key column of the target.
- Optional *Apply Dimension Data Access Controls to Fact* propagates the dimension's row-level
  DAC to the fact — the clean way to inherit row security.
- **Text association, compound-key rule (verbatim from SAP):** *"When you have defined a
  compound key for a dimension, you must map all key columns to the text entity. You can only
  provide translations for the representative key column. Other key columns cannot be
  translated."*
- **Hard limit in the Analytic Model: only one association per attribute** can be used, even
  when several originate from the same attribute — pick the right one in the attribute's
  Text/Association property.
- Associations deliver **current truth** of master data. For **historic truth** (the attribute
  as it was at posting time) you must **join** the attributes into the fact instead — the
  classic slowly-changing-dimension decision, and it has to be made per attribute, early.

### 12.4 Text entities

Structure (BW/S4-style): key column(s) ✔, `LANGUAGE` ✔ (**ISO-639-1** — S/4 and BW one-character
codes `E`/`D`/`F` are converted implicitly), description column with semantic type Text.

1. Build the text view, usage **Text**, mark key + language, set the semantic types.
2. Add a **Text Association** from the dimension.
3. With a compound key, map all key columns but designate **one representative key** — only that
   one is translatable.
4. Texts-only master data may be associated straight to the fact, but DSP warns against more
   than one text entity per entity; adding a text column on the dimension attribute is cleaner.

### 12.5 Hierarchies — four kinds

| Type | Shape | Defined by |
|---|---|---|
| **Parent-child** | recursive, any depth | a parent column + child column *inside* the dimension |
| **Level-based** | fixed levels | 2+ level columns inside the dimension |
| **External hierarchy** | parent-child in a separate entity | a Hierarchy entity associated to the dimension |
| **Hierarchy with directory** | several parent-child hierarchies + a directory listing them; nodes may span multiple dimensions | own entities, associated; this is what BW/S4 hierarchies import as |

**Hierarchy with directory — what it needs:** a fact, a data-node dimension, text entities per
dimension, optional further node-type dimensions, a **hierarchy directory entity** (usage
Dimension: hierarchy id as key + hierarchy name), and the **hierarchy entity** itself (usage
*Hierarchy with Directory*, keys = child node id + hierarchy id). On the hierarchy entity, set
Parent, Child, the directory association, the node-type column and one entry per node type
(value, whether it is the data node, its id column(s)). Consume it in the AM by enabling the
data-node column as a row and picking the hierarchy under *More → Hierarchy*.

> Note for the consumption side: consuming these **Datasphere-side external hierarchies and
> hierarchies-with-directory** in SAC requires the **Optimized Design Experience**; the Classic
> experience does not support them. (Classic stories handle hierarchies in general perfectly
> well — the restriction is about this hierarchy type, not about drill-down as such.)

A frequent alternative to importing a BW hierarchy directory is to **build the hierarchy in SQL**
off the S/4 set tables (`SETHEADER` / `SETNODE` / `SETLEAF`) and expose the result as a
Hierarchy-with-Directory view. That is often more transparent than the import, and it is the
only option when the hierarchy is maintained as a set rather than as a BW hierarchy.

---
