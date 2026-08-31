#!/usr/bin/env python3
"""
SAP Analytics Cloud: create and fill a parent-child hierarchy on a dimension
via the internal FPA REST API (browser session, no OAuth client required).

Companion to README.md in this folder, which explains every call in detail.
Field-verified against a productive SAC tenant (2026-07); the FPA layer is
UNSUPPORTED internal API — re-verify against your release before relying on it.

FLOW
  1. CSRF handshake        GET  /epm/session?action=logon  (x-csrf-token: fetch)
  2. Read the dimension    POST /epm/objectmgr             (action: readObject)
  3. Add the hierarchy     POST /fpa/dimension             (action: update)
  4. Fill the tree         PUT  /fpa/wrangling             (3 calls, see README §5)
  5. Verify                re-read + poll the member count

HARD RULES (each one cost real time to learn)
  - There is NO patch API: always read the full definition, modify, write the
    whole thing back. Guard the payload before firing (see update_dimension).
  - `action` goes in the REQUEST BODY, not the query string. `?action=...` in
    the URL returns 400 with an EMPTY message — a silent, misleading failure.
    Only `?tenant=<GUID>` belongs in the URL (mandatory on some tenants).
  - The tree is NOT part of the hierarchy definition. It lives in the members'
    parent pointers, filled from a parent column of the source during a
    master-data import. Declare the hierarchy first, then map + load.
  - The package namespace is tenant-specific (t.XX / t.10 / t.B ...). Never
    hardcode it — resolve it via contentlib getResourceEx (resolve_package).
  - Cross-hierarchy leaf rule: a member that becomes a PARENT in any
    parent-child hierarchy of the dimension can no longer carry fact data.
    Check what is booked on the affected members before creating the hierarchy.
"""

import json
import sys
import time

import requests

# ─── Placeholders — fill in per tenant ───────────────────────────────────────
BASE = "https://<TENANT>.<DC>.hcs.cloud.sap"  # or <tenant>.<dc>.sapanalytics.cloud
TENANT_GUID = "<TENANT_GUID>"  # visible as ?tenant=... on any FPA
# request in the browser dev tools;
# leave "" if your tenant omits it
COOKIE = "<COOKIE_HEADER>"  # full Cookie header copied from an
# authenticated SAC browser session

PACKAGE = "t.<NS>"  # tenant namespace, e.g. t.XX
DIM = "<DIMENSION_ID>"  # technical dimension name
HIER_NAME = "<HIERARCHY_NAME>"
HIER_DESC = "<HIERARCHY_DESCRIPTION>"

# Fill step — the source must already be STAGED (an import job exists).
# Capture these ids from the network calls of the Data Management UI (README §5):
SFILE_ID = "<SFILE_ID>"  # staged file id of the import job
CONNECTION_ID = "<CONNECTION_ID>"  # source connection id
QUERY_ID = "<QUERY_ID>"
QUERY_NAME = "<QUERY_NAME>"
ID_COLUMN = "<ID_SOURCE_COLUMN>"  # source column holding the member key
PARENT_COLUMN = "<PARENT_SOURCE_COLUMN>"  # source column holding the parent key
# ─────────────────────────────────────────────────────────────────────────────

FPA = f"{BASE}/sap/fpa/services/rest"


def q(url: str) -> str:
    """Append the tenant GUID as a query parameter when configured."""
    if not TENANT_GUID or TENANT_GUID.startswith("<"):
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}tenant={TENANT_GUID}"


session = requests.Session()
session.headers.update({"Cookie": COOKIE, "Accept": "application/json"})
# If the TLS handshake fails with alert 70, force TLSv1.2:
# import ssl; from requests.adapters import HTTPAdapter
# ctx = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
# class Tls12(HTTPAdapter):
#     def init_poolmanager(self, *a, **kw): kw["ssl_context"] = ctx; return super().init_poolmanager(*a, **kw)
# session.mount("https://", Tls12())


def get_csrf() -> str:
    r = session.get(
        q(f"{FPA}/epm/session?action=logon"), headers={"x-csrf-token": "fetch"}
    )
    r.raise_for_status()
    token = r.headers.get("x-csrf-token")
    assert token, "No CSRF token — session expired? Re-copy the cookie header."
    session.headers["x-csrf-token"] = token
    return token


