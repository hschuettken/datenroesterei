# ZTABLE_EXPORT_CSV - High-Performance SAP Table to CSV Exporter

ABAP report for extracting large SAP tables (e.g., ACDOCA with 1.5B+ rows) into chunked CSV files on the application server.

## Key Features

- **Streaming cursor** (`OPEN CURSOR` + `FETCH ... PACKAGE SIZE`) — constant memory usage regardless of table size
- **Chunked output** — split by row count or max file size (GB)
- **Fully parameterized** — table name, fields, delimiter, WHERE clause, chunk sizes, etc.
- **Long WHERE clauses** — text field parameter, save as variant for reuse
- **Locale-independent numerics** — decimals always use `.` as separator
- **Crash-safe checkpoint/resume** — survives job crashes; resumes from last PK checkpoint via keyset pagination
- **ORDER BY PRIMARY KEY** — deterministic ordering, free on HANA (clustered by PK)
- **Compatible with ABAP 7.02+** (SAP NetWeaver 7.0 EHP2 and later)

## Parameters

### Table & Format (Block 1)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `P_TABLE` | Source table name | `ACDOCA` |
| `P_PKG` | Rows per DB fetch (package size for cursor) | `50000` |
| `P_CHUNK` | Rows per CSV file (row-based chunking) | `5000000` |
| `P_MAXGB` | Max GB per file; overrides row-based chunking if > 0 | `2.00` |
| `P_DELIM` | CSV field delimiter | `;` |
| `P_ENCL` | Text enclosure character | `"` |
| `P_HEAD` | Write header row in each file | `X` (yes) |
| `P_ESC` | Escape enclosure chars in data values | `X` (yes) |
| `P_CRLF` | Use CRLF line endings (Windows-style) | ` ` (no, uses LF) |
| `P_UTF8` | Open files with UTF-8 encoding | `X` (yes) |

### Output File (Block 2)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `P_PATH` | Output directory on app server (AL11) | `/tmp/export/` |
| `P_PREFIX` | File name prefix | `EXPORT` |
| `P_EXT` | File extension | `.csv` |

Files are named: `{PREFIX}_{TABLE}_{00001}.csv`, `{PREFIX}_{TABLE}_{00002}.csv`, ...

### Field Selection & Filter (Block 3)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `S_FIELDS` | Select-option: field names to export (empty = all fields) | empty |
| `P_WHERE` | Inline WHERE clause | empty |

### Execution Control (Block 5)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `P_MAXREC` | Max total rows to export (0 = unlimited) | `0` |
| `P_PROG` | Progress log interval (every N rows) | `100000` |
| `P_TEST` | Test mode: export only the first package | ` ` (no) |

### Checkpoint / Resume (Block 6)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `P_RESUM` | Resume from last checkpoint file | ` ` (no) |
| `P_CKINT` | Checkpoint interval in rows (0 = every package) | `0` |

The checkpoint file is written to `{P_PATH}{P_PREFIX}_{P_TABLE}_checkpoint.dat` and contains:
- Line 1: `file_count|total_rows|chunk_rows|chunk_bytes`
- Line 2: Primary key values of the last exported row, pipe-separated

On successful completion, the checkpoint file is automatically deleted.

## Performance

### Measured Benchmarks

Benchmarked on SAP S/4HANA 2023, ACDOCA table, 44,818 rows test dataset.

| Fields | Rows/sec | ms/row | μs/field | File size |
|--------|----------|--------|----------|-----------|
| 518 (all columns) | **2,700** | 0.37 | 0.71 | 42 MB |
| 41 (field selection) | **26,364** | 0.038 | 0.93 | 5.5 MB |

The per-field cost differs because the IS INITIAL fast-path skips empty fields at ~0.1μs vs ~0.9μs for populated fields. Wide tables like ACDOCA have 70-90% empty fields per row, so the effective per-field cost drops significantly.

### Extrapolated Run Times

| Scenario | Fields | Rows | Est. rows/sec | Est. time |
|----------|--------|------|---------------|-----------|
| ACDOCA all cols | 518 | 50M | ~2,700 | ~5.1 hours |
| ACDOCA all cols | 518 | 1.5B | ~2,700 | ~6.4 days |
| ACDOCA selected | 60 | 50M | ~18,000 | ~46 min |
| ACDOCA selected | 60 | 1.5B | ~18,000 | ~23 hours |
| ACDOCA selected | 41 | 50M | ~26,000 | ~32 min |
| Narrow table | < 20 | 50M | ~40,000+ | ~21 min |

