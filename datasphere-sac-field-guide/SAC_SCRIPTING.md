# SAC — Story & Application Scripting

> What the SAC scripting language can and cannot do, the API surface that matters, and the
> patterns and defects seen in productive stories and in SAP's own training material.
> Companion to `SAC_KNOWLEDGE.md` and `SAC_APIS.md`.
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

SAC's scripting language looks like JavaScript and is a **typed subset** of it. Most of the
friction comes from three places: the missing language features, the type system, and member keys
arriving in hierarchy format.

## 1. The language is a subset

| Not available | Use instead |
|---|---|
| object literals / maps as data structures (`var m = {}; m[k] = …`) | primitives and typed arrays only — replace "collect per key" with several passes over the data |
| plain array literals (`var a = []`) | `ArrayUtils.create(Type.string)` |
| defining functions inside an event handler | **script objects** — and they are **per story**, so a helper written in one story does not exist in another |
| `undefined`/loose typing tricks | declare return types on script-object functions; a missing return type silently discards the value |

The one structured type you do use as a literal is the **member payload** for master-data writes
(`{id, description, properties:{…}}`), which is accepted because it is a typed API argument.

**The most common self-inflicted bug in script objects:** a function whose body computes the right
value but has **no `return`, and no declared return type**. It validates, it runs, it returns
nothing. Check both when reviewing.

## 2. The API surface

The authoritative catalogue is SAP's **Optimized Story Experience API Reference Guide** (see §12),
which is organised alphabetically by class. What follows is a map of it — what exists, grouped by
what you would go looking for.

| Category | Classes |
|---|---|
| **Application** | `Application`, `ApplicationPage`, `BookmarkSet`, `DataChangeInsights`, `Scheduling`, `SearchToInsight` |
| **Data sources** | `DataSource`, `FileDataSource`, `InputControlDataSource`, `CommentingDataSource`, `BpcPlanningSequenceDataSource` |
| **Planning** | `Planning`, `PlanningModel`, `PlanningVersion`, `DataLocking`, `DataAction`, `MultiAction`, `BpcPlanningSequence` |
| **Visualisation widgets** | `Chart`, `Table`, `GeoMap`, `RVisualization`, `ValueDriverTree` |
| **Input controls** | `InputControl`, `Dropdown`, `ListBox`, `CheckboxGroup`, `RadioButtonGroup`, `Slider`, `RangeSlider`, `InputField`, `TextArea` |
| **Layout & navigation** | `Panel`, `FlowPanel`, `PageBook`, `TabStrip`, `Popup`, `StoryPopup`, `FilterPanel` |
| **Display** | `Image`, `Shape`, `Text`, `Button`, `Timer` |
| **Utilities** | `ArrayUtils`, `ConvertUtils`, `StringUtils`, `NavigationUtils`, `DateFormat`, `NumberFormat`, `CurrentDateTime`, `Range`, `TimeRange`, `UrlParameter`, `LayoutValue` |
| **Export** | PDF, Excel, CSV and PowerPoint export APIs |

The subset that carries most day-to-day work:

| Object | Methods worth knowing |
|---|---|
| `Application` | `showMessage(ApplicationMessageType.…)`, `showBusyIndicator` / `hideBusyIndicator`, `refreshData`, `getFileDataSource(<modelId>)` |
| `PlanningModel` | `getMembers(<dim>[, {limit: n}])`, `getMember(<dim>, <key>)`, `createMembers`, `updateMembers`, `deleteMembers`, `getPlanning()`, plus the private-version family (§8) |
| `Planning` | `getPublicVersion(s)`, `getPrivateVersion(s)`, `getDataLocking()`, `getPlanningAreaInfo()`, `submitData()`, `setUserInput()`, `isEnabled()` / `setEnabled()` |
| `Table` | `getSelections()`, `getDataSource().getResultSet([selection])` |
| `DataAction` / `MultiAction` | `setParameterValue`, `getParameterValue`, `setAllMembersSelected`, `isAllMembersSelected`, `execute()`, `executeInBackground()`, `onExecutionStatusUpdate`, `bindInputControl` |
| `Dropdown` / `ListBox` | `removeAllItems`, `addItem(key[, text])`, `setSelectedKey`, `getSelectedKey` |
| `InputField` | `getValue`, `setValue` |
| `StoryPopup` | `open`, `close`, and `onButtonClick(buttonId)` — `button1` = OK, `button2` = Cancel |

A story's own `usedApi` inventory (readable through the story definition, `SAC_APIS.md` §6) is the
fastest way to see which of these an existing story actually touches before you change it.

> **Version the reference against your tenant.** The guide is published per release; methods do get
> added. If a call the documentation shows does not resolve in the editor, check the guide's
> version against your tenant's release before assuming you have the syntax wrong.