def post(url: str, payload: dict, method: str = "POST") -> dict:
    r = session.request(
        method, q(url), json=payload, headers={"Content-Type": "application/json"}
    )
    if r.status_code >= 400:
        # 500 "Method X was not implemented" = right endpoint, wrong action verb.
        sys.exit(f"HTTP {r.status_code} on {url}\n{r.text[:2000]}")
    body = r.json()
    # Some errors come back as HTTP 200 with an error field — check both.
    if isinstance(body, dict) and body.get("error"):
        sys.exit(f"API error on {url}:\n{json.dumps(body, indent=2)[:2000]}")
    return body


def resolve_package(resource_id: str) -> str:
    """Resolve the tenant namespace instead of guessing (objectId = 'TYPE:<package>:<id>')."""
    body = post(
        f"{FPA}/epm/contentlib",
        {"action": "getResourceEx", "data": {"resourceId": resource_id}},
    )
    return body["objectId"].split(":")[1]


def read_dimension() -> tuple[dict, int]:
    """readObject: for DIMENSIONs, the returned data is already write-shaped
    (unlike stories, whose read projection is NOT valid for writing back)."""
    body = post(
        f"{FPA}/epm/objectmgr",
        {
            "action": "readObject",
            "data": {
                "p1": {"name": DIM, "type": "DIMENSION", "package": PACKAGE},
                "p2": False,
                "p3": {
                    "bUseTempService": True,
                    "resourceOptions": {
                        "metadata": {"name": True, "description": True},
                        "accessMode": 1,
                    },
                },
            },
        },
    )
    # optimistic lock lives in metadata.version, NOT inside data
    return body["data"], body["metadata"]["version"]


def build_write_data(read_data: dict) -> dict:
    """Minimal write structure from the read; drop read-only extras
    (mode, packageName, schemaName, masterDataTableName, memberCount, ...)."""
    keep = {
        k: read_data[k]
        for k in (
            "type",
            "isLocal",
            "capability",
            "properties",
            "hierarchies",
            "defaultHierarchy",
        )
        if k in read_data
    }
    keep["isEmbedded"] = False
    return keep


def add_hierarchy(write_data: dict) -> dict:
    ns = PACKAGE.split(".", 1)[1]
    hier_view = f'"TENANT_{ns}"."{PACKAGE}:{DIM}//hier/{HIER_NAME}"'
    write_data.setdefault("hierarchies", []).append(
        {
            "hierarchy": HIER_NAME,
            "hierarchyType": "parent_child",  # level-based: fill levels:[...] instead
            "description": HIER_DESC,
            "descriptions": {"en": HIER_DESC},
            "isMandatory": False,
            "levels": [],
            "nodeStyle": None,
            "hierarchyViewName": hier_view,  # auto-derived naming convention
        }
    )
    return write_data


def update_dimension(
    write_data: dict, version: int, expect_hier_count: int, expect_prop_count: int
) -> None:
    # Guards BEFORE firing — this may run against a productive tenant:
    assert len(write_data["properties"]) == expect_prop_count, "properties[] changed!"
    first = write_data["properties"][0]
    assert first.get("propertyType") == "ID" or first.get("property") == "ID", (
        "ID property not at position 0!"
    )
    assert len(write_data["hierarchies"]) == expect_hier_count, (
        "hierarchies[] unexpected!"
    )

    body = post(
        f"{FPA}/fpa/dimension",
        {
            "action": "update",
            "data": {
                "id": {"type": "DIMENSION", "name": DIM, "package": PACKAGE},
                "version": version,
                "data": write_data,
            },
        },
    )
    print(f"  update → notificationID {body.get('notificationID')}")


