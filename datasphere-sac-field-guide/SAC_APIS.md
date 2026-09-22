# SAC — Programmatic Access: APIs & Authentication

> Companion to `SAC_KNOWLEDGE.md` (planning model, data actions, advanced formulas) and
> `SAC_SCRIPTING.md` (story and analytic-application scripting). Everything here was verified
> against live tenants; SAC evolves quarterly, so re-verify limits before relying on them.
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

SAC has **no first-party CLI**; "SAC CLI" means these REST surfaces. There are four access
planes with genuinely different authentication and different support status — mixing them up is
the usual reason an integration "works in the browser but not from the job":

| Plane | Reaches | Auth | Supported |
|---|---|---|---|
| **Public REST APIs** (`/api/v1/…`) | data import, data export, content transport, users/teams | OAuth 2.0 client | ✅ documented, stable across releases |
| **Data Export Service** (OData) | model structure + fact/master data | OAuth 2.0 **or** a normal browser session | ✅ |
| **InA** (`/sap/bc/ina/service/v2/…`) | analytical queries, server-side aggregation — the protocol stories and Data Analyzer use | browser session + CSRF | ⚠️ internal protocol |
| **FPA REST layer** (`/sap/fpa/services/rest/…`) | everything the Modeler can do — models, dimensions, hierarchies, members, data actions, stories | browser session (user context) | ❌ unsupported (§6) |

## 1. OAuth — SAC has its own identity plane

**SAC's XSUAA instance is separate from Datasphere's**, even on tenants where both share a URL.
A DSP token does not authenticate against SAC and vice versa; SAC needs its own OAuth client,
created on the SAC host.

**Client creation:** *Administration → App Integration → Add an OAuth Client*. The dialog asks
for:
- **Name**
- **Purpose** — `Interactive Usage` (→ grant `Authorization Code`, needs a redirect URI) or
  `API Access` (→ grant `SAML 2.0 Bearer` or `Client Credentials`, plus a mandatory **Access**
  selection). The Access field picks **which API the client may call** (user provisioning, data
  import, …) — it is not a role object, so do not go looking for one in the role administration
- **Token / refresh lifetime** — defaults 60 min / 720 h

The **secret is shown once**. The tenant's authorize and token endpoints are printed on the same
page (`https://<tenant>.authentication.<region>.hana.ondemand.com/oauth/{authorize,token}`).

> ⚠️ **The purpose list is not the same as Datasphere's.** Datasphere additionally offers a
> **Technical User** purpose that creates a role-scoped technical identity — the clean headless
> path there (`DSP_PROGRAMMATIC_ACCESS.md` §1.1). Do not assume the same option exists on the SAC
> side of a tenant; read the dialog rather than transferring the Datasphere pattern, and re-check
> after a release upgrade.

**The auth gotcha that costs the most time:** like Datasphere, SAC ties data access to identity
and roles, not to client scopes alone. A bare `client_credentials` client is frequently rejected
for data APIs with `400 "OAuth Client is not allowed to …"` or an HTML auth-redirect body. The
client's **purpose and grant matter**, and for some APIs the client must additionally be
authorized against the specific provider/data source. Two practical consequences:

- **Test the body, not the status code.** A misconfigured call very often returns **HTTP 200
  with an HTML login page** in the body. Anything that only checks `res.ok` will report success
  forever.
- Budget for one round of "create the client with the right purpose and Access role" before
  estimating the integration itself.

**Three OAuth facts that are decisions, not tasks, in a productive tenant:**

- **The client secret cannot be rotated.** After creation it is neither visible nor changeable;
  SAP's own help says to delete the client and recreate it — which also changes the **client
  id**, so every consumer has to be reconfigured. There is no API for it either (the obvious
  `/api/v1/oauth/clients` and `/administration/oauthclients` paths answer 404; the XSUAA client
  routes need `uaa.admin`, which an API client does not carry). It stays a browser task under
  App Integration — plan it, do not discover it.
