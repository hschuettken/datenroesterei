# SAP Datasphere — Programmatic Access, APIs & Operations

> Companion to `DSP_KNOWLEDGE.md` (architecture, modeling, SQL, persistence, semantics).
> Everything here was verified against live tenants.
> Field notes from productive SAP Datasphere / SAP Analytics Cloud work.
> No customer-specific information.

**Contents** — §1 OAuth, CLI (incl. SQL views, analytic models, Open-SQL tables, folders),
consumption APIs, Open SQL Schema, writing data, orchestration ·
§2 design-time & monitoring APIs, reading data the Data Viewer's way, operating a bulk deploy ·
§3 transport & content packages · §4 Datasphere ↔ SAC · §5 browser-driven automation

## 1. Programmatic Access — OAuth, CLI and the API planes

There are **four distinct access planes** into Datasphere, and they authenticate differently.
Confusing them is the single biggest time sink when automating DSP:

| Plane | What it reaches | Auth |
|---|---|---|
| **CLI / public REST** (`/dwaas-core/api/…`) | spaces, objects (design time), users, task chains, DB users | OAuth 2.0 bearer, **user context** |
| **Consumption OData** (`/api/v1/datasphere/consumption/…`) | data of exposed views and analytic models | OAuth 2.0 bearer |
| **HANA Open SQL Schema** | the underlying HANA, real SQL | HANA database user (host/port/user/password) |
| **Design-time & monitor REST** (`/deepsea/…`, `/dwaas-core/monitor/…`, `/dwaas-core/tf/…`) | CSN, lineage, run status, persistence triggers | the **browser session cookie** of a logged-in user |

### 1.1 OAuth — the part that decides whether automation is possible at all

**Client creation** (needs *DW Administrator*): **System → Administration → App Integration**
→ *Add an OAuth Client*.

**There are three purposes, and picking the wrong one is the most common reason an integration
cannot be made to work at all:**

| Purpose | Grant | Identity the token carries | Use it for |
|---|---|---|---|
| **Interactive Usage** | `Authorization Code` (fixed) — 3-legged, a human logs in at the IdP | acts **as the logged-in user**, with that user's roles | the CLI, OData consumption where a human logs in (SAC, Power BI), Connections and Marketplace REST APIs, content transport. **Redirect URI required.** Access token 60 min and refresh 30 days *by default* — both configurable (§1.1) |
| **Technical User** | `Client Credentials` (fixed) | creates a **real technical user** (ID ≤ 20 chars, A–Z/0–9/_) to which you assign **global and/or scoped roles** — so it can be restricted to specific spaces | **the headless path**: unattended OData consumption, most CLI commands, the schedules/tasks REST API, SCIM, content transport, audit export. No redirect or authorization URL. Secret expiry 3 months by default (7 days–20 years); token lifetime 1 day |
| **API Access** | choice of `Client Credentials` or `SAML 2.0 Bearer` | **tenant-wide privileges** — SAP's documentation states this verbatim ("An API Access purpose provides tenant-wide privileges"); there is no space scoping | admin plumbing only: SCIM 2.0 user provisioning, transport (Analytics Content Network). An "Access" selector picks which of those the client may call |

**Rule of thumb:** human in the loop → *Interactive Usage*. Unattended data consumption from a
job, a pipeline or a middleware → **Technical User with a scoped role limited to the target
space** — this is the option to design for in a regulated environment, because the identity is
named, role-restricted and auditable. User-provisioning middleware → *API Access*, which is the
purpose SAP documents for the SCIM API.

> Both *Technical User* and *API Access* can reach SCIM and content transport. Prefer the
> **Technical User** wherever it works, precisely because API Access is the unscoped one: give
> tenant-wide privileges only to the integration that genuinely needs tenant-wide reach (user
> provisioning), and scope everything else.

- **Redirect URI**: `http://localhost:8080` is the conventional choice, but tenants differ —
  some clients are registered against an SAP-hosted callback page instead. Whatever is
  registered must be sent verbatim in the authorize call, or XSUAA answers
  *"redirect_uri does not match the configuration"*.
- **Token lifetimes are configurable, and the defaults are not the ceiling.** The dialog
  defaults to 60 min access / **720 h (30 days) refresh**, but SAP documents the refresh-token
  lifetime as settable from 60 seconds up to **180 days**. Raise it deliberately if you are
  running an Interactive Usage client and want fewer re-authentications — and weigh that against
  the security review, because a long-lived refresh token is a long-lived credential.
- **The client secret is displayed exactly once** at creation. Capture it immediately.
- The tenant's authorize/token endpoints are printed at the top of the App Integration page:
  `https://<tenant>.authentication.<region>.hana.ondemand.com/oauth/{authorize,token}`.

> **In One Tenant Mode** (DSP and SAC sharing a URL) the administration UI is served inside a
> same-origin iframe — relevant only if you automate the page itself.

**The scope insight — why a bare `client_credentials` client gets 403 on everything.** Datasphere
ties data access to a **user identity and that identity's space/role membership**, never to OAuth
client scopes. That single rule explains all three outcomes:

