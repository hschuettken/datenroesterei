# SAC hierarchy automation — creating and filling dimension hierarchies programmatically

Field notes on creating, modifying, deleting and **filling** parent-child hierarchies on
SAP Analytics Cloud dimensions without touching the Modeler UI, using the internal FPA REST
layer (`/sap/fpa/services/rest/…`) with a plain browser session. Companion script:
[`create_fill_hierarchy.py`](create_fill_hierarchy.py).

This document is written to be **self-contained for an LLM agent**: everything needed to
execute the flow — auth, endpoints, payload shapes, ordering, constraints, verification, and
the failure modes that look like success — is in this one file.

> **Status and caveats.** The FPA layer is *internal, undocumented, unsupported* API — the
> same calls the SAC web UI makes. It can change with any quarterly release. Everything below
> was field-verified in productive work (2026-07); re-verify against your release. And know
> what the supported alternative can and cannot do: the official **Data Import Service**
> (`/api/v1/dataimport/…`, OAuth client required) covers recurring fact and master-data loads,
> but **hierarchy content is not part of its documented API** (see §7) — for hierarchy trees,
> the routes are the UI import or this FPA layer.

---

## 1. The mental model

Two separate things make up a hierarchy in SAC, and they are created in two separate steps:

1. **The hierarchy definition** — an entry in the dimension's `hierarchies[]` array
   (name, type `parent_child` or level-based, description). Created via a dimension update.
2. **The tree itself** — *not* stored in the definition. It lives in the **members**: each
   member carries a parent pointer per parent-child hierarchy, filled from a **parent column
   of the source data during a master-data import** whose mapping binds that column to the
   hierarchy.

So the flow is always: *declare the hierarchy on the dimension → map a parent column onto it
in an import → load master data → the tree exists.*

There is **no patch API** anywhere in this layer. Every modification is
read-the-full-definition → modify → write-the-full-definition-back, with an optimistic-lock
version number.

## 2. Auth: browser session + CSRF handshake

No OAuth client is needed. All calls ride on the **session cookie of an authenticated SAC
browser session** (copy the full `Cookie` header from dev tools, or execute the calls as
same-origin `fetch` from an authenticated tab).

Before any write, fetch a CSRF token and send it on every subsequent request:

```http
GET /sap/fpa/services/rest/epm/session?action=logon
x-csrf-token: fetch
→ 200, response header x-csrf-token: <token>
```

Some tenants require the tenant GUID as a query parameter on **every** FPA call
(`?tenant=<GUID>`); others work without it. The GUID is visible on any FPA request in the
browser's network tab. When in doubt, send it — it is harmless where unneeded.

## 3. The four rules that prevent the expensive mistakes

1. **`action` goes in the request body, never the query string.** The FPA services take a
   JSON envelope `{"action": "<verb>", "data": {…}}`. Putting `?action=readObject` in the
   URL returns **400 with an empty message** — a silent failure that is very easy to
   misread as a permissions or payload problem.
2. **The package namespace is tenant-specific** (`t.XX`, `t.10`, `t.B`, …) — never
   hardcode it. Resolve it first:
   ```http
   POST /sap/fpa/services/rest/epm/contentlib
   {"action":"getResourceEx","data":{"resourceId":"<any object id>"}}
   → {"objectId":"DIMENSION:<package>:<id>", …}
   ```
   A wrong package returns `500 OBJECT_NOT_FOUND` phrased like a permission error
   ("…or you do not have permissions…") — it is usually just the wrong package.
3. **Unknown action verbs return 500** `{"message":"Method X was not implemented"}` — not
   404. A 500-method-error means *right endpoint, wrong verb*, and it also proves your auth
   works.
4. **Errors can arrive as HTTP 200** with an `error` field in the body. Always check the
   body, not just the status code.

## 4. Creating (and removing) a hierarchy definition

### 4.1 Read the dimension

```http
POST /sap/fpa/services/rest/epm/objectmgr
{"action":"readObject","data":{
  "p1":{"name":"<DIM>","type":"DIMENSION","package":"<PACKAGE>"},
  "p2":false,
  "p3":{"bUseTempService":true,
        "resourceOptions":{"metadata":{"name":true,"description":true},"accessMode":1}}}}
```

