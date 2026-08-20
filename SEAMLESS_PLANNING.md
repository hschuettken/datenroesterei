# Seamless Planning — SAC Planning on SAP Datasphere

> The architecture, the prerequisites, and the restrictions that decide whether it fits.
> Compiled from SAP Help (SAC and Datasphere, current at Q3 2026), SAP Community material,
> SAP Notes and KBAs, plus first-hand observation on a productive tenant.
> Companion to `SAC_KNOWLEDGE.md`, `DSP_KNOWLEDGE.md` and `DSP_PROGRAMMATIC_ACCESS.md`.
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

**Contents** — §1 what it is · §2 the architecture is inverted · §3 where the compute lands ·
§4 prerequisites · §5 live versions and currency · §6 the restrictions that bite ·
§7 sizing and noisy neighbours · §8 support routing · §9 when to use it, when not

---

## 1. What it is

SAP's term is **seamless planning** (the SAC admin page is *Data Storage for Planning*). It is
not a separate product or SKU — it changes **where an SAC planning model persists its data**.

SAP's own framing: *"SAP Analytics Cloud is responsible for the consumption, modeling and
visualization of the data, while SAP Datasphere handles the data storage"* — with SAC still
owning the run-time artifacts: views, tables, fact planning data, teams, currencies, units and
data access control security.

| When | Milestone |
|---|---|
| QRC4 2024 | controlled release |
| **QRC1 2025** | **general availability** |
| QRC4 2025 | External Live Version Data Sources — DSP fact views consumed as versions, no replication |
| QRC1 2026 | Data Import API for public dimension tables and private versions |
| QRC2 2026 | Data Export API; delta-calculation jobs in the Job Monitor |
| QRC3 2026 | reuse of Datasphere currency rate tables in seamless models; version dimension allowed in restricted calculations |

No Business Data Cloud licence is required, but SAP positions seamless planning as the planning
foundation inside BDC. Treat it as **the strategic target architecture** — SAP is unambiguous
about that — while scoping adoption against §6 and §9.

---

## 2. The architecture is inverted

**This is the single most important thing to understand, because almost everyone assumes the
opposite.** There is no connection *from* an SAC model *to* an existing Datasphere artifact.
Instead, **SAC provisions its own run-time tables inside a Datasphere space**, and those tables
are then exposed *back* into Datasphere.

At model creation you set *Data Storage Location = SAP Datasphere* and pick a **space** (per
model). Inside that space SAC then creates:

| Object | Technical shape |
|---|---|
| Hidden schema | `<SPACE_NAME>#SAC_<id>` |
| Fact table (published versions) | `sap.sac.<GUID>` |
| Private versions | `sap.fpa.services.epm.versions…` tables |
| Public dimensions | master-data tables plus a translation/text table |
| Hierarchies | materialise as `<namespace>::HIER_<DIM>` |
| Data point comments | **stay in SAC** — there are no comment tables in Datasphere |

All SAC-originated objects carry a `sap.sac` prefix, which makes them easy to recognise in the
space.

**Exposure is opt-in, per object** (Model Details → *Expose Fact Table / Dimension Table in SAP
Datasphere*). Exposed objects appear in the Data Builder as **read-only local tables** with
semantic usage Fact or Dimension. They can be used in graphical views, SQL views, data flows,
transformation flows and analytic models, and shared to other spaces. Datasphere modellers
**cannot** change their structure, delete them, or write into them.

⇒ The practical consequence for a project plan: *"we will point seamless planning at our
existing Datasphere model"* is not a thing that exists. Provisioning and — where the design needs
them — hierarchy rebuilds are their own workstreams.

---

## 3. Where the compute lands

Everything heavy runs on **Datasphere's HANA**, not on SAC. SAP:

> "Planning and modeling activities like publishing, running data actions, importing data etc.
> are running on SAP Datasphere's database and consume memory and CPU power there. … SAP
> Analytics Cloud's tenant size is not a performance-relevant factor for seamless planning
> models."

Data actions and advanced formulas execute as **`CALL` procedures** on the Datasphere HANA.

**Observability is the part teams are unprepared for: planning activity does not appear in the
Datasphere task logs.** The practical trace is the expensive-statements view:

```sql
SELECT * FROM M_EXPENSIVE_STATEMENTS
WHERE SCHEMA_NAME LIKE '%#SAC_%' AND OPERATION = 'CALL'
```