## 3. Reading filters — story filter vs widget filter

The story-level filter is read through the **file data source**, not through a widget:

```js
var filter = ArrayUtils.create(Type.string);
var f = Application.getFileDataSource("<modelId>").getDimensionFilters("<Dimension>")[0];

if (f === undefined) { return filter; }                       // "All" → empty array, do not restrict
if (f.type === FilterValueType.Single) {
    filter[0] = cast(Type.SingleFilterValue, f).value;
} else if (f.type === FilterValueType.Multiple) {
    filter = cast(Type.MultipleFilterValue, f).values;
}
return FormattingFunctions.separateFromHierarchyFormat(filter);
```

Three things go wrong here in practice:

1. **`getDimensionFilters` returns an empty array when the filter is on "All"** — `[0]` on an empty
   array kills the script. Guard for `undefined`.
2. **The model id is usually hardcoded** as a string literal. After a model migration this silently
   reads the *old* model's filters. Make it an argument, and when you migrate a story remember that
   model id, dimension names **and** hierarchy names all change together — an id swap alone is not
   enough.
3. ⚠️ **Dimension names are often prefixes of one another** (`X_Customer` vs `X_Customer_SAC`). A
   naive search-and-replace across a story definition destroys the already-migrated references.
   Count first, replace by descending length or with word boundaries, and verify the residual count
   before saving.

## 4. Hierarchy format — the conversion everyone needs

Anything coming out of a **filter** or a **table selection** on a hierarchical dimension is
bracketed (`[All].[2026].[202603]`, `[Product].[ProductHierarchy].&[P_ALL]`), while
`setParameterValue` and the member APIs want the **bare key**. Values from a dropdown you filled
yourself are already bare.

```js
// separateFromHierarchyFormat(values: [string]) : [string]
var result = ArrayUtils.create(Type.string);
for (var i = 0; i < values.length; i++) {
    var s = values[i];
    var open = s.lastIndexOf("["), close = s.lastIndexOf("]");
    result[i] = (open >= 0 && close > open) ? s.substring(open + 1, close) : s;
}
return result;
```

On a flat dimension the cut is a no-op, so it is safe to apply unconditionally — which is exactly
what makes it a good shared helper. The same cut is needed on `onAfterDataEntryProcess` contexts
(`SAC_KNOWLEDGE.md` §12).

## 5. Reading master data and result sets

```js
// members + attributes
var members = PlanningModel_1.getMembers("<Dimension>", {limit: 20000});
members[i].id; members[i].description; members[i].properties["<Attribute>"];

// one member
var m = PlanningModel_1.getMember("<Dimension>", <key>);

// result set of a table, optionally narrowed to the selection
var rs = tbl.getDataSource().getResultSet(tbl.getSelections()[0]);
rs["<Dimension>"].properties["<Dimension>.<Attribute>"];   // attribute of a dimension member
rs["<Account>"].formattedValue;                             // the displayed cell value
```

- **`getMembers` has a default result limit** — pass `{limit: n}` explicitly when the dimension is
  large, and sanity-check the returned count. A silently truncated member list produces a dropdown
  that looks fine and is missing entries.
- **Version properties are read this way too**, which is the supported alternative to hardcoding
  calendar logic: `rs["Version"].properties["Version.lastActualMonth"]`.
- **Deduplicating by comparing with the previous element only works if the source is sorted.** The
  common "distinct attribute values" loop in sample code relies on `getMembers` ordering; if you
  need distinctness, do not assume it.

## 6. Master-data CRUD from a story

```js
var member = { id: productId, description: description,
               properties: { Weight: weight, ManuallyCreated: manuallyCreated } };

var ok = PlanningModel_1.createMembers("<Dimension>", member);   // updateMembers / deleteMembers
if (ok === true) {
    Application.showMessage(ApplicationMessageType.Success, "Created.");
    Application.refreshData();
} else {
    Application.showMessage(ApplicationMessageType.Error, "Failed.");
}
```

`deleteMembers` takes an array of **bare keys** — selections must go through the hierarchy strip
(§4) first. Numeric-looking attributes are frequently `NVARCHAR`, so validate with
`ConvertUtils.stringToNumber(x).toString() === "NaN"` before writing.

⚠️ **Popup buffers must be reset by the caller.** The standard create/update popup pattern keeps
the field values in global variables and fills the inputs in `onOpen`. If the "create" entry point
does not clear them, Create opens pre-filled with the previously edited record — a data-quality
bug that looks like a UI glitch.

## 7. Parametrising and running data and multi actions

```js
DA.setParameterValue("targetVersion",   "public.Forecast1");   // SINGLE → string
DA.setParameterValue("Product",         products);             // MULTI  → [string]
DA.setAllMembersSelected("<Dimension>", "<Hierarchy>");        // "everything" without listing it
```

