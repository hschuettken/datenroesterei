# Datenrösterei

Notes and tools from productive SAP data-platform work — **SAP Datasphere**, **SAP Analytics
Cloud planning**, and **ABAP** — published because the things that cost the most time are rarely
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

---

## What is here

### [`datasphere-sac-field-guide/`](datasphere-sac-field-guide/) — seven documents, ~3,100 lines

A working reference for building and operating SAP Datasphere and SAC planning. Modeling
knowledge and programmatic access are kept apart on purpose: the modeling files are read front to
back, the access files are opened when a specific question comes up.

| Document | Covers |
|---|---|
| `DSP_KNOWLEDGE.md` | architecture, artifact types, view design, HANA SQL quirks in DSP, persistence, space design, integration, performance, security, deployment, semantics & hierarchies |
| `DSP_PROGRAMMATIC_ACCESS.md` | OAuth and the identity model, the CLI, consumption OData, Open SQL Schema, writing data, orchestration, design-time & monitoring APIs, transport |
| `SAC_KNOWLEDGE.md` | planning models, data actions, advanced formulas in depth, allocations, multi actions, performance, pitfalls, authoring a data action end to end |
| `SAC_APIS.md` | the four SAC access planes, OAuth, Data Import/Export, Content Network, SCIM, the DES protocol, InA, import-job automation |
| `SAC_SCRIPTING.md` | the scripting language and its limits, the API catalogue, filters, hierarchy format, master-data CRUD, the planning API, utility classes |
| `SEAMLESS_PLANNING.md` | SAC planning persisted in Datasphere: the inverted architecture, prerequisites, the restrictions that decide feasibility, sizing |

Start with [the guide's own README](datasphere-sac-field-guide/README.md).

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

SAP, SAP Datasphere, SAP Analytics Cloud, SAP NetWeaver and ABAP are trademarks of SAP SE. This is
independent work with no affiliation to or endorsement by SAP.