(Datasphere timestamps are UTC while the UI shows local time — an easy way to misattribute a
run.)

**There is no write-back from Datasphere into plan data.** Transformation flows cannot write into
the SAC-owned tables. Every load path into the plan goes through the SAC APIs
(`SAC_APIS.md` §2).

⇒ Sizing, monitoring and data-residency conversations belong on the **Datasphere** side of the
house, not the SAC side. That reassignment surprises people late in a project if it is not made
explicit early.

---

## 4. Prerequisites — all mandatory, all hard gates

- SAC tenant on **SAP HANA Cloud** infrastructure (Cloud Foundry; the legacy infrastructure is
  not supported). *Documentation discrepancy:* the formation page mentions HANA 2.0 while the
  seamless-planning prerequisite pages say HANA Cloud only — treat HANA Cloud as the gate.
- SAC and Datasphere in the **same data centre and the same landscape**.
- The **same SAML identity provider and the same subject name identifier**.
- A **strict 1:1** tenant relationship — no fan-out, no multi-tenant. SAP: *"there is no timeline
  for potential enrichment in this area."*
- Established as a BTP **formation** or as a tenant link in SAC *System → Administration → Data
  Storage for Planning*, by the system owner of both tenants.
- **Unlinking requires deleting every model, public dimension, currency table and data action**
  stored on the Datasphere side first. Plan the link as a one-way door.

---

## 5. Live versions and currency

**External Live Version Data Sources** (QRC4 2025) bind a version to a Datasphere fact view
exposed for consumption — from the model's own space or shared into it. No replication.

- ✅ usable in model calculations, story calculations and data actions including advanced
  formulas; feeds predictive; copyable into planning versions
- ✅ **Datasphere Data Access Controls are honoured** — the row security travels
- ❌ **not writable**
- ❌ **no self-reference** — a live version cannot be based on a view over the model's own fact
  table
- ❌ live **master data** is not yet available (SAP calls it a high-priority future enhancement)

**Currency** (QRC3 2026): Model Preferences → Conversion → *SAP Datasphere* selects the standard
currency view, which must already exist and be populated in the model's space. A client ID is
mandatory; rate types are pre-populated from the rate table. A shared rate table from another
space works by pointing the local view at the shared space.

---

## 6. The restrictions that actually bite

SAP's own words: **"seamless planning is still under development."** These are current at Q3 2026
and worth re-verifying against the release you are on.

### Lifecycle

- **No migration tooling.** SAP: *"it is currently not possible to migrate existing SAP Analytics
  Cloud models, dimensions or currency rates tables to SAP Datasphere spaces."* Brownfield means
  rebuild. **This is the single largest adoption cost** and the reason to scope greenfield-first.
- **Content transport drops the exposure setting** — fact and dimension tables lose their
  *exposed* flag when transported. Re-verify after every import.
- Model deletion has its own KBA (3633125) — it is not a plain delete.

### Functional

- **Account models are not supported** — standard/measure-based models only. An account
  *dimension* inside a standard model is fine; a classic account model is not. Check this before
  promising a migration path for an existing estate.
- **Input Tasks are not supported** (use the SAC Calendar instead).
- **Classic Design Experience is not supported** — Optimized only.
- **Hierarchies are not exposed to Datasphere** and must be rebuilt natively there. That creates
  a real risk of **semantic drift** between the hierarchy the planner sees in SAC and the one the
  report uses in Datasphere — put a reconciliation check in the QA plan.
- **Local (model-private) dimensions are not exposed** — only public ones.
- **The same-space constraint**: shared public dimensions, currency rate tables and cross-model
  data actions require the objects *and* the models to live in the same space, and you cannot
  cross-model-copy between an SAC-stored and a Datasphere-stored model. This pushes a design
  toward one large planning space, which fights Datasphere space governance. SAP says it is
  actively working to reduce the space dependency.
- **Data Export Service: audit tables are not supported** for seamless models — and the DES
  endpoints generally are not usable against them (`SAC_APIS.md` §3). Export through the in-app
  data-change export or read the data on the Datasphere side.
- **Comments live in SAC** and are therefore invisible to Datasphere-side consumers.

### A field-observed defect worth knowing about

Creating or saving a **public Account dimension** with Datasphere as the storage location has
been observed to fail outright (SAP KBA **3782435**, status "under investigation", no workaround
at the time of observation). The error message exposes the cross-schema architecture directly: a
lookup joins the SAC tenant modelling schema against the model's generated space container and
fails to resolve the former. Generic and local public dimensions are unaffected.