- **A `SAML 2.0 Bearer` client uses the alias token endpoint**
  (`/oauth/token/alias/<subaccount>.<landscape>`), not the plain `/oauth/token` printed on the
  page. Sending the assertion to the wrong one produces an error that looks like an
  authorization problem and is not.
- **A `client_credentials` client does work for the public REST APIs** where its purpose and
  Access selection allow it, and its token lives ~24 h — which makes it the first SAC access
  that does not depend on a browser session (the 25–30-minute session expiry is the most common
  failure of any longer automation on the internal planes, §4/§6).

**Host nuance:** the APIs are documented under the public analytics host
(`https://<tenant>.<region>.sapanalytics.cloud/api/v1/…`), but tenants on other SAP domains
expose them under their own host as well. Confirm the working base URL per tenant rather than
assuming. If the network path to SAP rejects TLS 1.3, pin TLS 1.2 (same symptom as on the
Datasphere side).

## 2. The supported public APIs

| API | Base path | What it does |
|---|---|---|
| **Data Import Service** | `/api/v1/dataimport/…` | push **fact data and master data** (attribute columns) into existing structures; jobs + validation. **No hierarchy import**: parent-child trees are not part of the documented API — note the asymmetry with the export side, which does have `…MasterWithHierarchy` |
| **Data Export Service** | `/api/v1/dataexport/…` | read model data and metadata as OData (§3) |
| **Content Network API** | `/api/v1/content/…` | export/import content packages — **the one supported way to move a changed model definition**, whole-object rather than delta |
| **SCIM** | `/api/v1/scim` (legacy), `/api/v1/scim2` (Cloud Foundry tenants only), `/api/v1/scim3` | users and teams CRUD; transport users/teams between tenants. **Three endpoint generations with different base paths** — pick deliberately; `/api/v1/scim` is the oldest, not the current one |

**SCIM — the two traps that delete the wrong thing** (verified against the current help):

1. **A team and a role are the same resource type** (`/Groups`). They differ only in the SAP
   extension: `urn:ietf:params:scim:schemas:extension:sap:2.0:Group → type` is `userGroup` for a
   team and `authorization` for a role. Code that filters by name and never checks the type will
   one day delete a role that happens to share a team's name. **The type is the ownership
   check.**
2. **Members are addressed by user UUID, not by user name** — and `members[].display` is the
   *display name* ("JANE DOE"), not the login. Both directions need a preloaded `/Users`
   directory.

Also: there is **no add-member endpoint** — membership changes are a `PATCH` on the group with
`op: add` / `remove`, **never `replace`** (which evicts everyone else). A `409` on create is a
name conflict, not proof of ownership and not a source for the id. The CSRF token is required
only on the browser domain; the direct API domain does not need it.

**The structural limit worth stating up front:** none of the supported APIs can *add a dimension
or change a formula in place*. Master data and facts are fully covered; model **structure**
changes go through the Modeler UI or through a package import that replaces the whole object.
Design accordingly — if structure has to change often, that is usually a signal that the
variable part belongs in master data, not in the model definition.

For a versioned, auditable pipeline the workable pattern is: keep the model definition in a
**content package**, store exports in Git, roll changes forward through the Content API import
job. Granularity is "whole package", not "one dimension". For tenant-to-tenant propagation SAP's
strategic tool is Cloud Transport Management.

> Content packages (`.package`) are **encrypted, not compressed** — no offline inspection,
> diffing or parsing. To see what a package contains, upload it and stop before importing; the
> import dialog lists the contained objects and dependencies.

## 3. Data Export Service — the protocol in detail

Reads model **structure and data**, and it accepts a normal authenticated browser session as
well as an OAuth token — which makes it the practical read channel during development.

```
/api/v1/dataexport/administration/Namespaces('sac')/Providers   # provider list = models
/api/v1/dataexport/providers/sac/<MODEL_ID>/$metadata           # EDMX: the real dimension list
/api/v1/dataexport/providers/sac/<MODEL_ID>/FactData?$filter=…&$top=…
```

