# Activating LO Cockpit Extraction (2LIS_*) on the ERP Side — Reference

> Compiled from SAP Support Content and SAP Community (sources below), checked against the
> systems in question. Focus: application **02 Purchasing** (2LIS_02_HDR / ITM / SCL / SRV); the
> procedure applies to all LO applications (11/12/13 SD, 03 inventory, 04 production, …) with
> the matching `OLI*BW` transaction.
> No customer-specific information.

---

## 0. What to know beforehand

- **Setup tables** (`MC*SETUP`, e.g. `MC02M_0HDRSETUP`, `MC02M_0ITMSETUP`, `MC02M_0SCLSETUP`) are
  the source for **full** loads and the **delta init**. They are a snapshot, not a buffer.
  Deleting/filling them does not touch the delta. The delta runs separately through LBWQ/SM13 →
  RSA7.
- **RSA3** shows setup-table content exclusively. 0 records in RSA3 almost always means: `OLI*BW`
  has not run, or wrote 0 records.
- Setup tables are cluster tables, not meaningfully readable in SE16. Log of the rebuild: **NPRT**.
- No documents may be posted during the rebuild (**quiet period**, typically a weekend). Either
  lock the transactions (SM01: ME21N/ME22N/ME23N/…) or pick a window without postings. That is
  the actual planning object of a 2LIS activation, not the clicking.
- Full loads from setup tables are only as current as the last rebuild. Productively you need
  init + delta.

## 1. Sequence in the ERP (application 02)

```
1. RSA5   transfer DataSources from Business Content (2LIS_02_HDR, _ITM, _SCL, _SRV if needed)
          → "Transfer"; check in RSA6
2. SBIW   Settings for Application-Specific DataSources → Logistics →
          Settings: Purchasing →
            a) "Determine Industry Sector"   (Standard / Retail / CP; NOT "None")
            b) "Transaction Key Maintenance for SAP BW"  (= MCB_) — execute
          → without a)+b), BWVORG, BWGEO, BWGEOO, BWNETWR, BWMNG, BWGVP, BWGVO stay empty
            although RSA3 returns records (notes 353042, 684465)
3. LBWE   LO Data Extraction: Customizing Cockpit → application 02
            - set the extract structure inactive first if needed (Update column)
            - "Maintenance": take fields from the communication structure into the extract structure
            - DataSource button: maintain selection / hide / cancellation fields
            - activate the extract structure, transport request
            - update mode: Queued Delta (standard), Direct Delta (small volumes only),
              Unserialized V3 (only when order does not matter)
            - Job Control: schedule the collective run (Queued Delta / V3)
4. LBWG   delete setup tables, application 02
5. OLI3BW fill the purchasing setup tables (run name, "termination time" in the future,
          in background; restrict by document number/date and parallelise if needed)
6. RSA3   Extractor Checker on every DataSource (setup content only)
7. Target replicate the DataSource (BW: RSDS / ODP context SAPI; Datasphere: replication flow
          ODP_SAP), load the delta init, then check RSA7 (entry green, delta mode D)
8. Delta  Queued Delta: LBWQ → collective run (Job Control) → RSA7 → delta load
          Direct Delta: straight to RSA7
          V3: SM13 → collective run → RSA7
```

OLI transactions per application: 02 purchasing `OLI3BW` · 03 inventory `OLI1BW` (BF),
`OLIZBW` (UM), `MCNB` (BX) · 11/12/13 SD `OLI7BW` / `OLI8BW` / `OLI9BW` · 04 production `OLI4BW`
· 08 shipment `OLI8BW` … (pattern: `OLI<n>BW`, n = application number).

## 2. Purchasing DataSources at a glance

