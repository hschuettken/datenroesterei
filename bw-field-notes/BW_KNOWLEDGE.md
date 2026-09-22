# SAP BW — Technical Field Notes

> Field notes from productive SAP BW / BW/4HANA work (7.4/7.5 on HANA, aDSO-based data flows,
> financial consolidation and controlling content). Everything here was **measured**, not read —
> usually the expensive way, because it went wrong first.
> No customer-specific information. Object names are placeholders.

**Contents** — §1 tables you must know · §2 field names and `/BIC/` · §3 routines ·
§4 semantic grouping · §5 activation: overwrite vs. summation · §6 DTP · §6a activation
errors: queue first · §7 activation dumps · §8 HANA SQL in a BW context · §9 measurement
rules · §10 modelling · §11 the `*$*$` markers · §12 generated table names · §13 reach of a
dependency scan · §14 the clipboard triples · §15 where the truth about a load sits · §16 empty
key fields · §17 control groups · §18 open-ended contracts · §19 correcting without selective
deletion · §20 stock figures in period cumulation · §21 two organisational views on one record ·
§22 self-loop transformations · §23 manifest before system · §24 exclude in a reconciler ·
§25 BW → Datasphere → Databricks

Companions: **`BW_TRANSFORMATION_ROUTINES.md`** (symptom → cause → recipe for routine code) and
**`LO_COCKPIT_EXTRACTION.md`** (activating 2LIS extractors on the ERP side).

---

## 1. Tables you must know

### Request and load management

| Table | Content |
|---|---|
| **`RSBKREQUEST`** | DTP requests for **InfoCubes and InfoObjects**. `SRC`, `TGT`, `SRCTP`/`TGTTP`, `PROCESSMODE`, `USTATE`, **`LINESREAD`**, **`LINESTRANSFERRED`**, `TSTMP_START`/`_FINISH`, `UNAME` |
| **`RSPMREQUEST`** | Requests for **aDSOs**. `DATATARGET`, **`STORAGE`** (inbound/active), **`RECORDS`**, `REQUEST_TSN`, `REQUEST_STATUS`, `SOURCE`, `TLOGO`, `UNAME`, `SYST_DATE`/`SYST_TIME` |
| `RSSTATMANPART` | Status manager per InfoProvider. ⚠️ **there is no field `TIMESTAMPBEGIN`** — the obvious name does not exist |
| `T006` / `T006A` | Units of measure. **The texts (`MSEH3`, `MSEH6`, `MSEHT`) live in `T006A`**, language-dependent — `T006` has no `MSEH3` |
| `RSTRAN` | Transformations: `TRANID`, `SOURCENAME`/`SOURCETYPE`, `TARGETNAME`/`TARGETTYPE`, `OBJVERS`. Answers "is this InfoObject loaded at all?" |

🔴 **BW splits request management in two.** An aDSO load is recorded **exclusively** in
`RSPMREQUEST` — you will not find it in `RSBKREQUEST`, not even with the right filter. Whoever
knows only one of the two tables mistakes an empty hit list for "never ran".

🔴 **The rule of three is the first thing to look at after every load:**

```
READ         RSBKREQUEST.LINESREAD          what the DTP pulled from the source
TRANSFERRED  RSBKREQUEST.LINESTRANSFERRED   what survived the transformation
ACTIVATED    RSPMREQUEST.RECORDS per STORAGE  the merge across data packages
```

The three numbers side by side show **in which step** records or values disappear. Without
that view you look for the defect in the wrong half of the chain — in one project the numbers
were 114,921 / 43,045 / 25,818, the loss sat in the third step, and it was hunted for hours in
the first two.

### Dictionary

| Table | Content |
|---|---|
| `DD03L` | Fields per table: `TABNAME`, `FIELDNAME`, `POSITION`, `KEYFLAG`, `DATATYPE`, `LENG` |
| `DD02L` / `DD02T` | Tables and their descriptions (`TABCLASS = 'TRANSP'` filters transparent tables) |
| `RSDIOBJCMP` | **Compounding per InfoObject**: `IOBJNM`, `IOBJCMP`, `POSIT`, `OBJVERS` |

### Generated tables — the suffix rules