def map_and_load() -> None:
    """Map the parent column onto the hierarchy and start the master-data load."""
    # 1. get the HEADER<n> ↔ source-column map
    init = post(
        f"{FPA}/fpa/wrangling",
        {
            "action": "setInitialDataForDimension",
            "data": {
                "p1": {
                    "sDimensionId": DIM,
                    "sFileId": SFILE_ID,
                    "useFirstRowAsHeader": False,
                    "workflow": "IMPORT_MASTER_DATA",
                }
            },
        },
        method="PUT",
    )
    cols = {c["name"]: c["tmpColumnName"] for c in init["mappingData"]["sourceColumns"]}
    print(f"  source columns: {list(cols)}")

    def map_col(column_name: str, attribute: dict) -> None:
        header = cols[column_name]
        post(
            f"{FPA}/fpa/wrangling",
            {
                "action": "changeDimensionMapping",
                "data": {
                    "p1": {
                        "changeInfo": {"attribute": attribute, "column": header},
                        "sFileId": SFILE_ID,
                        "sDimensionId": DIM,
                        "sTmpColId": header,
                    }
                },
            },
            method="PUT",
        )

    # 2. map the key column and the parent column (further attributes analogous;
    #    fire the calls sequentially, not in parallel)
    map_col(
        ID_COLUMN, {"type": "ID", "compoundType": "ID", "id": "ID", "isMandatory": True}
    )
    map_col(
        PARENT_COLUMN,
        {
            "type": "HIERARCHY",
            "compoundType": "HIERARCHY",
            "id": HIER_NAME,
            "hierarchyType": "parent_child",
        },
    )

    # 3. start the load (runs async server-side)
    body = post(
        f"{FPA}/fpa/wrangling",
        {
            "action": "importMasterData",
            "data": {
                "p1": {
                    "sFileId": SFILE_ID,
                    "sDimensionId": DIM,
                    "sPackage": PACKAGE,
                    "aAcquisitionPayloads": [
                        {
                            "fileId": SFILE_ID,
                            "acquisitionPayload": {
                                "wranglingMethod": "HANA",
                                "connectionId": CONNECTION_ID,
                                "queryId": QUERY_ID,
                                "queryType": 1,
                                "queryName": QUERY_NAME,
                                "payloadVersion": "1.0",
                                "schedulable": 1,
                            },
                        }
                    ],
                    "sFileName": QUERY_NAME,
                    "hierarchyValidationToOmit": {},
                }
            },
        },
        method="PUT",
    )
    print(f"  importMasterData → {body}")


def poll_member_count(minutes: int = 10) -> None:
    """Members load async — poll until the count jumps."""
    for _ in range(minutes * 6):
        body = post(
            f"{FPA}/fpa/member",
            {
                "action": "query",
                "data": {"dimensionId": DIM, "package": PACKAGE},
            },
        )
        count = (body.get("Data") or {}).get("totalMembersCount")
        print(f"  totalMembersCount = {count}")
        if count and count > 1:  # right after the load this reads 1 ('#')
            return
        time.sleep(10)
    print("  ⚠ timeout — check the load in the Data Management UI.")


def main() -> None:
    get_csrf()
    print(f"package per tenant: {resolve_package(DIM)} (configured: {PACKAGE})")

    print("1/4 reading dimension ...")
    read_data, version = read_dimension()
    n_props = len(read_data["properties"])
    n_hiers = len(read_data.get("hierarchies", []))
    print(f"  {DIM}: {n_props} properties, {n_hiers} hierarchies, version {version}")
    if any(h["hierarchy"] == HIER_NAME for h in read_data.get("hierarchies", [])):
        sys.exit(f"hierarchy {HIER_NAME} already exists — aborting.")

    print("2/4 creating hierarchy definition ...")
    write_data = add_hierarchy(build_write_data(read_data))
    update_dimension(
        write_data, version, expect_hier_count=n_hiers + 1, expect_prop_count=n_props
    )

    print("3/4 verifying (re-read) ...")
    read_data2, version2 = read_dimension()
    assert version2 > version, "version not bumped — did the update land?"
    assert any(h["hierarchy"] == HIER_NAME for h in read_data2["hierarchies"])
    print(f"  ok: version {version} → {version2}")

    print("4/4 filling the tree (mapping + load) ...")
    map_and_load()
    poll_member_count()
    print(
        "Done. Cross-check in the Modeler: dimension → hierarchies → inspect the tree."
    )


if __name__ == "__main__":
    main()