- **Cardinality is type-checked**: a `SINGLE` parameter takes a string, a `MULTI` one takes a typed
  array. Wrap single values with `ArrayUtils.create` where needed.
- `getParameterValue` and `isAllMembersSelected` read the current state back — useful for a
  "what will this run do?" confirmation before firing.
- `bindInputControl()` ties a parameter to an input control so the planner's selection flows in
  without any script at all. Prefer it over reading the widget yourself where the mapping is 1:1.

### Synchronous vs background execution

There are two execution methods, and the choice matters as soon as an action runs longer than a
few seconds:

| | `execute()` | `executeInBackground()` |
|---|---|---|
| Behaviour | runs synchronously, the story waits | queues the run and returns immediately |
| Returns | `DataActionExecutionResponse` | `DataActionBackgroundExecutionResponse` |
| Status values | `Accepted`, `Queued`, `Running`, `Success`, `Canceled`, `Error` | `Accepted`, `Error` |

**The six statuses are the reason not to write `if Success … else if Error …`.** A run that comes
back `Queued` or `Running` is neither, and a story that only handles two of them shows the user
nothing at all — the single most common defect in inherited planning stories.

```js
DA.onExecutionStatusUpdate = function(response) {
    if (response.status === DataActionExecutionResponseStatus.Success) {
        Application.showMessage(ApplicationMessageType.Success, "Done.");
        Application.refreshData();
    } else if (response.status === DataActionExecutionResponseStatus.Error) {
        Application.showMessage(ApplicationMessageType.Error, "Failed.");
    } else if (response.status === DataActionExecutionResponseStatus.Canceled) {
        Application.showMessage(ApplicationMessageType.Warning, "Cancelled.");
    } else {
        // Accepted / Queued / Running — keep the busy indicator up, say something
    }
};
```

`onExecutionStatusUpdate` is the event that makes `executeInBackground()` usable: it fires on
status changes, so the story can leave the user free while a long prefill runs and report when it
finishes. For anything a planner triggers on a large model, background execution plus this handler
is the better pattern — a synchronous `execute()` on a big scope leaves the story frozen with no
way to tell whether it is working or hung.

- **Pair `showBusyIndicator()` with `hideBusyIndicator()`.** Calling only the hide half — very
  common in inherited stories — means long-running actions give no feedback at all.
- **Verify which model the action gadget is bound to.** A story whose tables bind to one model and
  whose scripted action gadget still points at another runs happily and writes into the wrong
  model. After any model migration this is the first thing to check, and it is invisible on the
  canvas.

---

## 8. The planning API — versions, private versions and data locking

This is the part of the surface most stories never touch, and it is where the operational
capabilities sit.

### Versions

```js
var planning = tbl.getPlanning();
planning.getPublicVersion("<name>").publish();      // works for any version — derive the name,
                                                     // never hardcode it in a save button
var v = planning.getPrivateVersion("<name>");
v.copy(); v.deleteVersion(); v.undo(); v.redo(); v.getId(); v.getDisplayId();
```

`undo()` / `redo()` on a version are worth knowing: they give a planning story a real undo for
data entry, which users ask for constantly and which most implementations answer with "restore
from a backup version".

### Private-version housekeeping — the counterpart to the row limit

```js
PlanningModel_1.getModelPrivateVersions();          // all private versions of the model
PlanningModel_1.deleteModelPrivateVersions([...]);  // specific ones, by id
PlanningModel_1.deleteAllModelPrivateVersions();    // everything
```

Every private and public-edit version carries its own data snapshot, and they accumulate
unnoticed — abandoned edit sessions, users who never published, versions left behind by failed
runs. That is the same mechanism behind the private-version row limit described in
`SAC_KNOWLEDGE.md` §12: the limit is about **materialisation**, and stale private versions are
materialised data nobody is using.

⚠️ `deleteAllModelPrivateVersions()` destroys other people's unpublished work. It belongs behind
an admin-only screen with a confirmation, never on a general planning page — and the polite
version of this feature lists them first (`getModelPrivateVersions()` returns owner, category and
creation time) so an administrator can see whose work they are about to discard.

### Data locking from a script

```js
var locking = tbl.getPlanning().getDataLocking();
locking.getState(...); locking.setState(...);       // single slice
locking.getStates(...); locking.setStates(...);     // batch
```

States: **`Open`**, **`Locked`**, **`Restricted`** (lock owners only), and **`Mixed`** — which is
a *read* result, not something you set: it means the queried region contains more than one state.
Code that compares against `Open` and treats everything else as locked will misreport a mixed
region; handle it explicitly.