Response: `data` holds the dimension (`type`, `capability`, `properties[]`,
`hierarchies[]`, `defaultHierarchy`, plus read-only extras); the **optimistic-lock version
is `metadata.version`**, *not* inside `data`.

Important asymmetry: for **dimensions** the read `properties[]`/`hierarchies[]` are
**write-valid** as-is. (For *stories* the readObject projection is read-only and replaying
it fails validation — do not generalize from stories to dimensions or vice versa.)

### 4.2 Write it back with the new hierarchy

Build the write payload from the read: keep `type`, `isLocal`, `capability`,
`properties` (all, unchanged), `hierarchies`, `defaultHierarchy`; set `isEmbedded:false`;
**drop the read-only extras** (`mode`, `packageName`, `schemaName`,
`masterDataTableName`, `memberCount`, `restNode`, …). Append the new entry:

```http
POST /sap/fpa/services/rest/fpa/dimension
{"action":"update","data":{
  "id":{"type":"DIMENSION","name":"<DIM>","package":"<PACKAGE>"},
  "version": <metadata.version from the read>,
  "data":{ …full write payload…,
    "hierarchies":[ …existing…, {
      "hierarchy":"<HIER_NAME>",
      "hierarchyType":"parent_child",
      "description":"<desc>", "descriptions":{"en":"<desc>"},
      "isMandatory":false, "levels":[], "nodeStyle":null,
      "hierarchyViewName":"\"TENANT_<NS>\".\"<PACKAGE>:<DIM>//hier/<HIER_NAME>\""
    }]}}}
→ 200 {"notificationID":"…"}
```

- **Parent-child**: `hierarchyType:"parent_child"`, `levels:[]`. The tree comes later from
  the import (§5).
- **Level-based**: same call, but with a populated `levels:[…]` array where each level
  references a property of the dimension.
- `hierarchyViewName` follows the auto-derived convention
  `"TENANT_<NS>"."<package>:<dim>//hier/<name>"`.

**Guards before firing** (assume a productive tenant): assert the property count is
unchanged, the ID property is still first, and `hierarchies[]` has exactly the expected
length. **Verify after**: re-read → `metadata.version` bumped, `status:"valid"`,
`hierarchies` as expected, property count and member count intact. A hierarchy-definition
change leaves members untouched. SAC keeps object version history, so a bad write is
recoverable.

### 4.3 Removing a hierarchy

Same read-modify-write: filter the entry out of `hierarchies[]` — and **fix
`defaultHierarchy`** if it pointed at the dropped one, or the save leaves a dangling
default. Dropping a hierarchy definition does not delete members.

## 5. Filling the tree — mapping + master-data load via `fpa/wrangling`

Precondition: the source is **staged** — an import job (connection + query) exists for the
dimension. Creating that job programmatically is possible but involved; the pragmatic route
is to create it once in the Data Management UI and capture the ids (`sFileId`,
`connectionId`, `queryId`, `queryName`) from the network calls. From then on everything is
API. Three calls, all `PUT`, all to `/sap/fpa/services/rest/fpa/wrangling`:

**Step 1 — get the column map.** The staging layer names columns `HEADER<n>`; get the
mapping to real source-column names:

```json
{"action":"setInitialDataForDimension","data":{"p1":{
  "sDimensionId":"<DIM>","sFileId":"<SFILE_ID>",
  "useFirstRowAsHeader":false,"workflow":"IMPORT_MASTER_DATA"}}}
→ mappingData.sourceColumns[] = [{"name":"<COL>","tmpColumnName":"HEADER9"}, …]
```

**Step 2 — map columns to attributes, one call per column, sequentially.** The key column
maps to the ID attribute; the **parent column maps to the hierarchy**:

```json
{"action":"changeDimensionMapping","data":{"p1":{
  "changeInfo":{
    "attribute":{"type":"HIERARCHY","compoundType":"HIERARCHY",
                 "id":"<HIER_NAME>","hierarchyType":"parent_child"},
    "column":"HEADER<n>"},
  "sFileId":"<SFILE_ID>","sDimensionId":"<DIM>","sTmpColId":"HEADER<n>"}}}
```