```
aDSO            /BIC/A<name>1   inbound
                /BIC/A<name>2   active
                /BIC/A<name>3   change log
classic DSO     /BIC/A<name>00  active
                /BIC/A<name>40  activation queue
                /BIC/B<number>  change log (generated name!)
InfoObject      /BIC/P<name>    master data, time-independent
                /BIC/Q<name>    time-dependent
                /BIC/M<name>    view over P and Q
                /BIC/T<name>    texts
                /BIC/S<name>    SIDs
                /BIC/X<name>    SIDs of navigation attributes (exists ONLY when
                                navigation attributes exist — a good indicator)
                /BIC/H<name>    hierarchy
```

⚠️ **SAP content lives in the `/BI0/` namespace, not `/BIC/`.** Manifest scanners like to
derive table names schematically with `/BIC/` and are wrong for every `0*` object.

⚠️ **An empty aDSO is not an empty aDSO.** Check all three tables: something in the inbound table
means "loaded but not activated" — an entirely different finding from "never loaded".

---

## 2. Field names: when `/BIC/`, when not

```
/BIC/ZPERTYPE    custom InfoObject                 → WITH prefix
CS_ITEM          SAP InfoObject                    → WITHOUT
CS_CHART         SAP InfoObject used as attribute  → WITHOUT
ZSOURCE          plain structure field in the aDSO → WITHOUT
```

**The prefix belongs to the object's namespace, not to the field.** A field that is not an
InfoObject at all gets none.

🔴 **Before every SQL statement and every routine, pull the field list from `DD03L`.** Ten seconds
against four failed attempts — that was the tally of guessing on a single day.

---

## 3. Routines

### `STATICS` is not allowed

Transformation routines are **methods** of the generated transformation class, and ABAP does not
allow `STATICS` in methods. Applies to field, start and end routines.

**The right place is the global declaration block:**

```abap
*$*$ begin of global - insert your declaration only below this line
    DATA: gt_buffer TYPE HASHED TABLE OF /bic/p<characteristic>
                    WITH UNIQUE KEY /bic/<characteristic>,
          gv_loaded TYPE c LENGTH 1.
*$*$ end of global - insert your declaration only before this line
```

What is declared there becomes an **attribute of the class** and survives the method calls —
exactly the effect `STATICS` was meant to have.

⚠️ The global block is **shown only in the editor of the start and end routine**. All routines of
one transformation are methods of **the same** class, though — a field routine sees what is
declared there. If a field routine needs a buffer, create a start routine for it, even if it does
nothing else.

⚠️ Use a **dedicated flag** as the "loaded" marker, not `gt_buffer IS INITIAL` — otherwise a
legitimately empty table is re-read on every data package.

### Compounded target fields are not scratch space

The end routine sees only `RESULT_PACKAGE`, i.e. only target fields. The reflex of parking a
source field in a target field by direct assignment fails when that target field is
**compounded** and the source hangs off a different parent:

```
ST22  ASSERTION_FAILED  in CL_RSTRAN_GEN_STEP_CONVERT
```

BW tries to generate a conversion step for it and does not find the source field in the
container. **Field routines do not have this problem** — they receive `SOURCE_FIELDS` and return
`RESULT` without translating between characteristics.

### `UNPACK` is `LPAD` in classic ABAP

```abap
    lv_tmp = SOURCE_FIELDS-<short_field>.
    SHIFT lv_tmp LEFT DELETING LEADING '0'.
    UNPACK lv_tmp TO RESULT.
```

Left-pads with zeros to the target width. The HANA function `LPAD` does not exist in Open SQL
7.50. The `SHIFT` + `UNPACK` combination is additionally **tolerant**: it returns the same result
whether `6`, `0006` or `000000000000000006` arrives.

### `DELETE` inside a `LOOP` over the same table

The classic trap — the indexes shift under the loop. **Mark, then delete:**

```abap
    LOOP AT RESULT_PACKAGE ASSIGNING <ls_res>.
      IF <condition>. <ls_res>-<field> = 'XX'. ENDIF.
    ENDLOOP.
    DELETE RESULT_PACKAGE WHERE <field> = 'XX'.
```

### `MOVE_TO_LIT_NOTALLOWED_NODATA`

In a `HASHED TABLE` the key fields are protected; `<fs> = ls_line` through a field symbol aborts
at runtime. Workaround: sort so the wanted record comes first and use only `INSERT` — no write
access needed.