| Client | The token represents | Result against the core service |
|---|---|---|
| **API Access** with `client_credentials` | the OAuth client itself — it holds no DW roles at all | **403 on everything** (`spaces list` returns "failed to return a list of existing spaces") — measured |
| **Technical User** with `client_credentials` | a real technical user carrying the global/scoped roles you assigned | **200**, access exactly per those roles |
| **Interactive Usage** with `authorization_code` | the logged-in human, with their roles | **200**, full access per those roles |

⚠️ The failure mode to recognise: an API-Access client is the one most people create first
(because "API" is in the name), and it is the one that cannot read data. If a
`client_credentials` token 403s on everything, the fix is almost never more scopes — it is the
wrong client purpose.

**What this means for architecture:**

- **Headless is available** — via a *Technical User* client with a scoped role. Design unattended
  integrations on that, not on a stored human refresh token.
- **The CLI's interactive flow is a different trade-off.** An Interactive Usage client acts as a
  named human, which is convenient for development and for anything that should inherit a
  modeller's rights. Its cost is the manual re-authentication: **the refresh token does not renew
  itself past its configured lifetime** — when it expires, both the refresh POST and the next API
  call return 401, and the only recovery is repeating the interactive step. At the 30-day default
  that means roughly monthly per tenant; the interval is a configuration choice, not a product
  property, so set it consciously rather than inheriting it.
- **Secrets expire on their own schedule too.** A Technical User client's secret carries an
  expiry date set at creation. Whatever the exact renewal mechanics on your release — verify them
  in the tenant rather than trusting a second-hand number, including ours — the operational point
  holds: **an unattended integration stops working on a date nobody wrote down.** Record the
  expiry in the same calendar that holds certificate renewals, and monitor for 401s on the
  integration rather than discovering it from a business user.
- One documented functional limit: a Technical User driving the CLI **cannot start task chains
  that contain BW bridge process chains**.

**Technical User — three things that cost a demo day** (all measured on one tenant, three
client creations before the consumption API answered 200):

- The technical user **does not appear under Security → Users**. It exists only as the
  client's identity; roles are assigned **at the client**, in the App Integration dialog.
- **Global roles give no space data** — not even *DW Administrator*. Only a **scoped role**
  assigned at the client opens the consumption API for that space. (A scope prompt may not
  appear; the assignment works anyway.)
- Diagnose a 403 by **decoding the JWT first**: an API-Access token carries `apiaccess` and an
  SAC user scope but **no `user_name` claim** — that is the signature of "wrong purpose", and no
  amount of extra scopes changes it. A client created with grant *SAML 2.0 Bearer* answers
  `Unauthorized grant type` to `client_credentials`; it needs an assertion, not a secret.

**PKCE varies per client.** Some registered clients require `code_challenge` /
`code_challenge_method=S256` in the authorize call plus the matching `code_verifier` in the
exchange; confidential clients elsewhere work without it. Read the client's configuration
before assuming a flow copies over from another tenant.

**Manual code exchange** (no local listener needed — useful in remote-browser or locked-down
setups):

```bash
# 1. authorize URL, opened in a browser session that is already SSO'd into the tenant
#    https://<tenant>.authentication.<region>.hana.ondemand.com/oauth/authorize
#      ?response_type=code&client_id=<urlencoded client_id>[&code_challenge=…&code_challenge_method=S256]
# 2. with a live SSO session it redirects straight to <redirect_uri>/?code=XXXX — read the code
#    from the address bar (the redirect target itself does not need to serve anything)
# 3. exchange it immediately — auth codes are SINGLE-USE with a TTL of seconds
curl --tlsv1.2 -X POST "$TOKEN_URL" \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode code="$CODE" \
  --data-urlencode redirect_uri="$REDIRECT_URI" \
  -u "$CLIENT_ID:$CLIENT_SECRET"
# → { access_token, refresh_token, expires_in, scope: "… uaa.user …" }
```

Later refreshes are a plain `grant_type=refresh_token` POST against the same endpoint.

**The browser session is NOT a bearer token.** Checked on live tenants: `localStorage` and
`sessionStorage` hold nothing token-like, and the only auth cookie is httpOnly and
session-scoped. The browser's role in this flow is purely **SSO passthrough** — it silently
approves the authorize request for an *already registered* client. It is not a way around
needing one.

**Two transport gotchas:**
- **TLS**: some network paths to the SAP endpoints reject TLS 1.3 (`SSL alert 70`,
  `tlsv1 alert protocol version`). Pin TLS 1.2 (`--tlsv1.2`, `--tls-version TLSv1.2`) when that
  happens — it is path-specific, so don't apply it blindly.
- Every CLI command prints a trailing deprecation `WARNING` to stdout **after** the JSON. Strip
  it before parsing.

### 1.2 The Datasphere CLI

`@sap/datasphere-cli` (npm, binary `datasphere`) is the robust path for everything design-time —
no renderer, no timing, reproducible, diff-able.

```bash
npm config set prefix ~/.npm-global && npm i -g @sap/datasphere-cli
datasphere login -H "$HOST" -c "$CLIENT_ID" -C "$CLIENT_SECRET" \
  -A "$AUTH_URL" -T "$TOKEN_URL" -a "$ACCESS_TOKEN" -r "$REFRESH_TOKEN" \
  -d authorization_code --force          # seed from tokens; no browser needed
datasphere spaces list -H "$HOST"
```