Entity sets per provider: `FactData`, `MasterData`, **`FactDataAggregation`**, plus one
`<Dim>Master` per dimension and `<Dim>MasterWithHierarchy` where a hierarchy exists.
`ProviderID` is the model id, `ProviderName` the display name — **two models can share a display
name**, so match on the id.

**Protocol is OData 4.0, GET only.** With a valid CSRF token, `POST …/$query` (the 4.01 long-filter
form) and `POST /$batch` both answer a clean **405 Method Not Allowed** — they are not
implemented. Without a token they answer 403, which reads like a permission problem and isn't.
Long selections must be split into several GETs and merged client-side.

**Authentication scope:** DES sits behind a **different approuter scope** than
`/sap/fpa/services/*`. The application session cookie does not carry over — every DES call from
an application tab returns HTTP 200 with an HTML login bounce. One **top-level navigation** to
any `/api/v1/dataexport/…` URL completes SSO silently, after which same-origin requests work. An
iframe fails (the identity provider forbids framing) and a popup is blocked.

**⭐ `FactDataAggregation` aggregates server-side.** `$apply=aggregate(…)` is **silently ignored**
on both entity sets — it returns plain rows, which is the trap that makes people page millions
of records and sum them in the client. But `FactDataAggregation` treats **`$select` as the
group-by** and returns SUMs at exactly that grain:

```http
GET FactDataAggregation?$select=Version,Amount&$count=true            → one row per version
GET FactDataAggregation?$select=Version,Date,Amount&$count=true       → version × date
GET FactDataAggregation?$select=Date,Amount&$filter=Version eq 'public.Actual'
```

The tell that this is real: `FactData` **rejects** a partial `$select` with
`400 Key column(s) not selected [1402]` — it demands the complete key — while
`FactDataAggregation` accepts it as the grain.

**Further verified quirks:**

- **`in`-lists are broken**: `$filter=Version in ('public.A','public.B')` →
  `500 SQL Statement cannot be prepared [1205]`. Use `or` chains. This matters precisely because
  `in` was the obvious way to keep long filters short.
- **Pagination has no `@odata.nextLink`** and the page cap is hard. A response can look complete
  and be missing everything past the cap. **Page with `$skip` until a page comes back short** —
  and **always add `$orderby` over the full grain**, because without it `$skip` is not
  deterministic and rows are duplicated or skipped between pages (the same failure mode as the
  import sort key in `SAC_KNOWLEDGE.md` §12). Measured cost of `$orderby`: none worth mentioning.
- `$count=true&$top=0` is a cheap size probe before a large pull; `$count` only works without a
  narrowing `$select`, and `/$count` as a path segment returns 406.
- Responses carry `@des.*` diagnostics (`entitiesInPage`, `totalNumberOfCells`,
  `processingTimeInMilliseconds`) — log them; they are the honest guard against silent
  truncation.
- **It returns raw fact records, not cells.** One cell carries several records from imports, data
  actions and manual entry — a factor of 30–40 between record count and populated cells is
  normal. Group before comparing against anything cell-based.
- Dates arrive as strings (`'202606'`); an unused time dimension can come back as `'0000'`.
  Master-data attributes appear on `FactData` as `<Dim>___<Attribute>` (three underscores).
  Unmapped import columns show up as `'#'` — a sudden surge of `#` is a **mapping** symptom.
- **Every DES query is logged.** For high-frequency verification during development, InA (§4)
  is the lighter channel.
- For **Datasphere-backed (seamless) planning models the DES endpoints are not usable** — export
  through the in-app data-change export, or read the data on the Datasphere side.

## 4. InA — the analytical query protocol

InA is what stories and the Data Analyzer speak. Its advantage over DES is that it **aggregates
server-side**, so a verification query returns finished sums instead of hundreds of thousands of
rows.

```
POST /sap/bc/ina/service/v2/GetResponse
Headers: Content-Type: application/json, x-csrf-token: <token>     # without the token: 403
```

