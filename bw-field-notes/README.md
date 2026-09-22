# SAP BW — Field Notes

*Part of [Datenrösterei](../README.md).*

Three documents on classic SAP BW (7.4/7.5 on HANA) and BW/4HANA — the parts that are not in the
documentation because they only show up once a load has run and the numbers are wrong.

Like the rest of this repository, the notes are weighted toward **silent failure**: the key figure
set to *overwrite* that stays invisible for years because every source row happened to carry its
own key; the DTP monitor that shows fewer records and is *not* reporting a loss; the aborted
request that sits in the activation queue and fails every later activation regardless of what was
fixed in the code; the range table made of exclusions that matches nothing and thereby deletes
everything.

| Document | What is in it | Read it when |
|---|---|---|
| **`BW_KNOWLEDGE.md`** | the tables you must know (request management, dictionary, generated table suffixes), `/BIC/` naming, routine mechanics (`STATICS`, global block, compounded fields), semantic grouping, overwrite vs. summation, DTP behaviour, activation errors and dumps, HANA SQL in a BW context, measurement rules, modelling (compounding, ALPHA, CompositeProviders, the transport principle), routine-code parsing, dependency scans, the clipboard, where the truth about a load sits, data-quality patterns, self-loop transformations, reconciler semantics, and the BW → Datasphere → Databricks paths | you are building, debugging or auditing a BW data flow |
| **`BW_TRANSFORMATION_ROUTINES.md`** | ten symptom → cause → recipe entries for ABAP transformation routines: `MONITOR` without header line, generated type names, the global section, syntax-time column checks, `#` vs. initial value, where an unpivot belongs, DTPs and InfoSources, content data elements, master-data tables, content activation | you are writing or inheriting routine code |
| **`LO_COCKPIT_EXTRACTION.md`** | activating 2LIS extractors on the ERP side: setup tables vs. delta, the transaction sequence (RSA5 → SBIW → LBWE → LBWG → OLI*BW → RSA3 → RSA7), the purchasing DataSources, known pitfalls, sources | you are bringing logistics data into BW or Datasphere from ECC / S/4 |

## If you only read three things

1. **The rule of three after every load** — read / transferred / activated
   (`RSBKREQUEST.LINESREAD`, `.LINESTRANSFERRED`, `RSPMREQUEST.RECORDS`). It tells you in which
   step records or values vanished; without it you debug the wrong half of the chain.
   `BW_KNOWLEDGE.md` §1.
2. **Overwrite and summation are identical until they are not.** A key figure on *overwrite* is
   indistinguishable from *sum* as long as every source row has its own key. `BW_KNOWLEDGE.md` §5.
3. **Look in the queue before the code.** An aborted request in the activation queue fails every
   later activation on the same records; deleting the aDSO's data does not remove it.
   `BW_KNOWLEDGE.md` §6a.

## Conventions

- Object names in angle brackets are placeholders; `Z…` objects are illustrative.
- ⚠️ marks something that fails silently; 🔴 marks something that cost a day.
- Table and field names were verified against the data dictionary of the release in question.
  BW releases differ in generated names (see `BW_TRANSFORMATION_ROUTINES.md` §2) — re-verify on
  yours.

## License

[CC BY 4.0](../LICENSE) — reuse and adapt freely, with attribution.

SAP, SAP BW and SAP BW/4HANA are trademarks of SAP SE. This is an independent work and carries no
affiliation with or endorsement by SAP.
