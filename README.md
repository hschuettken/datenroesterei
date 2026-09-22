# Datenrösterei

Notes and tools from productive SAP data-platform work — **SAP Datasphere**, **SAP Analytics
Cloud planning**, **SAP BW** and **ABAP** — published because the things that cost the most time are rarely
the things that are documented.

*Rösterei — a roastery. Raw beans are not a drink and raw tables are not a model; both need
someone to apply heat carefully and know when to stop.*

The common thread across everything here is **silent failure**: the API call that returns HTTP 200
and does nothing, the data action that completes successfully and writes nothing, the export that
looks complete and is missing everything past the page cap, the import that reports zero rejects
and loads the wrong rows. Those are the expensive ones, and they are the ones the official
documentation is quietest about.

Written and maintained by Henning Schuettken. Not affiliated with or endorsed by SAP.
Corrections and additions are welcome — open an issue or a pull request.

The reasoning behind these documents — why the silent-failure class matters more than the loud
one, and what each mechanism cost to find — is written up at **[Layer 8](https://layer8.schuettken.net)**.
This repository is the evidence; that is the argument.

---

## What is here

### [`datasphere-sac-field-guide/`](datasphere-sac-field-guide/) — seven documents, ~3,700 lines

A working reference for building and operating SAP Datasphere and SAC planning. Modeling
knowledge and programmatic access are kept apart on purpose: the modeling files are read front to
back, the access files are opened when a specific question comes up.

| Document | Covers |
|---|---|
| `DSP_KNOWLEDGE.md` | architecture, artifact types, view design, HANA SQL quirks in DSP, persistence, space design, integration, performance, security, deployment, semantics & hierarchies, design rules from the field |
| `DSP_PROGRAMMATIC_ACCESS.md` | OAuth and the identity model, the CLI (incl. SQL views and analytic models from CSN), consumption OData, Open SQL Schema, writing and reading data, orchestration, design-time & monitoring APIs, operating a bulk deploy, transport |
| `SAC_KNOWLEDGE.md` | planning models, data actions, advanced formulas in depth, allocations, multi actions, performance, pitfalls, asymmetric reporting, authoring a data action end to end |
| `SAC_APIS.md` | the four SAC access planes, OAuth, Data Import/Export, Content Network, SCIM, the DES protocol, InA, import-job automation |
| `SAC_SCRIPTING.md` | the scripting language and its limits, the API catalogue, filters, hierarchy format, master-data CRUD, the planning API, utility classes, custom-widget delivery |
| `SEAMLESS_PLANNING.md` | SAC planning persisted in Datasphere: the inverted architecture, prerequisites, the restrictions that decide feasibility, sizing |

Start with [the guide's own README](datasphere-sac-field-guide/README.md). Two walkthroughs of the
material: [Five ways SAP Datasphere tells you everything is fine](https://layer8.schuettken.net/datasphere-silent-failures/)
and [The data action ran green and wrote nothing](https://layer8.schuettken.net/sac-planning-writes-nothing/).

### [`abap-table-export/`](abap-table-export/) — `ZTABLE_EXPORT_CSV`

An ABAP report that extracts arbitrarily large SAP tables to chunked CSV files on the application
server. Built for tables in the billion-row class (ACDOCA and similar):

- **streaming cursor** (`OPEN CURSOR` + `FETCH … PACKAGE SIZE`) — constant memory regardless of
  table size
- **chunked output** by row count or file size
- **crash-safe checkpoint and resume** via keyset pagination on the primary key — a job that dies
  at 800 million rows continues where it stopped instead of starting over
- locale-independent numerics, configurable delimiter, enclosure and encoding
- runs on ABAP 7.02+ (NetWeaver 7.0 EHP2 and later)

The three design decisions behind it are written up in
[Exporting billion-row tables from ABAP](https://layer8.schuettken.net/exporting-billion-row-tables-from-abap/).

### [`bw-field-notes/`](bw-field-notes/) — classic BW and BW/4HANA, ~970 lines

Three documents on the ABAP side of the platform: the tables that tell you what a load actually
did (`RSBKREQUEST` / `RSPMREQUEST` and the rule of three: read → transferred → activated), the
suffix rules of generated tables, routine mechanics (`STATICS`, the global block, compounded
fields), the *overwrite vs. summation* defect that stays invisible until a source maps many rows
onto one key, activation-queue diagnosis, measurement rules for financial data, and the current
BW → Datasphere → Databricks paths. Plus ten symptom → cause → recipe entries for transformation
routines, and a reference for activating 2LIS extractors on the ERP side.

### [`sac-hierarchy-api/`](sac-hierarchy-api/) — hierarchies without the Modeler

A field guide plus Python script for creating, removing and **filling** parent-child
hierarchies on SAC dimensions via the internal FPA REST layer — browser session only, no
OAuth client. The README is written to be self-contained for an LLM agent: auth handshake,
payload shapes, the read-modify-write discipline (there is no patch API), and the
constraints that decide the design — above all the **cross-hierarchy leaf rule**, under
which a member that is a parent in *any* parent-child hierarchy can no longer carry fact
data. Unsupported API, clearly marked as such; the supported alternatives are listed
alongside.

---

## A note on what these documents are

They are **field notes**, not official documentation. Behaviour in both SAP Datasphere and SAP
Analytics Cloud changes quarterly, so anything marked "currently", and every measured limit,
should be re-verified against your release. Where a statement is a field observation rather than
documented behaviour, the text says so explicitly — that distinction is kept deliberately, because
the two age differently.

Everything is generalized: object names, tenants and identifiers are placeholders, and there is no
customer-specific information anywhere in this repository.

## License

- **Documentation** — [CC BY 4.0](LICENSE): reuse and adapt freely, with attribution.
- **ABAP source** — [MIT](abap-table-export/LICENSE).
- **Python source** — [MIT](sac-hierarchy-api/LICENSE).

SAP, SAP Datasphere, SAP Analytics Cloud, SAP NetWeaver and ABAP are trademarks of SAP SE. This is
independent work with no affiliation to or endorsement by SAP.