Scripted locking is what lets a release workflow live in the story rather than in a multi action —
useful when the lock scope depends on what the user just selected. The multi-action data-locking
step (`SAC_KNOWLEDGE.md` §7.2) remains the right tool when the scope is fixed and the locking is
part of a scheduled sequence.

### Planning area and submission

`getPlanningAreaInfo()` reports the model's planning area — the setting that bounds how much data
a private version materialises. A story that runs heavy data actions can read it to fail fast with
a meaningful message instead of letting the run hit the row limit. `submitData()` and
`setUserInput()` cover programmatic data entry where a table's own entry grid is not the right UI.

---

## 9. Utility classes

Small, and repeatedly re-implemented by hand in stories that did not know they existed:

| Class | What it saves you |
|---|---|
| `NavigationUtils` | `createStoryUrl` / `openStory`, `createApplicationUrl` / `openApplication`, `openDataAnalyzer`, `openInsight`, `openUrl` — **the supported way to navigate between stories with parameters.** Hand-rolled "URL composer" script objects that build story links by string concatenation are a common and avoidable maintenance burden |
| `UrlParameter` | `create()` — build the parameters those navigation calls take, instead of concatenating query strings |
| `StringUtils` | `replaceAll()` — the missing string method that scripts most often reach for |
| `ConvertUtils` | `stringToNumber`, `stringToInteger`, `numberToString` — mandatory, because numeric-looking attributes are usually strings |
| `NumberFormat` | `create` / `format`, decimal and grouping separators, maximum decimal places, scaling factor — formatting a figure into a text widget without inventing rounding |
| `DateFormat` | `format()` for temporal values |
| `CurrentDateTime` | `createCalendarDateTime()` / `createFiscalDateTime()` — **fiscal-aware "today"**, which is what planning stories actually need and hand-written date maths gets wrong |
| `Range` / `TimeRange` | `create`, plus `createMonthRange` / `createWeekRange` / `createYearRange` — typed ranges for filters and parameters rather than assembled member lists |
| `ArrayUtils` | `create()` — the only way to make a typed array (§1) |
| `LayoutValue` | `create()` — programmatic layout, for dynamic panels |

Two of these deserve to be house rules: **use `NavigationUtils` for every story-to-story jump**,
and **use `CurrentDateTime.createFiscalDateTime()` instead of deriving the fiscal period from the
calendar date in script**.

## 10. A layering that stays maintainable

The structure worth adopting — and the one SAP's own training material implies with its stubs:

- **Generic helpers in one script object**: read a dropdown key, read a filter value, set one
  parameter, execute-and-report. No story-specific knowledge.
- **A story-specific wrapper in a second script object**: "fill this multi action completely",
  which knows the parameter names and where each value comes from.
- **Event handlers stay thin** — read one widget, call the wrapper, refresh. If a handler is longer
  than about ten lines, the logic belongs in a script object.

Two habits that pay off immediately: keep **filter values in global variables** written by the
handler that owns the widget (rather than re-reading widgets from everywhere), and capture the
**initial state of input controls in `onInitialization`** so a "reset filters" button is three
lines rather than a rebuild.

## 11. Review checklist for inherited story scripts

Every item below was found in production or in official training material:

- [ ] script-object functions with a computed value but **no `return` / no return type**
- [ ] hardcoded **model IDs**, dimension names and hierarchy names (breaks on migration)
- [ ] hardcoded **calendar logic** per version instead of reading version properties
- [ ] loops iterating over the **wrong `.length`** (a string's length instead of the array's)
- [ ] `debugger;` statements left in
- [ ] `hideBusyIndicator()` without a matching `showBusyIndicator()`
- [ ] `onActive` / `onInitialization` debug leftovers that clobber globals **on every page
      activation**, including on return from a popup
- [ ] a Cancel branch trapped inside the `else` of a validation check — Cancel stops working
      exactly when the input is invalid
- [ ] popup buffers never reset between create and update
- [ ] `execute()` status handling that covers only Success and Error — there are six (§7)
- [ ] a long-running action run with `execute()` instead of `executeInBackground()` + `onExecutionStatusUpdate`, freezing the story
- [ ] hand-rolled URL composition for story navigation instead of `NavigationUtils` (§9)
- [ ] fiscal periods derived from calendar dates in script instead of `CurrentDateTime.createFiscalDateTime()`
- [ ] widgets bound to a different model than the scripted action gadget
- [ ] declared-but-unused global variables (harmless, but a reliable sign of unfinished work)

---

## 12. Sources

- **Optimized Story Experience API Reference Guide** (published per release; the class catalogue,
  method signatures, enums and event handlers) —
  `help.sap.com/doc/1639cb9ccaa54b2592224df577abe822`
- SAP Analytics Cloud Help: analytic applications / optimized story experience scripting
- Productive planning implementations and SAP training material (the defect checklist in §11 is
  drawn from both).