The command tree is **dynamic** — before login only `config`/`login`/`logout` appear. After
login: `spaces`, `objects`, `tasks`, `users`, `dbusers`, `marketplace`, `global-roles`,
`scoped-roles`, `workload`, `configuration`, `job-status`.

- `objects` branches by artifact type — `views`, `local-tables`, `remote-tables`,
  `analytic-models`, `task-chains`, `data-flows`, `replication-flows`, `transformation-flows`,
  `data-access-controls`, `business-entities`, `fact-models`, `consumption-models`,
  `intelligent-lookups`, `ontologies`, `contexts`, `types`, `services`, `er-models` — each with
  `list` / `read` / `create` / `update` / `delete`.
- `create` / `update` take `-F <file>` or `-I <json>` and **deploy by default**; `-N/--no-deploy`
  saves without deploying, `-S/--save-anyway` saves despite validation messages, `-f` allows
  missing dependencies.
- `spaces`: `create`/`read`/`delete`/`list`/`connections`/`users`. `tasks`: `chains`
  (`run`/`cancel`/`retry`), `logs`, `consent` (needed for scheduled/automated runs),
  `replication-flows`. `dbusers`: the HANA Open SQL Schema user plane (§1.4).
- `--verbose` prints the HTTP exchange plus the correlation id — the fastest way to get a
  support-grade trace.

**Graphical views are fully representable in the CLI.** A common misconception is that the
graphical modeler is UI-only. It isn't: `objects views read` on a join-built view returns the
complete CQL query tree — join node, on-condition, projection/mapping — not just the output
columns:

```json
"query": { "SELECT": {
  "from": { "join": "inner", "args": [{"ref":["SRC_A"]},{"ref":["SRC_B"]}],
            "on": [{"ref":["SRC_A","Date"]}, "=", {"ref":["SRC_B","DATE_UTC"]}] },
  "columns": [ {"ref":["SRC_A","Date"]} ] } }
```

Combined with deploy-by-default `create`/`update`, this makes the CLI a genuine alternative to
the canvas for scripted or bulk changes — and a far stronger verification tool than "does the
object exist", because you can diff the exact join/filter/mapping tree against intent. Still
worth verifying per case: whether modeler-only node types (currency conversion, rank, hierarchy
association, restricted measures) round-trip cleanly.

**Two practical notes.** `spaces read` returns *space metadata* (storage, RAM, auditing), not an
object export — use `objects <type> list/read`. And `objects views read` returns the **deployed**
SQL, which is exactly why it is the right verification source: a file copy in a repository can
be out of date with what is actually running.

**A local table can be created from CSN**, which is the cleanest way to script a target table:

```json
{"definitions":{"<NAME>":{"kind":"entity",
 "@ObjectModel.supportedCapabilities":[{"#":"DATA_STRUCTURE"}],
 "@ObjectModel.modelingPattern":{"#":"DATA_STRUCTURE"},
 "@EndUserText.label":"<NAME>",
 "elements":{"MATNR":{"type":"cds.String","length":18,"key":true,"notNull":true},
             "VALUE":{"type":"cds.Decimal","precision":15,"scale":3}}}}}
```

⚠️ **A SQL view created through the UI comes out as `DATA_STRUCTURE` with no consumption
exposure — SAC then cannot see it at all.** Fix it by reading the view, patching the JSON and
updating:

```
"@ObjectModel.modelingPattern"        : {"#":"ANALYTICAL_FACT"}
"@DataWarehouse.consumption.external" : true
elements.<key columns>                : "key": true, "notNull": true
```

**What the CLI does NOT do: ad-hoc SQL.** There is no `datasphere query`. Data access is the job
of the consumption APIs (§1.3) or the Open SQL Schema (§1.4).

#### SQL views through the CLI — the empty-shell trap

⚠️ `datasphere objects views create` with **only the SQL text** in the CSN creates an **empty
shell**: it reports `Saved and deployed`, builds no `query` tree, and the view returns **0 rows,
forever**, with no error anywhere. A SQL view needs `query` (the CQN tree) **and** `elements`
(the typed column list) in the CSN — exactly what the SQL editor produces before it saves. The
editor does it in three calls, all on the browser session (§2):

| # | Call | Role |
|---|---|---|
| 1 | `POST /dwaas-core/cdssql/buildcqn` `{"sql": "…"}` → `{status, sql, csn}` | the SQL→CQN compiler; `csn` is the bare `{SELECT:…}` / `{SET:…}` tree |
| 2 | `POST /dwaas-core/metamodel/<folderGuid>/validate-csn` | validation only, skippable |
| 3 | `POST /dwaas-core/deploy/<SPACE>/base` `{folderId, folderGuid, spaceName, name, content:{definitions:{…}}}` | **saves and deploys**, and returns real compiler errors |

`folderGuid` is mandatory on call 3, is **always the space's GUID** (never a folder's — a folder
GUID there yields `403 User must have DWC_DATABUILDER authorization privilege`, which reads like
a missing right and is only the wrong value), and no API returns it: read it once off the
`validate-csn` URL in the browser's network log and cache it. The public CLI endpoint
(`/api/v1/spaces/<S>/views?deploy=true`) saves correctly but answers only `Failed to deploy` on
UNION views, which is why call 3 is the one to script.