---

## 4. Semantic grouping — when it is required

> **If the routine works on one record — no grouping.
> If it needs neighbours — group on the characteristic that defines the neighbourhood.**

A routine that fans out the period columns of *one* record needs none. A routine that
accumulates across periods (each period its own record) needs it without exception — otherwise
it computes partial sums per data package, **silently and without error**.

Do not switch it on everywhere as a precaution: it forces BW to cut the packages by that
characteristic and costs parallelism.

---

## 5. Activation: overwrite vs. summation

🔴 **The most expensive mistake of the day.** A key figure of an aDSO was set to **overwrite**
instead of summation. Symptoms:

- source `SUM(amount)` = 0.00 (double-entry bookkeeping), target ≠ 0
- positions with **few** source rows are exact, those with **many** are not
- **the record count is entirely correct** — every key is created, only the values are discarded

**Why it stays invisible for a long time:** as long as every source row carries its own key,
overwrite and add are **the same thing**. Only a source that maps many records onto the same key
triggers it. A model can be "proven value-preserving" for years and carry this defect.

**Diagnostic pattern:** small groups correct, large ones wrong → the merge across data packages
is at fault, not the transformation.

### The same trap at rule level

A key-figure rule of type **routine** has its **own aggregation setting**, not inherited from
direct assignment. Set to overwrite, exactly **one** source record per target key survives.

**Diagnostic pattern:** the values are far too small and the factor is **not constant** — off by
70 here, by 1,000 there. A wrong multiplication would be wrong everywhere by the same amount; a
surviving single record is not. Calculate back and the target value matches exactly one plausible
source row.

⚠️ Particularly treacherous when **two rule groups** fill the same target field and only one of
them uses a routine: one half is right, the other wrong, and you search the routine instead of its
setting.

---

## 6. DTP

### Extraction condenses — that is not a loss

A DTP from a DSO reads **condensed to the fields the transformation uses**. 5.4 million line items
become 115,000 read records.

🔴 **A smaller record count in the monitor is not automatically a loss.** The difference is
measurable: **condensing preserves the sum, filtering does not.** Compare the sum on both levels
first, then judge.

### Extraction source on classic DSOs

`Delta`/`Full` and *what is read from* are **two different settings**. A full DTP on the change
log reads the whole change log, not the active table. On decommissioned flows the log is often a
leftover.

### Constants are not padded

A CHAR 2 target (not NUMC) receiving the constant `0` holds `'0 '`, not `'00'`. Consequences:
every query with `= '00'` misses the data, and a separate value appears in the target.

**Check pattern:** concatenate all constants in **one** query and group.

```sql
SELECT F1 || ' / ' || F2 || ' / ' || F3 AS CONSTANTS, COUNT(*)
FROM "<target table>" WHERE <source>
GROUP BY F1, F2, F3
```

**More than one row** means the load is inconsistent (old and new records side by side). A wrong
value in the single row is visible at once. Cheaper than eight individual checks.

### Header lines

"Header lines to ignore" defaults to 0. A loaded header line becomes a master-data record whose
key is the column title and whose plan value is the first two characters of the next column
title. It is never noticed and then sits there for years — a grown system contained legacy records
of exactly this kind.

---

## 6a. Activation errors: look in the queue first, not in the code

🔴 **An aborted request stays in the activation queue and makes every later activation fail on
the same records** — regardless of what has been changed in the code since.

**"Delete data" on the aDSO removes the active table, not the open request.** Whoever empties the
object and reloads still has the blocker afterwards.

**Diagnosis order for every activation error:**

```sql
-- 1. What sits unactivated in the queue?
SELECT DATATARGET, STORAGE, REQUEST_STATUS, REQUEST_TSN, RECORDS, SYST_DATE
FROM RSPMREQUEST WHERE DATATARGET = '<adso>' AND REQUEST_STATUS <> 'D'
ORDER BY REQUEST_TSN DESC;
--    AQ = activation queue · AT = active table · CL = change log
--    GG = active · M = loaded, not activated · D = deleted

-- 2. Which records are broken, and where do they come from?
SELECT <origin characteristic>, <mandatory fields>, COUNT(*)
FROM "/BIC/A<adso>1"          -- the INBOUND table, suffix 1
GROUP BY <origin characteristic>, <mandatory fields>;
```