(Key column: `"attribute":{"type":"ID","compoundType":"ID","id":"ID","isMandatory":true}`.
Plain attributes: `"type":"PROPERTY"`. To undo a wrong auto-mapping add
`"removeMapping":true` to `changeInfo`.) Notes from the field:

- **Map by domain knowledge, not by name** — localized attribute names don't auto-match
  English source columns; supply the explicit map.
- Attributes with no matching source column: leave unmapped. Empty beats wrong.

**Step 3 — start the load** (async server-side):

```json
{"action":"importMasterData","data":{"p1":{
  "sFileId":"<SFILE_ID>","sDimensionId":"<DIM>","sPackage":"<PACKAGE>",
  "aAcquisitionPayloads":[{"fileId":"<SFILE_ID>","acquisitionPayload":{
    "wranglingMethod":"HANA","connectionId":"<CONN>","queryId":"<QID>",
    "queryType":1,"queryName":"<QNAME>","payloadVersion":"1.0","schedulable":1}}],
  "sFileName":"<QNAME>","hierarchyValidationToOmit":{}}}}
→ {"newMappingCreated":true}
```

Poll `POST /fpa/member {"action":"query", …}` for `Data.totalMembersCount` — immediately
after the load it reads `1` (just the `#` member), then jumps to the full count when the
async load lands.

## 6. Constraints that decide your design (learned the hard way)

- **Cross-hierarchy leaf rule (hard, enforced at fact import).** A member that is a
  **parent in *any* parent-child hierarchy** of a dimension **cannot carry fact data**. A
  second hierarchy in which the same member is a leaf does *not* rescue it — the fact
  import rejects with `"<DIM>, Must be leaf node in hierachy, <member>"` (SAP's typo
  included). Consequence: two parent-child hierarchies can never give you both
  "book on X" and "roll up detail under X" on the same dimension. Options: keep only the
  hierarchy where the bookable member is a leaf and model the detail view as an
  **attribute + filter**, or put it on a separate reporting dimension. **Level-based
  hierarchies don't create booking-blocking parents** (the grouping is an attribute on the
  leaf, not a member-parent) — often the right choice for a pure roll-up view.
- **The `#` (unassigned) member** works flat, but **breaks as a node in a parent-child
  hierarchy**. Use an explicit `UNASSIGNED`-style leaf instead of parenting things
  under `#`.
- Fact rows must land on members that **exist** and are **stored** (not calculated)
  **leaves** — the three reject classes you'll see are "must be leaf node", "member does
  not exist", and "cannot use calculated measure".
- Naming collisions during migrations: dimension/hierarchy names that are **prefixes of
  each other** (e.g. `Customer` vs `Customer_V2`) make naive search-and-replace on
  definition JSON destructive. Count occurrences first, replace with word boundaries or
  longest-first, and re-count before writing.

## 7. Alternatives, for completeness

| Route | Supported? | When |
|---|---|---|
| Modeler UI | ✅ | one-off manual work |
| Master-data import wizard (parent column in mapping) | ✅ | tree content, manual |
| **Data Import Service** `/api/v1/dataimport` (OAuth client) | ✅ | recurring automated loads of fact data and master-data **attributes** — but **no hierarchy import**: parent-child trees are absent from the documented API and its changelog (the export side has `…MasterWithHierarchy`; import has no counterpart) |
| Internal FPA API (this document) | ❌ unsupported | scripted structural work, one-offs, migrations |
| Story scripting (Analytics Designer) | ✅ but can only *switch* the displayed hierarchy (`setHierarchy`) | never for creating/changing |
| Live models (Datasphere/BW/HANA/S4) | — | hierarchies are **not editable in SAC at all**; change them in the source |

## 8. The script

[`create_fill_hierarchy.py`](create_fill_hierarchy.py) implements §2–§5 end to end with
placeholders for tenant, cookie, package, dimension, hierarchy and staging ids. It refuses
to run if the hierarchy already exists, guards every write, and verifies by re-reading.
Python 3.9+, `requests` only.

---

Part of [Datenrösterei](../README.md) — SAP field notes by Henning Schuettken. Not
affiliated with or endorsed by SAP. Documentation CC BY 4.0, code MIT.