**Do not derive `elements` yourself — let HANA describe the query.** A deployed view with
`@DataWarehouse.consumption.external: true` is readable from the Open SQL Schema (§1.4): create a
throw-away view, read `SYS.VIEW_COLUMNS`, drop it. Deploy a chain bottom-up and each stage can
describe itself against the previous one. Mind the scale trap when you do
(`DSP_KNOWLEDGE.md` §4.18: `SCALE` is `NULL` for computed decimals — never map it to 0).

#### Analytic models through the CLI

`datasphere objects analytic-models create -F <csn>.json` works, and the CSN needs **both
halves**: `definitions.<AM>` (`ANALYTICAL_CUBE` plus a query on the fact) and
`businessLayerDefinitions.<AM>` (`factSources`, `attributes`, `measures`). Reverse-engineer the
shape from an existing model (`objects analytic-models read`). The traps, in the order they were
hit:

1. **Elements must not carry a `type`** — only `@EndUserText.label` (plus `measureType` on
   measures). With a `type`, `create` fails and DSP reports a **misleading
   `409 ObjectAlreadyExists`**, even for a freshly invented name. The same 409 appears when
   association elements (`cds.Association`) are copied into the model — skip them.
2. **`update` works — but only with `--technical-name`.** Without the flag it looks broken, which
   is how a "delete + create" habit starts. That habit is **expensive**: delete + create gives
   the model a **new object id, and every story bound to it loses its binding** — the crosstab
   then shows axis headers and nothing else, with no error. Rule: model exists → `update
   --technical-name`, otherwise `create`.
3. The view underneath must be `ANALYTICAL_FACT`, not `DATA_STRUCTURE`, with element annotations
   (`@Analytics.dimension`, `@Semantics.currencyCode` / `.unitOfMeasure`,
   `@AnalyticsDetails.measureType` + `@Aggregation.default` + `@Semantics.amount.currencyCode`).
   **Numeric non-measures** (sort orders, indent levels) must be marked as dimensions
   explicitly, or they become summable measures in SAC.
4. Four more that **the deploy survives without complaint** — visible only in the UI, never as
   an error: measures need `measureMapping`, not `sourceKey`/`key` (otherwise the model **no
   longer opens in the modeler** — blank canvas, no message); a dimension source needs a
   duplicated, hidden key attribute with `usedForDimensionSourceKey`; a calculated measure needs
   its formula **twice** (flat `xpr` **and** `formulaRaw`/`formula`/`elements`); a multi-part
   dimension needs a `representativeKey`.
5. **`update` does not deploy when nothing changed in content** — return code 0, empty output,
   "Deployed On" unchanged. After a dimension change, press Deploy in the UI.
6. **Compound dimensions** (multi-column `on` conditions) require **every left-hand column to
   carry the same name in the target** (`MISSING_DEPENDENCY: <DIM>#<COLUMN>`) — rename in the
   node, do not duplicate. And DSP refuses to remove a column while any view reads it
   (`NOT_MODIFY_IN_USE`), so a rename is a **two-stage rebuild**: deploy every view in the chain
   with *both* names, switch consumers top-down to the new name, then remove the old one
   bottom-up. The same lock means: when a model uses a view's association, **redeploy the
   models first, then the view**.
7. A new column in a *source table* must be **re-registered** (re-imported) before a view can
   reference it, or the view deploy answers `MISSING_DEPENDENCY: <TABLE>#<COLUMN>`.

#### Tables in the Open SQL Schema are invisible to the space

Data loaded into the space's Open SQL Schema (§1.4) does **not** appear in the Data Builder, and
no view may reference it — the deploy fails with `depends on following missing objects`.
Datasphere knows only **space objects**. The route: one local table per source table whose CSN
points at the existing one —

```json
{"definitions":{"<NAME>":{"kind":"entity",
 "@ObjectModel.modelingPattern":{"#":"DATA_STRUCTURE"},
 "@DataWarehouse.external.schema":"<SPACE>#<DBUSER>",
 "@DataWarehouse.external.entity":"<NAME>",
 "elements":{ … }}}}
```

— created with `objects local-tables create`. Tables first, then views.

#### Folders: not a CLI concept

There is no `folders` command, no `--folder` option, and the object CSN carries no folder —
folder membership is **repository metadata**. New objects therefore land in the **space root next
to the customer's objects** and are noticed when somebody opens the space. Assigning happens on
the internal repository route (`POST /deepsea/repository/<SPACE>/objects/`, §2.1), and
`parent` / `folderAssignment` expect the **technical folder name**, not its GUID — an unknown
value is silently ignored and the object stays in the root. After every scripted run, list the
objects and check where they went.

### 1.3 Consumption APIs (OData)

Two endpoints, both bearer-authenticated:

```
/api/v1/datasphere/consumption/relational/<SPACE>/<VIEW>      # views exposed for consumption
/api/v1/datasphere/consumption/analytical/<SPACE>/<AM>/<AM>   # analytic models (entity set = AM name)
```

- The **analytical** endpoint answers row-level `$select` / `$top` reliably. Its
  `$apply=groupby(…)/aggregate(…)` grammar differs from the relational one and has been seen to
  return null measures or a 400 — for a quick "does the AM carry the right numbers" check,
  row-level plus client-side summing is enough; verify the aggregate syntax per release before
  relying on it.