**The inbound table shows the records written before the activation aborted.** You see the defect
there instead of inferring it from behaviour. Always group by an origin characteristic — then it
says at once which load produced it.

⚠️ **What this cost to learn:** three routine versions built to answer a question that one query
answers. Halving the code showed nothing, because the problem was not in the code.

**And: mandatory fields announce themselves, silent fields do not.** `0FISCVARNT` is the
compounding parent of `0FISCPER` and forces an abort. An empty currency or an empty custom
characteristic passes through and creates an additional value in the key.

---

## 7. Activation dumps

**`ASSERTION_FAILED` in `CL_RSTRAN_GEN_STEP_CONVERT` / `GET_META_OBJECT_`**
→ SAP KBA **2532283**, component BW-WHM-DST-TRF, status *Bug Filed*.

The dump says **nothing about the correctness of the rule set**. The cause is usually a rule with
inconsistent metadata — typically after **changing the rule type** on the same rule.

**Way out: delete the rule, activate, recreate the rule.** Switching is not enough. Whoever changes
a rule type deletes the rule first.

---

## 8. HANA SQL in a BW context

- **Subqueries are not allowed in `CASE` or in the select list** (*"subquery expressions not
  allowed here"*); in the `WHERE` clause they are. Build classifications as a CTE of their own and
  join them; denominators via `CROSS JOIN` from a one-row CTE.
- `WITH` CTEs work (unlike in Datasphere SQL views).
- `FULL OUTER JOIN`, window functions (`SUM(...) OVER ()`) and `UNION ALL` all run.

---

## 9. Measurement rules — the four that keep applying

**1. `SUM` over balance-sheet positions is ≈ 0.** Assets = liabilities, P&L flows into equity.
Useless as a fill-level or coverage test. Likewise: the sum over all P&L positions of one company
is zero because the result line sits in the same area. And `SUM(amount)` over all accounts of an
FI ledger is **exactly** zero — double-entry bookkeeping. **That is proof of correctness, not an
error.**

**2. `SUM(ABS(...))` is not aggregation-stable.** When +100 and −100 collapse during condensing,
the algebraic sum is preserved and the absolute sum halves. Useless for comparisons **across
aggregation levels**.

> **Coverage is counted, value preservation is summed — and summed per unit.**

**3. Record counts say nothing about completeness.** Twelve equally sized months can be the image
of a fan-out in which ten months are empty. What counts is where a **value** stands, not where a
row stands.

**4. An outer join across two sources of different scope measures the scope difference, not the
deviation.** Align the population first, then compare. `INNER` and `FULL OUTER` answer two
different questions — you have to know which one you asked.

**And a fifth that follows from all of them:** a systematic factor of **exactly two** is never a
business problem. Always double counting — usually a dimension missing from the `GROUP BY`.

---

## 10. Modelling

### Compounding

`RSDIOBJCMP` tells you. A compounded characteristic (say, a financial-statement item compounded
to its chart) can become an **attribute** of another characteristic **only** if its compounding
parent is also an attribute of that object — and **positioned before it**. A reference
characteristic inherits the compounding and does not help.

### Conversion routine `ALPHA`

Protects against format differences between load file and target field. Without it, `20802` is a
different value from `0000020802`, and the lookup silently finds nothing.

On flat-file DataSources additionally check the **Format** column per field: `Internal` for
already converted values, otherwise the routine runs over them a second time.

### CompositeProvider over history plus a rolling window

A CompositeProvider that **unions** a history aDSO and a delta-window aDSO returns several version
states of the same event for the window period. **Whoever extracts it without a filter gets
inflated quantities.** It is built for reporting with filters set, not as an interface.

If you build something like it yourself over an InfoSource, the two DTPs must select
**disjointly** — typically a date cut.

### Two sources, one target — the transport principle

Never build against a different source in DEV than in PROD. When an object has data only in PROD:
**put an InfoSource in between and connect both sources.** Two trivial 1:1 transformations in,
one with the logic out. Identical in both systems; in DEV one branch simply delivers nothing.

---

## 11. Routine code: quoted `*$*$` markers

BW delimits the customer-editable parts of a routine with

```
*$*$ begin of routine - insert your code only below this line       *-*
*$*$ end of routine   - insert your code only before this line      *-*
```

The marker is itself a comment line — "is a comment" is therefore no distinguishing feature. What
distinguishes it: **`*$*$` stands in column 1.**

Whoever parses routine code and looks for the marker anywhere in the line loses the body of every
routine that **quotes** the markers in a comment — say, an end routine that documents the global
declaration block because that block is visible only in the start/end-routine editor:

```
*  *$*$ begin of global
*    DATA: gt_quota TYPE SORTED TABLE OF /bic/az<adso>2 ...
*  *$*$ end of global
```

The quoted "end of" closes the real section. Everything after it counts as generated frame. The
error is silent and looks plausible: 264 lines become 7, with the note "257 frame lines omitted".

**Rule:** evaluate the marker in column 1 only. If none is found, keep everything rather than guess.

---

## 12. A routine reads the generated table, not the object

`SELECT * FROM /bic/az<adso>2` stands for the aDSO `Z<ADSO>`. Whoever treats the table name as a
table gets an edge to a name that no namespace filter matches, and loses the dependency.

| Pattern | Object |
|---|---|
| `/BIC/A<aDSO>1` `…2` `…3` | aDSO: inbound / active / change log |
| `/BIC/A<DSO>00` `…40` | classic DSO: active / activation queue |
| `/BIC/F<Cube>` `/BIC/E<Cube>` | InfoCube fact tables |
| `/BIC/P Q M T S X Y H K J I <IOBJ>` | characteristic (with `/BI0/` and a leading `0`) |

The inference is a convention, not a metadata table: **always check the candidate against the
header table** (`RSOADSO`, `RSDODSO`, `RSDCUBE`, `RSDIOBJ`), or ghost objects appear.

---

## 13. Reach of a dependency scan

Direction is a property of the **path**, not of the scan. Whoever checks "both directions" by
testing every edge against the scan direction blocks nothing on "both" and reaches the entire
connected component — starting from a finance DSO you end up at maintenance orders.

Two mass sources, in this order:

1. **Master-data loads of the characteristics.** A characteristic brings its own DataSource,
   transformations and DTPs. On a real scan: 1,888 of 2,811 objects, 409 of 432 transformations.
2. **Chains and planning sequences.** A process-chain node knows many functionally unrelated
   loads and reconnects branches that the direction lock has just separated.

---

## 14. The clipboard triples

`CL_GUI_FRONTEND_SERVICES=>CLIPBOARD_EXPORT` runs through `DP_STRETCH_SIMPLE_TABLE`. The function
creates a copy of the table with **three times the column width** (`LCNDPU45`, line 59:
`wide_field_length = field_length * 3`, capped at 65,535).

The width is the **type width**, not the actual text length. A table of `c LENGTH 2000` costs
12,000 bytes per row under Unicode — even when every row carries 20 characters. 14.6 MB of text
became a request of about 7 GB and ended in `TSV_NEW_PAGE_ALLOC_FAILED`.

The treacherous part: the abort comes **after** the actual work, when fetching the result. The
run was finished; the result is gone anyway.

**Rule:** clipboard only for small volumes, and set the limit at rows × type width, not at text
length. For anything larger, the ALV grid (the GUI's own copy path does not stretch) or a file.

The opposite direction is just as wrong: a narrow column (`c(255)`) avoids the abort and
**silently truncates** every longer line. Both are data loss; only one of them is loud.

---

## 15. Where the truth about a load sits

In an aDSO a record travels through three tables:

| Suffix | Role | Lifetime |
|---|---|---|
| `…1` | inbound | **cleared on activation** |
| `…2` | active | the stock |
| `…3` | change log | holds the movement per request |

An order to remember follows from this:

- **Before activating**, check the **inbound** table (`…1`). It holds what the run produced, and
  you can still abort. That is the only moment at which a broken request is cheap to discard.
- **After activating**, the inbound table is empty. Whoever searches there then finds nothing and
  mistakes it for "no data". The answer is in the **change log** (`…3`), with `REQTSN` per request.
- The **active table** (`…2`) only says what applies now — never who wrote it.

On a classic DSO the suffixes are `…00` active and `…40` queue; the log sits in a `/BIC/B*` table.

**Contradiction between rule and result?** Order: change log per `REQTSN` → then `RSPMREQUEST` →
then the transformation rules. Not the code first.

---

## 16. An empty key field betrays itself only in square brackets

A filter that matches nothing looks in the ALV like an empty table. Before suspecting the load
chain, group the field **without** the filter and bracket the value:

```sql
SELECT '[' || t."/BIC/ZFLAG" || ']', COUNT(*) FROM ... GROUP BY ...
```

`[0001]` versus `[   1]` versus `[]` is otherwise indistinguishable — and a `CHAR` comparison fails
on it silently. In one case the field was empty throughout the target table although it is a
**key field**: the source transformation does not supply it, and a hardcoded value in the expert
routine carried the business meaning alone.

**Mnemonic:** four empty results with the same filter are not a data problem but a filter problem.

---

## 17. The control group decides, not the remainder

A remainder that is distributed *contrarily* always looks like a distortion: 50 % of the records
carried no area, and among them 73 % were vacant, while among the visible ones 65 % were occupied.
The obvious conclusion — the reported ratio is too high — was wrong. The remainder consisted of
parking spaces, which are measured in units and legitimately have no rentable area.

It was proven only by the same decomposition on the **visible** set: there the cases lay
completely differently. A decomposition without a control group is a number, not a check.

---

## 18. Open-ended contracts inflate period views until 2099

The RE-FX occupancy extractor (`0REFX_14`, `REIS_OCCUPANCY_PER_TRAN`) resolves every occupancy
interval into monthly records — for open-ended contracts up to the technical end date. **81 % of
the table** were identical projection years from a cut-off year onward, bit-identical year after
year.

Every evaluation without a time window is dominated by it. The limit belongs into the model as a
condition, not into the users' query discipline. Recognition mark: `GROUP BY` year returns, from
some year on, a constant record count **and** a constant sum.

---

## 19. Correcting without selective deletion: self-transformation with `RECORDMODE = D`

Taking back a slice of an aDSO (one month, one source) works through a self-transformation that
sets `RECORDMODE` to `D`, plus a DTP filter on exactly that slice. After activation the records
are gone. Then reload.

Advantage over selective deletion: the operation is an ordinary request with a log, can be hung
into a chain and repeated. Prerequisites: an aDSO with change log or activatable inbound, and a
DTP filter that sits exactly.

---

## 20. Stock figures do not belong in a summing period cumulation

QTD/YTD/L12 as the sum of monthly values is right only for flow figures (amounts, boxes). For
headcount, FTE or key-date areas, YTD would be twelve times too much. Such accounts need LAST
logic (in SAC: exception aggregation LAST) or stay out of the cumulation. The simplest way is to
exclude the source through the cumulation's DTP filter. When a new source is connected, the
exclusion applies automatically as long as the filter is a positive list.

---

## 21. Two organisational views on one record: unit and partner

When a key figure has two assignments (e.g. personnel before secondment by company code, after
secondment by organisational key), one record with unit = view 1 and partner = view 2 suffices.
The totals of both views are equal by construction. Records without a second assignment need
partner = own unit, otherwise they are missing from view 2.

If the front end knows no partner (an SAC model without a partner dimension), view 2 has to be
derived as records of its own on accounts of its own with the unit swapped. That belongs in the
source-specific transformation, not in the general self-transformation.

---

## 22. Self-loop transformations carry only what is universal

Into the self-transformation of an aDSO belongs only source-independent logic — quota
distribution, period types QTD/YTD/L12, freeze mechanics. Source-specific derivations (say, a
second organisational view from the org key of one particular source) go into that source's own
transformation, e.g. as a rule group of its own. Test question before touching the self-loop:
does the rule hold for **all** values of the source characteristic? If not → the single
transformation.

---

## 23. Manifest before system

Before deriving a cause with SQL (`RSDKYF`, `TF160`/`TF161`, aDSO fill levels …), read the
documented routine source — the start routines, when documented as they should be, carry decisions
**with date and reason**. An empty local-currency branch cost 45 minutes of table queries — the
reason stood verbatim in the start routine: a deliberate decision, not a defect. Documentation
answers "why is it like this", SQL answers "what does it look like today". Do not swap the order.

---

## 24. Exclude in a reconciler means delete (ABAP range semantics)

When an application reconciles target against actual and removes the surplus, a filter that acts
only on the **source** does not narrow the scope — it produces deletions: the excluded object
afterwards sits "in the target, not in the source", which is exactly what the reconciliation
removes. Range semantics amplify it: a set consisting only of `E` lines matches *nothing*
(`IN` needs at least one `I` hit), so the target state becomes empty — a withdrawal order for the
whole area. Rules: apply every restriction symmetrically to both sides; count and log what falls
out instead of touching it; reject exclude-only sets in validation and demand the intended `I`
line; do not allow `NE`/`NP` (an exclusion disguised as an inclusion defeats the rule).

---

## 25. BW → Datasphere → Databricks — the paths (as of September 2026, per SAP Help and SAP blogs)

| Path | Mechanics | Semantics | Delta-shareable to Databricks? |
|---|---|---|---|
| **Model Transfer** (`RSDWC_QUERY`, query variants) | metadata over an HTTP tunnel (InA + `/sap/bw4/v1/dwc`), data through the **SDI HANA adapter with a DB user on the BW HANA** → remote tables + dimensions/texts/hierarchies + **analytic model**; restricted/calculated key figures, exception aggregation and constant selection come along, hierarchy-node filters become IN lists; analysis authorizations importable as DACs | full | **no** (remote tables/views/AMs are not file-store local tables) |
| **SAP BW connection** (ABAP adapter, ODP-BW) | remote tables on aDSO / CompositeProvider / "query as InfoProvider"; real-time only aDSO with change log | flat | no |
| **Replication flow** ODP-BW / SAPI | direct, no DMIS; initial + delta | flat | only after reloading into a file-store space |
| **Data Product Generator (DPG)** — BW/4 2023 SP0+, 2021 SP4+, 7.50 SP24+, TCI note 3590400 | data subscriptions (BW cockpit / BW modelling tools) → **local table (file)** in a read-only "BW inbound space" (HDLFS); full/delta; CompositeProvider delta since 03/2026, hierarchies since 06/2026 | flat | **yes** — but **only for BW private cloud edition under a Business Data Cloud licence**; on-premise means a lift into PCE (note 3584640); no embedded BW |
| **Query Template Generator (QTG)** — since 12/2025 | query → dimensions + fact view + **analytic model in the HANA space** | full | no |

**The sentence that decides an architecture:** BDC delta-share data products take exclusively
local tables (file) from HDLFS spaces. Query semantics (Model Transfer, QTG) end in Datasphere;
Databricks receives flat tables and needs a semantic layer of its own. **Model Transfer brings
semantics to Datasphere; DPG brings data to Databricks; never both through one object.**

**Without BDC:** delta sharing between Datasphere and Databricks is gated on BDC in both
directions. Outbound = replication flow "Premium Outbound" to ADLS Gen2 / S3 as Delta/Parquet
(replication-flow targets: S3, ADLS, GCS, Kafka, Confluent, BigQuery, SFTP, HANA, HDL files,
Signavio — **no Databricks target, Snowflake as source only**). Return = generic JDBC federation
(DP agent + Simba driver) on a SQL warehouse. Databricks Lakeflow Connect has **no SAP
connector**. The **Azure Data Factory SAP BW Open Hub connector does not support BW/4HANA** (BW
7.01+ only) — for BW/4HANA that means Open Hub → database table or file plus your own pickup.
The Open Hub licence also applies to ODP-OData on BW InfoProviders, not only to Open Hub
destinations. And since 2026, ODP over RFC is reserved for SAP's own consumers (BW/4HANA,
Datasphere, Data Services); third-party ODP-RFC extraction is prohibited by SAP note 3255746
and actively blocked by a security patch — ODP over OData stays permitted.

---

## Sources

- SAP Help — SAP BW/4HANA: data transfer process, aDSO request management, transformation
  routines, RE-FX extractors; SAP BW in SAP Business Data Cloud (Data Product Generator, Query
  Template Generator); Datasphere connection and replication-flow documentation
- SAP KBA 2532283 (`ASSERTION_FAILED` in `CL_RSTRAN_GEN_STEP_CONVERT`), SAP notes 3590400,
  3584640, 3255746
- Kernel include `LCNDPU45` (`DP_STRETCH_SIMPLE_TABLE`)
- Everything else: measured on productive BW 7.5 / BW/4HANA systems. Table and field names were
  verified against the data dictionary of the release in question; re-verify on yours.