The request body is large (a capabilities block plus the query definition). The practical way in
is to capture one real request from the Data Analyzer and use it as a template, then replace
only two things: `Analytics.Definition.Dimensions` (per dimension `{Name, Axis:'Rows'|'Columns'}`,
plus the measure on the columns axis) and
`Analytics.Definition.DynamicFilter.Selection.Operator.SubSelections` (one `SetOperand` per
filter, with `FieldName` and `Elements:[{Comparison:'=',Low:<value>}]`).

**Field-name spelling is decisive** and differs by dimension type — a flat dimension is
`<DIM>.ID`, a hierarchical one is `[<DIM>].key` plus a `Hierarchy` block with member paths like
`[<DIM>].[<hier>].&[<member>]`, and the measure is `[Measures].[Measures]`.

**Three traps that produce plausible wrong numbers:**

1. **`ReadMode:"Booked"` is the magic value** for "which members actually carry data".
   `"Master"` returns all members regardless of data; most other spellings fail with an explicit
   "read mode must not be of type …" message that helpfully names the check.
2. **The row grid must contain every dimension the measure varies over.** A ratio test that
   omitted one distribution-channel dimension produced a factor of 0.02 instead of 1.0 — the
   numerator aggregated correctly while the denominator summed across ten channels. Justify the
   grid before believing the deviation.
3. **`RowTo` defaults to 150** in a captured template. A query over 719 members returned 16 and
   an understated total, with no warning. Raise it *and* check the returned row count against
   the limit — a result landing exactly on the limit is a truncation, not an answer.

Read results at the top level (`Grids[0].Cells.Values.Values`); the row labels sit in
`Grids[0].Axes[…].Tuples[k].TupleElementIds.Values` as **one array per dimension**, not per row,
so row *i* is assembled from position *i* of each array. Also strip `HierarchyNavigations` and
`Sort` from a captured template, or you inherit somebody's drill state.

## 5. Automating import jobs

> ⚠️ **Read §6 before building on this section.** The verbs below belong to the **internal,
> session-authenticated plane** — the same one §6 argues against as a production interface, for
> the same reasons (no compatibility guarantee, user-session authentication, no SAP incident
> path). They are documented here because they are what the UI itself calls and because they are
> genuinely useful for attended build and operations work, **not** because they are sanctioned.
>
> **The supported path first:** for loading data on a schedule, use the **Data Import Service**
> (`/api/v1/dataimport/…`, §2) with an OAuth client. It covers fact and master data into existing
> structures, with jobs and validation, and it is the interface to design an unattended
> integration on. Reach for the verbs below only for what the public API genuinely does not
> cover — re-running an existing UI-built job, and reading reject detail — and only under
> supervision.

| Action | API |
|---|---|
| **Run** an existing job | `dataintegration action=runScheduledJob` with the schedule id and mapping id |
| **Poll** status + counts | `dataintegration action=getScheduleLogsByModel` → newest `refreshLogs[]`; counts under `wranglingAndUpdateResult.data.{allCount,rejectedCount,insertedCount}` |
| **Read** a job definition | `dataintegration action=getMappingById` → update method, target model, mapping name |
| **Reject reasons as CSV** | `GET /wrangling/api/dm/executions/<executionId>/rejections?app=SAC` → `Source,Target,Issue,Value,Records` |
| **Create or copy** a job | ❌ **not possible** — `createMapping`/`saveMapping`/`copyMapping`/`duplicateMapping` all answer 400. The UI wizard is the only way. |

Status codes on a refresh log: `5` running · `1` complete, no rejects · `2` complete **with**
rejects (not "zero rows" — a run with over a million rows inserted and 61 rejects reports 2) ·
`3`/`4` cancelled/stopped.

**Two operational rules learned the hard way:**

- **The log entry lags the execution — by minutes on a large load.** A missing entry is *not*
  evidence that nothing is running. Fire once, then observe for at least 15 minutes before even
  considering a restart.
- **Never fire a second run while one is in flight** — both end up stopped. The schedule's own
  `status:"STOPPED"` is the *recurrence* status, not a live-run flag; the real live indicator is
  that the newest refresh log entry is not yet terminal. Guard on that before firing.