- The internal *instant* data-access path cannot compile an analytic model (`SETUP_CAP_FAILED`,
  "CDS compilation failed") — AMs are consumed through the analytical API or through InA, which
  is the protocol SAC itself uses.
- **These endpoints need the bearer token; browser cookies return 401.** That is the practical
  dividing line between the two access planes — with one useful exception: `$metadata`.
- **`GET …/consumption/analytical/<SPACE>/<AM>/$metadata` with `Accept: application/xml`
  (JSON → 406) is the cheapest health check an analytic model has.** It answers 200 or 500 per
  model, in seconds, from the logged-in browser session, and it is the same path SAC takes when
  it fails with "contact your administrator" plus an unresolvable correlation id. Run it after
  every model change; the classic 500 is a hierarchy node with two validity slices
  (`DSP_KNOWLEDGE.md` §12.6).

### 1.4 HANA Open SQL Schema — real SQL access

Each space can expose a **database user** (Space Management → *Database Access → Database
Users*, or the CLI's `dbusers` branch). That yields a HANA host/port/user/password usable from
any HANA client (`hdbsql`, Python `hdbcli`, JDBC tools). Objects become visible to that schema
only when they are **exposed for consumption**.

This is the plane to use for genuine ad-hoc analysis, for bulk extraction, and for connecting
third-party tools. Two operational notes from the field: the space's database-user password
policy is enforced on rotation, and a service that restarts in a loop with a stale password will
**lock the HANA user** — recovery is an administrative password reset, not a retry.

### 1.5 Writing data into a local table

**The supported route is the public local-table API with an OAuth bearer token** (§1.1 — a
Technical User client is the right fit for an unattended writer). Design any recurring load on
that, or on a Replication Flow / Data Flow, which is what those artifacts exist for.

> ⚠️ **What follows is the internal route the Data Editor itself uses.** It authenticates on a
> **user session cookie**, it is undocumented, and it is a **write** interface — so it carries
> the same objections as any unsupported plane: no compatibility guarantee across releases, no
> technical-identity audit trail, no SAP incident path. It is documented here because the Data
> Editor has no CSV import and one-off corrections otherwise mean typing rows by hand. Treat it
> as an attended, ad-hoc tool for a developer fixing test data — **never** as part of an
> unattended job, and never on production data without the same change control you would apply
> to a manual edit.

```
POST /dwaas-core/data-access/instant/<SPACE>/<TABLE>/$batch
Content-Type: multipart/mixed;boundary=batch_id-xyz
  → inner: POST _<TABLE> HTTP/1.1  with a JSON body of the row
  → delete by key: DELETE _<TABLE>(K1='…',K2='…')
```

- All values as **strings**, decimals included. No CSRF token needed with a session cookie.
- ⚠️ **DSP executes only the FIRST operation of a `$batch`** when the operations are not wrapped
  in a changeset — and still answers HTTP 200. A batch of 20 rows writes exactly one. Send **one
  operation per batch in a loop**; it is fast enough (dozens of rows in seconds).
- An existing key returns `400 "Entity already exists"`, which makes the loop easy to make
  idempotent.

### 1.6 Orchestration — task chains, flows and scheduling

Task chains are the scheduler-facing unit in Datasphere: they wrap view persistence, data flows,
replication flows and other chains into one runnable object. Everything about them is scriptable:

```bash
datasphere objects task-chains list   --space <S>          # inventory
datasphere objects task-chains read   --space <S> --technical-name <C>
datasphere objects task-chains create --space <S> -F chain.json     # deploys by default
datasphere tasks chains run    --space <S> --technical-name <C>
datasphere tasks chains cancel --space <S> --technical-name <C>
datasphere tasks chains retry  --space <S> --technical-name <C>
datasphere tasks logs list | get | get-extended
datasphere job-status get
```

**The consent gotcha:** scheduled and automated runs require a **scheduling consent** to be on
file for the user whose identity the schedule runs under (`datasphere tasks consent get / give /
revoke`). Consent expires. When a chain that has run for months suddenly stops firing without any
change to its definition, check consent before debugging the chain — this is a recurring and
easily misdiagnosed outage.

**Design principles that matter more than the API:**

- A chain is only as fresh as its **weakest upstream**. Persistence inside a chain runs in the
  chain's order, but nothing verifies that the source replication actually delivered new data
  first — check the freshness of the sources (§2.2), not just the chain's own status.
- **Prefer one chain per consumable output** over one big chain per space: a failure in an
  unrelated branch should not block the artifact somebody is waiting for, and retry granularity is
  the whole point of the object.
- Status from the monitoring endpoints (§2.2) is the honest source; the UI's green tick reflects
  the last *run*, not the currency of the data.

---

## 2. Design-Time & Monitoring APIs (session-authenticated)

Everything below is reachable with `fetch(…, {credentials:'include'})` from a logged-in browser
session — no OAuth client involved. This is the fastest way to audit a tenant, and the only way
to read some things at all. Outputs are large (a single space's CSN is 300 KB+, a recursive
dependency tree 450 KB+) — filter server-side or in-page rather than pulling everything.

### 2.1 The repository (design-time truth)

```js
// per-space object list incl. the full CSN
fetch('/deepsea/repository/<SPACE>/designObjects?details=name,%23repairedCsn')
// dependency graph — upstream lineage or downstream impact
fetch('/deepsea/repository/dependencies/?ids=<OBJID>&recursive=true&level=20'
    + '&impact=false&lineage=true&details=%23spaceName,qualified_name,%23objectStatus')
// full column list of one entity, even at 87 columns (the Data Viewer shows ~20)
fetch('/deepsea/repository/<SPACE>/versions?kind=entity&name=<T>&details=version&top=1')
fetch('/deepsea/repository/<SPACE>/version?version=<n>&technicalName=<T>')
```

- `designObjects` lists a space's **own** objects only — objects shared *into* it are not
  included.
- Semantic usage appears as `@ObjectModel.modelingPattern.#`: `ANALYTICAL_DIMENSION`,
  `ANALYTICAL_FACT`, `ANALYTICAL_CUBE` (= Analytic Model), `LANGUAGE_DEPENDENT_TEXT`,
  `PARENT_CHILD_HIERARCHY_NODE_PROVIDER` (hierarchy with directory), `DATA_STRUCTURE`.
- Associations are elements of `type:"cds.Association"` with `{target, on, label}`; classify the
  association kind by the *target's* modeling pattern.
- A view's SQL also sits in `@DataWarehouse.sqlEditor.query`.
- **`inaccessibleDependencies` is the sharing check**: empty at every node of the dependency
  tree = every reference resolves. Non-empty = something referenced isn't shared, which is
  exactly the failure mode described in `DSP_KNOWLEDGE.md` §12.0 — and it is checkable in one call instead of by
  clicking through Space Management.
- `#objectStatus`: `1` = deployed, `2` = redeploy needed, `0` = never deployed.
- Object kinds in `designObjects?details=name,kind`: `entity`, `sap.dwc.taskChain`,
  `sap.dis.replicationflow`, `sap.dis.dataflow`, `sap.dwc.analyticModel`, `sap.dwc.dac`.

### 2.2 Monitoring — freshness without clicking

```
/dwaas-core/monitor/<SPACE>/taskchains                          last run per task chain
/dwaas-core/monitor/<SPACE>/persistedViews?mode=persistedOrWithRuns
        → dataPersistency, lastRunStatus, latestUpdate, numberOfRecords, replicationError
/dwaas-core/monitor/<SPACE>/remoteTables | localTables           incl. dpAgentState, dataAccess
/dwaas-core/dataflow/status?space=<SPACE>                        all data + replication flows:
        status, lastStarted/lastStopped (unix seconds), nextRun, activationStatus, cron
/dwaas-core/tf/<SPACE>/schedules?applicationId=<VIEWS|TASK_CHAINS|REMOTE_TABLES|DATA_FLOWS|REPLICATION_FLOWS>
```

⚠️ **"Running" on a delta replication flow does not mean "current".** Always cross-check on the
data side (`max(posting date)`, rows per posting day). A flow can sit in `Running` for days
while delivering nothing.

### 2.3 Triggering persistence without the monitor UI

```
POST /dwaas-core/tf/directexecute
     {"applicationId":"VIEWS","spaceId":"<SPACE>","objectId":"<VIEW>","activity":"PERSIST"}
     → 202 {"taskLogId": …}
GET  /dwaas-core/tf/<SPACE>/logs?objectId=<VIEW>&getLocks=true
GET  /dwaas-core/tf/<SPACE>/extendedlogs/<logId>
GET  /dwaas-core/monitor/<SPACE>/persistedViews/<VIEW>?includeBusinessNames=true
```

No CSRF token required — the session cookie is enough. ⚠️ When polling, evaluate **only the
newest log entry**; a naive search over the whole response matches an older `COMPLETED` and
reports "done" far too early. See `DSP_KNOWLEDGE.md` §5 for the failure semantics of the first PERSIST after a
deploy.

**What `directexecute` will and will not start** (same body shape, `activity` varies):

| `applicationId` / `activity` | Result |
|---|---|
| `VIEWS` / `PERSIST` | 202 `{taskLogId}` ✔ |
| `DATA_FLOWS` / `EXECUTE` | 202 ✔ — a first **502 Bad Gateway** can be transient; retry before reading it as a refusal |
| `TASK_CHAINS` / `EXECUTE` | **403 `insufficientPermission`** — "a task of this type cannot be triggered by this user". Starting chains stays an operator click (or the CLI's `tasks chains run` with a proper identity, §1.6) |

**A task chain's definition is not readable from the client.** `designObjects` returns metadata
only (`details=…,content` is ignored), `/dwaas-core/tf/<S>/taskchains/<id>` expects a **log id**
(a run, not the definition), and the editor keeps the graph in no reachable UI model. Nodes *and*
edges appear only in a run log — so verify a chain's structure with a test run:
`/dwaas-core/tf/<S>/taskchains/<logId>` returns `tasks[]` with `objectName`, `activity`
(`RUN_CHAIN` / `REMOVE_PERSISTED_DATA` / `PERSIST` / `EXECUTE`), `status`, `startTime`.

⚠️ **Log timestamps are UTC.** Against a CEST shell, a freshly started run looks like a hung node
for two hours. Check the timezone before diagnosing a stall.

### 2.4 Deleting an object

> ⚠️ **A destructive mutation on the internal plane** — unlike the rest of §2, which is
> read-only diagnostics. The supported way to delete an object is the CLI
> (`datasphere objects <type> delete`, §1.2) with a proper OAuth identity, and that is what
> should appear in any script. The route below exists in the notes because the UI's own delete
> path is awkward to drive; it is not an interface to build on.

```
DELETE /dwaas-core/repository/<SPACE>/objects/     body: {"object_id":"<GUID>"}
```

The GUID comes from `designObjects?details=name,id`.

### 2.5 Reading data the Data Viewer's way

The Data Viewer itself reads through an OData v4 endpoint on the browser session — useful when
the Data Export API is unwanted (it writes a log entry per export, which some customers object
to) and when all you need is a count:

```
GET /dwaas-core/data-access/instant/<SPACE>/<OBJECT>/_<OBJECT>?$format=json&$top=5
GET /dwaas-core/data-access/instant/<SPACE>/<OBJECT>/$metadata
GET …/_<OBJECT>?$apply=aggregate($count as n)                    # count server-side
GET …/_<OBJECT>?$apply=groupby((_<FIELD>),aggregate($count as n))
```

- **The leading underscore is the trap.** The second path segment is the *entity-set name*.
  Names starting with a **digit** — most of them in an SAP landscape (`04VR_…`, `03TR_…`) — are
  not valid OData identifiers, so DSP prefixes `_`. The same applies to **field names**
  (`0logsys` → `_0logsys`, `/BIC/HK_FTE` → `_BIC_HK_FTE`). Without the prefix: `400 Expected uri
  token 'ODataIdentifier' could not be found … at position 1`, which reads like a broken name.
  When in doubt, pull `$metadata` and read `<EntitySet Name>` / `<Property Name>`.
- 🔴 **Never measure in parallel.** `Promise.all` over several objects returns, on a server-side
  timeout, an **empty aggregate (`n: 0`) with HTTP 200** instead of an error. A parallel run
  reported 0 rows where a sequential one found 79,000, and every conclusion built on it was
  wrong. A `for` loop with `await`, and every relevant zero counter-checked with `$top=1`.
- On wide UNION views even `$apply` takes minutes or never returns — "no heavy previews" applies
  to aggregations too.
- The `/deepsea/…` routes (§2.1) are **metadata only**; every data path there is a 404.

### 2.6 Operating a bulk deploy

Notes from four full runs of ~200 views and ~25 analytic models in one day, each of which failed
for a different reason — **none of them in the data**:

1. **The `401` mid-run is not a session end — it is a token refresh.** Measured: `buildcqn → 401`
   at 22:31 took 18 views down with it; at 22:40 the **same session**, with nobody logging in
   again, answered the same call 200, and the 18 views went through 18/18. SAP renews the session
   token in the background, and calls during that window get 401. **Wait and retry** (four
   attempts, 20 s apart, worked) — and retry **only** 401: a `422 MISSING_DEPENDENCY` or SQL that
   HANA rejected fails the second time exactly the same way. Check the session in three seconds
   from the tab: `fetch('/dwaas-core/api/v1/spaces').then(r => r.status)` — 200 means alive.
   (An earlier version of this note said "the session lasts ~1 h, deploy in blocks"; that was
   wrong, and it is why a batch sat undeployed for days.)
2. **Never hardcode the browser tab id.** Chrome assigns a new one on every reopen; a stale id
   disguises itself as a deploy error (`no page target matching '…'`). Look the target up on
   `http://<host>:<port>/json/list` — and **when more than one tab matches, abort with the list
   rather than pick**: a deploy into the wrong space costs more than an abort, and it happens
   for real as soon as someone logs in twice.
3. **`NOT_MODIFY_IN_USE`** — redeploy the analytic models first, then the view (§1.2).
4. **Analytic models are a separate path.** A "deploy everything" that covers only views is not
   one; verify the consumption layer separately (the `$metadata` probe, §1.3).
5. **A hung deploy has a signature:** process alive, **CPU time 0**, no open connection, log
   frozen. The browser connection is gone and the deploy waits without a time limit. Kill it,
   take the deployed names from the log, re-run the rest by name.
6. **Persistence survives a redeploy without structural change** (`DSP_KNOWLEDGE.md` §5) — do
   not schedule a re-persist reflexively.
7. **Folders are not passed through** (§1.2) — check where the objects landed after the run.
8. After every model deploy, read the SAC-side dimension name — it is not deploy-stable (KBA
   3487607, `DSP_KNOWLEDGE.md` §13).

---

## 3. Transport, Lifecycle & Content Packages

- The transport container of both Datasphere and SAC is the **`.package` file** (Transport →
  Export → download; import = upload to the content repository, then Transport → Import). It is
  the same format SAP ships community content in; the `(1.0.0)` in the file name is its semver.
- **It is not CSN.** CSN is the readable model JSON from DSP/CAP — a different thing entirely.
- **`.package` files are encrypted, not merely compressed.** Measured on a real sample: no
  container magic bytes, Shannon entropy 7.9995 bit/byte, chi-square indistinguishable from
  random, no printable strings, no zlib/deflate/gzip stream, zero duplicate 16-byte blocks. So
  there is **no offline inspection, diffing or parsing** of a transport package. To see what is
  inside, upload it and stop before importing — the import dialog lists the contained objects,
  types and dependencies for confirmation. Do that on a sandbox tenant, not on production.
- Consequence for CI/CD: the versionable, diff-able artifact is the **CSN/CQL from the CLI**, not
  the package. A workable pattern is CLI export → Git → CLI apply, with the package reserved for
  whole-object moves between tenants. For Q→P propagation SAP's strategic tool is **Cloud
  Transport Management** integration.
- **Packages in DSP are single-space.** A "use case package" spanning several spaces does not
  exist; model cross-space dependencies as required packages per space.

---

## 4. Datasphere ↔ SAC

- A DSP OAuth token does **not** authenticate against SAC and vice versa. The two run separate
  XSUAA instances even when they share a tenant URL — SAC needs its own OAuth client created on
  the SAC host.
- SAC reads DSP analytic models over **InA**, not OData — either from the DSP host directly or
  proxied, depending on the tenant's wiring. When a story's numbers are in doubt, the honest
  comparison is: fact → analytic model (consumption API, §1.3) → story (InA), measured
  separately. That isolates the layer in one pass instead of arguing about the model.
- **Import connections into SAC** from DSP go through the DSP consumption OData endpoint, which
  means an OAuth client and a bearer token — see §1.1. A DSP view surfaces in that OData
  service with a **leading underscore** (`_MY_VIEW`), which trips up entity-name lookups.
- **Seamless Planning (SAC planning on Datasphere)** — summarised here, treated in full in
  **`SEAMLESS_PLANNING.md`** (architecture, prerequisites, restrictions, sizing, and when not to
  use it). The headline: **it binds in the opposite direction to what most people assume.** The SAC model does not bind to existing DSP artifacts. SAC provisions its own
  runtime tables in a hidden schema *inside* the chosen DSP space and exposes them back into DSP
  as read-only local tables, opt-in per object. Two consequences that shape a project:
  1. "Just point it at our existing Datasphere model" is not a thing — plan for provisioning.
  2. **Publishes, data actions and advanced formulas execute as procedures on the Datasphere
     HANA.** The SAC tenant size is not the performance factor; sizing, monitoring and
     data-residency discussions belong on the DSP side. Planning activity does **not** show up
     in the DSP task logs — it is visible in the HANA expensive-statement view filtered on the
     SAC schema and `OPERATION='CALL'`.
  Comments and hierarchies stay in SAC; DSP-side hierarchies have to be rebuilt natively.

---

## 5. Browser-driven automation — when it is the only option

On tenants where no OAuth client can be created (locked-down or remote-desktop-only access),
driving the UI is the remaining path. Three things are worth knowing before starting:

- **Deploy does not run the query** (`DSP_KNOWLEDGE.md` §5) — so the whole class of "the preview hangs" problems is
  avoidable by never previewing.
- **A hung preview can kill the automation channel**, not just the page: the renderer stops
  responding to evaluation and screenshots while URL and title still update. Recovery is a tab
  reload, sometimes with a wait before the first call.
- **Heavy monitor pages are a known renderer trap** — use the monitoring APIs in §2.2 instead of
  opening the Data Integration Monitor.
- **Synthetic clicks are untrusted.** `el.dispatchEvent(new MouseEvent('click'))` opens no
  popup, so every flow that depends on one — an SSO handshake above all — fails, with a message
  that looks like a server or authorization problem ("no access to the Datasphere spaces",
  "connection to the tenant failed"). The application's error text is no proof of the cause
  when the input itself was not real. Use real input (`Input.dispatchMouseEvent` over CDP, or
  a real automation framework's click); drag & drop additionally needs a dwell on the target or
  the drop lands nowhere, silently.
- **Address tabs by target id, never by URL substring**, as soon as more than one tab of the
  same tenant is open: a substring match takes the *first* hit, and on a shared browser that can
  be a colleague's story in edit mode. Open new tabs via `PUT /json/new?<url>` — it sidesteps
  the `beforeunload` dialog that navigating an unsaved tab triggers.
- **A crashed driver leaves its headless browser alive.** The next run with the same port and
  profile attaches to the *old* page, whose state has already advanced — "state nothing on the
  page could have set", instrumentation that never fires. Compare `performance.timeOrigin` with
  the run's start before debugging page state; give drivers a per-process port and profile plus
  a terminate-on-exit.

The stronger pattern in every case is **drive in one channel, verify in the other**: change
something in the UI and confirm it through the CLI or the repository API (or the reverse). Two
independent paths cross-checking each other catch the silent failures — a save that didn't
register, a deploy that didn't publish, a share that isn't in place.

---

## 6. Sources

- SAP Help — SAP Datasphere: App Integration and OAuth client purposes
  (Interactive Usage / API Access / Technical User), verified against the product documentation
- SAP Help — SAP Datasphere Command Line Interface (`@sap/datasphere-cli`)
- SAP Help — Consuming data via OData (relational and analytical consumption APIs), database
  users and Open SQL Schema
- SAP Note on Seamless Planning sizing (the Datasphere-side sizing deliverable, §4)
- Endpoint behaviour, error semantics and the operational gotchas were verified against live
  tenants. The design-time and monitoring routes in §2 are internal to the product: they are
  stable in practice but not part of a published contract — treat them as diagnostics, not as an
  integration interface.
