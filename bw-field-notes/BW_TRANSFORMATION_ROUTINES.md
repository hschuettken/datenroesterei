# BW 7.4/7.5 — Transformation Routines: Traps and Recipes

> Hard-won on a BW 7.5 financial-consolidation project. Applies to classic BW 7.4/7.5 (and the
> ABAP side of BW/4HANA), not to Datasphere. Every item: **symptom → cause → recipe.**
> Companion to `BW_KNOWLEDGE.md` §3 (routines) and §11 (the `*$*$` markers).
> No customer-specific information.

---

## 1. `MONITOR` is a table WITHOUT a header line

**Symptom:** `MONITOR is a table without a header line, therefore no component named MSGID`

**Cause:** the classic pattern from BW 3.x days (`MONITOR-msgid = …` / `APPEND MONITOR.`)
presupposes a header line. From 7.4 on there is none.

**Recipe:**
```abap
  DATA: ls_monitor LIKE LINE OF MONITOR.
  ...
  CLEAR ls_monitor.
  ls_monitor-msgid = 'ZMSGCLASS'.
  ls_monitor-msgty = 'I'.
  ls_monitor-msgno = '001'.
  ls_monitor-msgv1 = |{ lines( SOURCE_PACKAGE ) }|.
  APPEND ls_monitor TO MONITOR.
```
`LIKE LINE OF MONITOR` instead of `TYPE rstmonitor` — then no structure name has to be guessed.
Some skeleton generations already provide a `MONITOR_REC`; use that if present.

**Addendum:** `ls_monitor-msgv1 = lines( … ).` is an `i`→`c` assignment and converts
**right-aligned** — the number then appears in the monitor with leading blanks. Use a string
template (`|{ … }|`) or `CONDENSE`.

---

## 2. The generated type name changes between releases

**Symptom:** `tys_sc_1` is unknown (or, the other way round, `_ty_s_SC_1`).

**Cause:** BW generates the routine structures and changed the naming convention: BW 7.3
`tys_sc_1` / `tyt_sc_1`, BW 7.5 **`_ty_s_SC_1` / `_ty_t_SC_1`** (target: `_ty_s_TG_1`).

**Recipe: do not name the type at all.**
```abap
  DATA: lt_new  LIKE SOURCE_PACKAGE,
        ls_new  LIKE LINE OF SOURCE_PACKAGE.
  FIELD-SYMBOLS: <ls_src> LIKE LINE OF SOURCE_PACKAGE.
```
Survives every upgrade. Applies equally to `RESULT_PACKAGE` in end routines.

---

## 3. `FORM`/`ENDFORM` in the global section is not allowed

**Symptom:** syntax error on `FORM` inside the `*$*$ begin of global` block.

**Cause:** in BW 7.5 the global section belongs to the **routine class**. Only declarations are
permitted there (`TYPES`, `DATA`, `CONSTANTS`), no subroutines.

**Recipe:** inline the logic into the routine, or make it **private methods** of the routine
class. Older documentation (and older systems) show the FORM pattern — it does not carry over.

---

## 4. Open SQL checks column names at SYNTAX time

**Symptom:** unknown column name, although the `SELECT` sits behind a runtime switch that never
becomes `true`.

**Cause:** the check happens at activation, not at runtime. An `IF gc_switch = abap_true.` in
front of it rescues nothing.

**Recipe:** as long as a column name is unclear, **comment out or remove** the block — a runtime
switch is not a solution. And: leave a dead, commented-out block in place only if it points to the
*right* path. If it points to a refuted source, it sends the next reader into the same dead end —
then remove it without replacement and write the decision down in plain words.

---

## 5. `#` is a display, not a value

**Symptom:** after loading there is a characteristic value `#` **next to** the initial value, or
the master-data check fails.

**Cause:** BW displays the initial value of a characteristic in queries and in SAC as `#`.
Whoever writes a literal `'#'` into the field creates a **real, different** value.

**Recipe:** leave empty characteristic values **empty**. The rule "do not discard the record" is
met by the absence of a filter, not by substitute values.

---

## 6. 1:n unpivot: where the routine belongs

**Symptom:** you want to turn N columns into N rows and find no place for it.

**Cause:** the visibilities are strictly separated:

| Routine | sees |
|---|---|
| start routine | **only** `SOURCE_PACKAGE` (source structure) |
| end routine | **only** `RESULT_PACKAGE` (target structure) |
| expert routine | both |

An unpivot needs the source columns **and** a field for the new dimension (e.g. period). Neither
of the two simple routines has both.

**Recipes, in order of cleanliness:**
1. **An InfoSource that carries both worlds** — source fields *plus* the target fields. Then a
   start routine suffices and the field mapping stays graphical. InfoSources are not persistent;
   the width costs only definition effort.
2. **Expert routine** — one object fewer, but the graphical field mapping disappears entirely and
   some developer guidelines forbid it.
3. Carrier fields in the inbound aDSO — works, but violates "inbound layer = 1:1 image".

⚠️ **Two InfoSources (wide → narrow) do NOT solve it by themselves.** The transformation in between
again sees only one side. It works only if the **inbound** InfoSource carries the target fields
and the routine is *its* start routine.

---

## 7. A DTP cannot end on an InfoSource

InfoSources are not persistent. The load runs in *one* pass from the source provider to the
target provider and passes through all transformations of the chain on the way.

**Consequences:**
- The **target aDSO must exist** before a routine in the middle of the chain is testable at all.
- Between the transformations there is **nothing to look at**. Debugging goes through the DTP in
  **expert mode with "Simulate"** and a breakpoint in the routine.

---

## 8. Content data elements exist only after content activation

**Symptom:** the global section does not compile because `/BI0/OI…` data elements are unknown —
although the work concerned an entirely different object.

**Recipe:** in routine declarations, **type elementarily** (`TYPE c LENGTH 18`) instead of via
content data elements. Copy the lengths from the generated structure. Otherwise an incomplete
content activation blocks work that has nothing to do with it.

---

## 9. Master-data tables of an InfoObject

| Table | Content |
|---|---|
| `/BI0/P<IOBJ>` | attributes **without** time dependency |
| `/BI0/Q<IOBJ>` | attributes **with** time dependency |
| `/BI0/M<IOBJ>` | view over P and Q — exists only when time-dependent attributes exist |
| `/BI0/T<IOBJ>` | texts |

Content attributes appear as a column **without the leading zero** (`0CURKEY_LC` → `CURKEY_LC`).

⚠️ **`RSD1` shows only the A version.** Non-activated content is visible exclusively through
`RSA1 → Business Content`. If an attribute is missing from the table, the first question is not
"does it exist?" but "was the InfoObject activated with its full attribute set?".

---

## 10. Content activation: mind the grouping

With "data flow before/afterwards" the collection drags **DataSources** along — and those need a
source-system assignment. If the source system is locked or not connected at that moment, this
ends in errors or silently skipped objects.

**Recipe:** for pure InfoObject activation use **"Only necessary objects"**. When transferring,
check that **compounding and reference characteristics** come along — if they are missing,
records later run into empty or wrong characteristic values, and you see it only when loading.