- Log timestamps are **UTC** while the tenant clock usually isn't — an easy way to mistake
  somebody else's run for your own.
- **Master data must be loaded before facts.** SAC only accepts fact rows whose dimension keys
  already exist as members. Otherwise the refresh "succeeds" and inserts **0 rows**.
- A master-data import job's **mapping screen cannot be re-entered** once the job exists. To
  remap columns or pick up a newly added attribute, the UI forces a completely new job.

## 6. The internal FPA REST layer — what it is, and why it is not an integration path

The SAC UI itself talks to `/sap/fpa/services/rest/…`, which can read **and write** everything
the Modeler can: models, dimensions, attributes, hierarchies, members, data actions, multi
actions, stories. It is real and it works — a complete planning model can be built end to end
through it without touching the UI.

**It is nevertheless not a production integration path, and in a regulated environment that
judgement should not be close:**

- no compatibility guarantee — SAP can change these endpoints in any quarterly release without
  notice, and nothing in the public documentation constrains them;
- authentication rides on a **user session**, not on a technical OAuth identity — exactly the
  audit-trail property a regulated environment does not want;
- no SAP incident path when it breaks;
- writes go through the same backend validation, but they produce no supported change record
  beyond the ordinary activity log.

The defensible use is **attended build and migration automation** under version control, where a
release break is visible immediately and costs a re-run rather than a production incident. Treat
it as an internal tool, never as an interface. Never place it in an unattended production job.

If you do use it, these mechanics are what actually cost time:

- **The verb goes in the BODY, not the query string.** `POST /epm/objectmgr {action:"readObject",
  data:{…}}`. Putting `?action=…` in the URL returns **400 with an empty message** — a silent,
  misleading failure. (One or two services are the exception and *do* take the action as a query
  parameter; verify per service.)
- **A missing `?tenant=<GUID>` produces a 200 that does nothing.** Same class of failure: the
  call reports success, the payload is ignored, nothing changes. When a write "succeeds" but has
  no effect, check the tenant parameter before rewriting the payload.
- **200 is not a success signal** on several verbs. Always verify against a counted read
  (member count, object version) rather than the response.
- **The package namespace is tenant-specific.** Objects live in a tenant namespace that differs
  per tenant; a hardcoded namespace returns "object not found or you do not have permissions",
  which reads like an authorization problem and is a wrong path. Resolve it first via the
  content library (`getResourceEx` → `objectId` = `<TYPE>:<package>:<id>`). Model-private
  ("embedded") objects live under `<namespace>.<modelId>`, public ones directly under
  `<namespace>` — that difference is precisely how you tell a shared dimension from a copy.
- **Writes are replace, not patch.** Updating one attribute means sending the complete property
  array. Read first, change one field, write the whole thing back — and compare the field set
  you read against the one the UI sends, or you silently drop attributes.
- **The read payload is not the write payload** for some object types (stories in particular
  return a read-only projection that fails write validation even as an unmodified round-trip).
  For those, the write shape has to come from a captured UI save, not from the read API.
- **Optimistic locking:** objects carry a version that must be sent back. An editor left open by
  a colleague holds a version — and, worse, **their next save overwrites your API change**.
  After any API write: reload the editor tab; before any API write: make sure nobody is in it.
- Most write verbs are **async** and return a notification id, so confirmation requires polling.
- **API writes bypass the editor's validation.** A data action written through the API is not
  syntax-checked until the editor opens it. The workflow is: write → reload → let the editor
  validate → read the messages.

---

---

## 7. Sources

- SAP Help: SAP Analytics Cloud REST API (Data Import Service, Data Export Service, Content
  Network API, SCIM), and the OAuth client / App Integration documentation
- SAP Help: Data Export Service OData service definition
- Protocol behaviour, status codes, pagination limits and the failure modes documented here were
  verified against live tenants; SAP may change internal endpoints (§6) without notice.