| DataSource | Content | Source table | Extract structure |
|---|---|---|---|
| 2LIS_02_HDR | purchase-order header | EKKO | MC02M_0HDR |
| 2LIS_02_ITM | purchase-order item (incl. commitment-relevant values) | EKKO/EKPO | MC02M_0ITM |
| 2LIS_02_SCL | schedule lines (GR/IR quantities and values) | EKET (+EKBE) | MC02M_0SCL |
| 2LIS_02_SRV | external services (service entry) | ESLL/ESLH | MC02M_0SRV |
| 2LIS_02_CGR / SGR / SCN | confirmations / GR actuals / scheduling-agreement releases | EKES/EKBE | — |

- SCL is the source for GR/IR values (`WEMNG`, `REMNG`, `BWGEO`); HDR/ITM are not enough for a
  purchase-order commitment when goods receipts are to be netted.
- `ROCANCEL`: `X` = reversal record, `R` = non-statistics-relevant item deleted, ` ` = current.
- Deleted items (`LOEKZ`) come only with the statistics indicator (note 578471).
- For purchase-order commitment alternatively/additionally: CO commitment via `0CO_OM_CCA_10`
  (cost-centre commitment, activity COMMITMENT) instead of purchasing documents.

## 3. Known pitfalls

- **RSA3 = 0 records despite a correct procedure:** the plug-in support package lags behind
  (note 720309 and predecessors); OLI3BW then silently writes nothing.
- **"DataSource still contains data to be transferred"** on a renewed rebuild: empty RSA7 first
  (fetch the delta twice, second run 0 records), then LBWG / OLI3BW.
- **Value fields empty (BWGEO & co.):** industry sector is "None" or MCB_ not executed (note
  353042). Then repeat LBWG + OLI3BW.
- **Extract structure inactive after adding fields:** always deactivate first, maintain, activate,
  transport. Extension by customer fields: note 2739105, exit `EXIT_SAPLRSAP_001`.
- **Collective run forgotten:** with Queued Delta the LUWs pile up in LBWQ, RSA7 stays empty.
- **CDS views as an alternative** exist for purchasing only from S/4HANA on
  (`I_PurchaseOrderItem` et al.), not on ECC EHP8. On ECC, 2LIS remains the standard path.

## 4. Sources (checked September 2026)

- SAP Support Content "LO Cockpit (LBWE) and Transport" — numbered step sequence:
  https://help.sap.com/docs/SUPPORT_CONTENT/bwdabc/3361383160.html
- SAP Support Content "BW-BCT-MM-PUR" — purchasing overview, LBWG 02, OLI3BW, notes 459517, 2715864:
  https://help.sap.com/docs/SUPPORT_CONTENT/bwdabc/3361384164.html
- SAP Support Content "2LIS_02_SCL" — fields, ROCANCEL, notes 353042/684465/856004/578471:
  https://help.sap.com/docs/SUPPORT_CONTENT/bwdabc/3361383831.html
- SAP Support Content "BW Setup Tables List":
  https://help.sap.com/docs/SUPPORT_CONTENT/bwdabc/3361383448.html
- SAP Community "LO data Extraction steps" (RSA5 → LBWE → LBWG → SBIW → RSA3 → RSA7):
  https://community.sap.com/t5/technology-blog-posts-by-members/lo-data-extraction-steps/ba-p/13298908
- SAP Community, solution to note 353042 (industry sector + MCB_):
  https://community.sap.com/t5/technology-q-a/oss-note-353042/qaq-p/1151883
- Roberto Negro, "Logistic Cockpit Delta Mechanism", episode 1 (V3) and 3 (Direct/Queued/V3):
  https://community.sap.com/t5/additional-blog-posts-by-members/logistic-cockpit-delta-mechanism-episode-one-v3-update-the-serializer/ba-p/12840364
  https://community.sap.com/t5/additional-blog-posts-by-members/logistic-cockpit-delta-mechanism-episode-three-the-new-update-methods/ba-p/12853101

help.sap.com is a single-page application: to read a page programmatically, render it (a headless
browser, or a rendering proxy) — a plain HTTP fetch returns only the shell.