**Recommendation:** Use field selection (`S_FIELDS`) to export only needed columns — this is the single biggest lever for throughput.

### Optimization History

Starting from a customer baseline of **~278 rows/sec** (2 hours per 2M records):

| Optimization | 518 cols | 41 cols | Factor |
|-------------|----------|---------|--------|
| Streaming cursor + dynamic SQL | 1,090 /s | — | 3.9x |
| + batch CONCATENATE, index access | 1,966 /s | 19,486 /s | 7.1x |
| + IS INITIAL fast-path (current) | 2,700 /s | 26,364 /s | **9.7x** |

Key techniques: `OPEN CURSOR WITH HOLD` + `FETCH PACKAGE SIZE` for streaming, `ASSIGN COMPONENT` by index, `LOOP ASSIGNING` (no structure copy), pre-allocated string table for CSV assembly, `IS INITIAL` fast-path to skip 70-90% of field processing, `CONCATENATE LINES OF` for O(n) row join.

### Package Size (`P_PKG`)

Controls how many rows are fetched per database roundtrip. Larger values reduce DB roundtrips but consume more memory. Benchmarks show package size has **no measurable impact** on throughput (the bottleneck is ABAP-side serialization, not DB fetch).

| Table Width | Recommended `P_PKG` |
|-------------|---------------------|
| Narrow (< 50 cols) | 100,000 - 500,000 |
| Medium (50-200 cols) | 50,000 - 100,000 |
| Wide (200+ cols, like ACDOCA) | 20,000 - 50,000 |

### Tips

1. **Run as background job** (`SM36`/`SM37`) — do not run in dialog mode for large extractions
2. **Schedule during off-peak hours** to minimize DB lock contention
3. **Check disk space** on the app server before starting — ACDOCA can produce 500GB+ of CSV
4. **Use size-based chunking** (`P_MAXGB = 2`) for predictable file sizes
5. **Use field selection** (`S_FIELDS`) to export only needed columns — reduces I/O dramatically

## Installation

1. Create the report in SE38 or SE80: program name `ZTABLE_EXPORT_CSV`
2. Paste the source code from `ZTABLE_EXPORT_CSV.abap`
3. Activate the program
4. Ensure the output directory exists on the app server (check with `AL11`)

## Example: Export ACDOCA

```
P_TABLE  = ACDOCA
P_PKG    = 50000
P_MAXGB  = 2.00
P_DELIM  = ;
P_PATH   = /tmp/acdoca_export/
P_PREFIX = ACDOCA
P_EXT    = .csv
P_PROG   = 500000
```

This will create files like:
```
/tmp/acdoca_export/ACDOCA_ACDOCA_00001.csv
/tmp/acdoca_export/ACDOCA_ACDOCA_00002.csv
...
```

Each file will be approximately 2 GB.

## Example: Export with WHERE clause

Set `P_WHERE` to your filter expression (supports arbitrarily long input — save as variant for reuse):
```
RCLNT = '100' AND GJAHR IN ('2022','2023','2024') AND RBUKRS IN ('1000','2000','3000') AND RACCT BETWEEN '0000400000' AND '0000899999'
```

## Example: Resume after crash

If a job dies at row 800M, the checkpoint file contains the last exported PK values.
To resume, simply re-run with the **same parameters** plus `P_RESUM = X`:

```
P_TABLE  = ACDOCA
P_PKG    = 50000
P_MAXGB  = 2.00
P_PATH   = /tmp/acdoca_export/
P_PREFIX = ACDOCA
P_RESUM  = X           <-- enables resume
```

The program will:
1. Read the checkpoint file to get the last exported primary key
2. Build a composite key WHERE clause: `(K1 > V1) OR (K1 = V1 AND K2 > V2) OR ...`
3. Continue file numbering and row counting from where it left off
4. Skip zero rows (the DB seeks directly to the resume point via PK index)

**Important:** Do not change `P_TABLE`, `P_PATH`, or `P_PREFIX` between runs — the checkpoint file path is derived from these.

## Retrieving Files

After extraction, download the CSV files from the app server:
- **CG3Y** transaction — download individual files from app server to local PC
- **FTP** — if the path is on a mounted FTP share, files are directly accessible
- **AL11** — browse the app server file system to verify files
