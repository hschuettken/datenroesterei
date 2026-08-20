# SAP Datasphere & SAP Analytics Cloud — Field Guide

*Part of [Datenrösterei](../README.md).*

A working reference for building and operating **SAP Datasphere** and **SAP Analytics Cloud
planning** — the parts that are hard to find in the official documentation because they only
show up once you have shipped something.

It is deliberately weighted toward **failure modes that are silent**: the call that returns
HTTP 200 and does nothing, the data action that completes successfully and writes nothing, the
export that looks complete and is missing everything past the page cap, the import that reports
zero rejects and loads the wrong rows. Those cost the most time and are the least documented.

Seven documents, ~3,100 lines. Modeling knowledge and programmatic access are kept apart on
purpose: the modeling files are the ones you read front to back, the access files are the ones
you open when a specific question comes up.

**What this is.** Field notes from productive SAP Datasphere and SAC consulting work, compiled
by Henning Schuettken from SAP's official documentation plus
project experience across several implementations. Non-obvious behaviour was verified against
live tenants and reviewed for accuracy before publication.

**What this is not.** Not official SAP documentation, not affiliated with or endorsed by SAP.
Both products ship quarterly and behaviour changes — anything marked "currently", and every
measured limit, should be re-verified against your release. Where a claim is a field observation
rather than documented behaviour, the text says so. Corrections and additions are welcome via
issue or pull request.

**No customer-specific information.** Every example is generalized; object names, tenants and
identifiers are placeholders.

---

## The files

| File | What is in it | Read it when |
|---|---|---|
| **`DSP_KNOWLEDGE.md`** | 4-layer architecture, artifact types, view design patterns, HANA SQL quirks in DSP, persistence strategy, space design, data integration, performance, security, deployment, associations / texts / semantic types / hierarchies | you are modelling in Datasphere |
| **`DSP_PROGRAMMATIC_ACCESS.md`** | OAuth and the identity model, the Datasphere CLI, consumption OData, HANA Open SQL Schema, writing data, orchestration, design-time and monitoring APIs, transport & content packages, Datasphere ↔ SAC, browser-driven automation | you are automating, integrating or operating Datasphere |
| **`SAC_KNOWLEDGE.md`** | planning model fundamentals, data actions and their step types, advanced formulas in depth, allocations, multi actions, performance, pitfalls, model-type migration, field-tested gotchas, authoring a data action end to end | you are building or reviewing SAC planning logic |
| **`SAC_APIS.md`** | the four SAC access planes, OAuth, Data Import / Data Export / Content Network / SCIM, the Data Export Service protocol, InA, import-job automation, the internal FPA REST layer and why it is not an integration path | you are integrating SAC with anything |
| **`SEAMLESS_PLANNING.md`** | SAC planning persisted in Datasphere: the inverted architecture, where the compute lands, the mandatory prerequisites, live versions and currency, the restrictions that decide feasibility (no account models, no migration tooling, hierarchies not exposed), sizing and noisy neighbours, and a use-it/don't-use-it call | you are deciding whether — or how — to run SAC planning on Datasphere |
| **`SAC_SCRIPTING.md`** | what the SAC scripting language can and cannot do, the full API catalogue, filter reading, hierarchy format, master-data CRUD, running actions synchronously vs in the background, the planning API (versions, private-version housekeeping, data locking), the utility classes, a maintainability layering and a review checklist | you are writing or inheriting story / analytic-application scripts |

## If you only read five things

1. **Datasphere ties data access to an identity and its roles, never to OAuth client scopes.**
   Which is why the OAuth client's *purpose* decides whether an integration can work at all: an
   API-Access client 403s on all data, a Technical User client with a scoped role is the
   headless path. `DSP_PROGRAMMATIC_ACCESS.md` §1.1.
2. **Deploy does not run the query.** Views whose preview would hang deploy fine — skip the
   preview, validate with bounded queries. `DSP_KNOWLEDGE.md` §5.
3. **Advanced formulas are declarative, not imperative**, and `RESULTLOOKUP` does *not* aggregate
   over unmentioned dimensions — the opposite of BPC FOX. `SAC_KNOWLEDGE.md` §5.0.
4. **A data-action parameter that is not wrapped in `BASEMEMBER` narrows silently** when it is
   empty: it collapses to the unassigned member, not to "everything". `SAC_KNOWLEDGE.md` §12.
5. **HTTP 200 is not a success signal** on several of these APIs — some failures answer 200 with
   an HTML login page, others accept a payload and ignore it. Test the body; verify with a counted
   read.

## The two SAP reference guides worth bookmarking

These documents are a field companion, not a replacement for SAP's own references. Two are worth
having open alongside:

- **Advanced Formulas Reference Guide** — the complete function grammar for data-action scripting
  (`help.sap.com/doc/5516580733124039b673c530125771b3`). Note it documents syntax in BNF-style
  notation rather than worked examples; `SAC_KNOWLEDGE.md` §5 supplies the mental model and the
  behaviour the grammar does not describe.
- **Optimized Story Experience API Reference Guide** — the complete class catalogue for story and
  analytic-application scripting, published per release
  (`help.sap.com/doc/1639cb9ccaa54b2592224df577abe822`). `SAC_SCRIPTING.md` maps it and adds the
  patterns and failure modes.

## Conventions in these documents

- `§n` refers to a section of the same file; a reference across files names the file explicitly.
- Code is illustrative, not copy-paste-ready for your tenant — object names, namespaces and model
  ids are placeholders in angle brackets.
- ⚠️ marks something that fails silently. Those are the ones worth reading twice.

---

## License

[CC BY 4.0](../LICENSE) — reuse and adapt freely, with attribution.

SAP, SAP Datasphere and SAP Analytics Cloud are trademarks of SAP SE. This is an independent
work and carries no affiliation with or endorsement by SAP.