The compounding detail: in a Datasphere-storage model the Add-Dimension dialog offers only
Generic/Date/Timestamp for embedded dimensions, so **Account exists only as a public dimension** —
which means the obvious "make it non-public" workaround is not selectable. Where this blocks a
go-live, the fallback is an SAC-local model for that scope.

**The general lesson, independent of this specific KBA:** seamless planning is GA but still
maturing. Build a fallback position into the plan for any model on the critical path, and
validate the specific dimension shapes you need early rather than at integration time.

---

## 7. Sizing and noisy neighbours

- SAP: *"minimal SAP Datasphere configurations may be too small for planning scenarios, even with
  few concurrent users."*
- **SAP Note 3564858** covers Datasphere tenant configuration for planning use cases. As a rough
  starting point it puts **>100 concurrent planners** at the order of **512 GB memory / 64 CPU
  cores** — SAP disclaims the accuracy of that figure, so treat it as a scoping anchor, not a
  quote.
- Per seamless-planning space, Workload Management caps apply — **100 % total thread limit,
  90 % total memory limit**.
- **Noisy-neighbour risk is new.** Planning bursts now contend with Datasphere ETL and reporting
  on the same HANA. That coupling did not exist when planning ran on the SAC tenant, and it means
  the publish peak at a planning deadline lands on the same machine as the nightly load. Size and
  schedule for the collision.

The general rule from `SAC_KNOWLEDGE.md` §12 still applies and matters more here: the private
version a data action materialises is bounded by the **planning area**, and the planning area has
to be set on the table. On shared infrastructure an unbounded materialisation is no longer just
your own problem.

---

## 8. Support routing

SAP KBA **3515100** splits the components: tenant link, identity provider and HANA migration go
to the SAC administration component; space access, and the data storage location, to the
Datasphere components; the planning functions to their own. Expect a degree of ping-pong between
them, and record which component a given symptom belongs to before opening the incident.

Other relevant notes and KBAs: **3564858** (tenant configuration for planning), **2832606**
(unsupported features on live connections), **3633125** (model deletion), **3574577**
(trusted-origins collision), **3782435** (the Account dimension defect in §6).

---

## 9. When to use it, and when not

**Use it when** SAC (on HANA Cloud) and Datasphere are both in place, in the same data centre,
behind one identity provider; the model is **greenfield**; plan data has to be consumed
downstream; large actuals already live in Datasphere; the roadmap points at Business Data Cloud;
SQL and Datasphere skills are available; and the design is a **standard model on the Optimized
Design Experience**.

**Do not use it (yet) when** the design needs an **account model**, Input Tasks or the Classic
Design Experience; there is a large existing SAC estate to migrate; the landscape is N:M or
multi-tenant; SAC runs on the legacy infrastructure; the design leans on Datasphere-consumable
**hierarchies**, local dimensions or live master data; **write-back** from Datasphere into plan
data is needed; the Datasphere tenant is minimally sized or already saturated; or governance
mandates strict space separation.

**The consulting stance that follows:** target architecture yes, wholesale migration no. New
models on Datasphere persistence, existing models left where they are until migration tooling
ships — and **Datasphere sizing, space design and hierarchy rebuild as explicit, budgeted
workstreams** rather than assumptions.

---

## 10. Sources

- SAC Help — *About Seamless Planning*; *Understand SAP Analytics Cloud Planning Data Storage
  Configuration in SAP Datasphere*; *Configure Data Storage for Planning*; *Create a Planning
  Model with Data Storage in SAP Datasphere*; *Expose Objects for Consumption in SAP Datasphere*;
  *About Live Data Access*; *Create and Reuse Currency Conversion Tables*
- Datasphere Help — *Integrate with SAC for Planning*; *Store and Consume SAC Data in SAP
  Datasphere*; *Consume Data in SAC via a Live Connection*
- SAP Community — seamless planning product FAQ; *Understanding Seamless Planning*; *Unlocking
  the Next Chapter of Seamless Planning* (live versions); *Monitoring the Resource Consumption of
  Seamless Planning in SAP Datasphere*; quarterly What's New
- SAP Notes / KBAs — 3515100, 3564858, 2832606, 3633125, 3574577, 3782435
- First-hand observation on a productive tenant (§6) — SAC 2026.8 / Datasphere 2026.15 era.
