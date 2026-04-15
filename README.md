# FX Rate Pipeline: Dockerized In-Flight State Management

[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![Apache NiFi](https://img.shields.io/badge/Apache%20NiFi-72B043.svg?style=for-the-badge&logo=apachenifi&logoColor=white)](https://nifi.apache.org/)
[![Postgres](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![API](https://img.shields.io/badge/Frankfurter%20API-Open%20Source-brightgreen?style=for-the-badge)](https://www.frankfurter.app/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)

> **An intentionally flawed ETL pipeline built with Apache NiFi and PostgreSQL inside Docker, designed to surface and demonstrate the architectural limitations of in-flight stateful transformation — and why the industry moved from ETL to ELT.**

---

## 📖 Table of Contents

- [Architecture Diagram](#architecture-diagram)
- [1. The Architectural Critique — ETL vs ELT](#1-the-architectural-critique--etl-vs-elt)
- [2. Docker Infrastructure](#2-docker-infrastructure)
- [3. Database Initialization](#3-database-initialization)
- [4. Step-by-Step NiFi Implementation](#4-step-by-step-nifi-implementation)
  - [4.1 Controller Services Setup](#step-41-controller-services-setup)
  - [4.2 Data Ingestion — InvokeHTTP](#step-42-data-ingestion--invokehttp)
  - [4.3 Transformation — JoltTransformJSON](#step-43-the-brittle-transformation--jolttransformjson)
  - [4.4 Record Splitting — SplitJson](#step-44-record-splitting--splitjson)
  - [4.5 State Management — DetectDuplicate](#step-45-state-management--delta-detection)
  - [4.6 Database Load — PutDatabaseRecord](#step-46-database-load--putdatabaserecord)
- [5. Critical Failure Analysis](#5-critical-failure-analysis)
- [Project Structure](#project-structure)

---

## Architecture Diagram

![FX Rate Pipeline Architecture](docs/architecture.png)

> The diagram above shows the full data flow: from the Frankfurter REST API, through the six NiFi processors (each color-coded by function), through the in-memory deduplication cache, and finally into the PostgreSQL `fx_rates` table. The red path shows where duplicate records are silently dropped.

---

## 1. The Architectural Critique — ETL vs ELT

> [!WARNING]
> **This pipeline is intentionally designed with a known architectural flaw.** Read this section before building anything. The purpose of this project is to demonstrate *why* this flaw exists and what the modern alternative looks like.

### What Is Wrong Here?

This pipeline performs **transformation inside the ingestion layer** — the definition of ETL (Extract → Transform → Load). Specifically, NiFi is responsible for:

1. Flattening the nested JSON from the API into a flat row structure (Jolt).
2. Maintaining an in-memory state cache to detect and drop duplicate records (DetectDuplicate).

Both of these responsibilities belong **downstream** in a healthy, modern data stack.

### The Modern Alternative: ELT

In a modern **ELT** (Extract → Load → Transform) stack, the workflow would look like this:

| Concern | ETL (this project) | ELT (modern approach) |
| :--- | :--- | :--- |
| **Ingestion Tool** | Apache NiFi | Airbyte / Fivetran |
| **Raw Storage** | Flattened rows via Jolt | Raw `JSONB` column in PostgreSQL |
| **Transformation** | NiFi Jolt spec (XML/JSON config) | dbt SQL models (version-controlled) |
| **Deduplication** | NiFi DistributedMapCache (ephemeral) | `DISTINCT ON` / `ROW_NUMBER()` in SQL (persistent) |
| **Schema-drift detection** | Pipeline crashes silently | dbt tests catch it downstream |
| **Maintainability** | Low — Jolt specs are opaque | High — SQL is readable and testable |

> Building this pipeline will demonstrate, through hands-on failure, exactly why ELT replaced ETL as the dominant paradigm.

---

## 2. Docker Infrastructure

NiFi and PostgreSQL must run in the **same Docker bridge network** so they can resolve each other by container name (e.g., `postgres_fx`) rather than by IP address, which changes on each restart.

### Start the Environment

```bash
# Start both containers in detached mode
docker-compose up -d

# Verify both containers are healthy
docker ps

# Stream NiFi logs if something seems wrong
docker logs -f nifi_fx
```

### Access NiFi

Open **[https://localhost:8443/nifi](https://localhost:8443/nifi)** in your browser.

> [!NOTE]
> NiFi uses a self-signed TLS certificate by default. Your browser will show a security warning — click **Advanced → Proceed** to bypass it. This is expected in local development. The credentials are set in `docker-compose.yml`:
>
> - **Username**: `admin`
> - **Password**: `SuperSecretPassword123!`

### docker-compose.yml Explained

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15             # Pinned major version for reproducibility
    container_name: postgres_fx    # Fixed name so NiFi can resolve it via DNS
    environment:
      POSTGRES_USER: nifi_user
      POSTGRES_PASSWORD: nifi_password
      POSTGRES_DB: fx_db
    ports:
      - "5432:5432"                # Expose to host for DBeaver / pgAdmin access
    networks:
      - nifi-network

  nifi:
    image: apache/nifi:latest
    container_name: nifi_fx
    ports:
      - "8443:8443"                # HTTPS UI
    environment:
      - SINGLE_USER_CREDENTIALS_USERNAME=admin
      - SINGLE_USER_CREDENTIALS_PASSWORD=SuperSecretPassword123!
    networks:
      - nifi-network               # Same network as postgres — required for JDBC
    depends_on:
      - postgres                   # Ensures postgres starts first

networks:
  nifi-network:
    driver: bridge
```

> [!IMPORTANT]
> **Why `container_name` matters:** The JDBC connection URL in NiFi uses `postgres_fx` as the host (`jdbc:postgresql://postgres_fx:5432/fx_db`). Docker's internal DNS resolves container names within the same network. If you remove `container_name`, Docker assigns a random name and the JDBC connection will fail.

---

## 3. Database Initialization

Connect to the running `postgres_fx` container and create the target table. You can use DBeaver, pgAdmin, or the Docker CLI:

```bash
# Connect via Docker CLI
docker exec -it postgres_fx psql -U nifi_user -d fx_db
```

Then execute the DDL from `sql/init.sql`:

```sql
CREATE TABLE fx_rates (
    base_currency        VARCHAR(3)      NOT NULL,
    target_currency      VARCHAR(3)      NOT NULL,
    exchange_rate        DECIMAL(10, 6)  NOT NULL,
    rate_date            DATE            NOT NULL,
    ingestion_timestamp  TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_fx_rate
        PRIMARY KEY (base_currency, target_currency, rate_date)
);
```

### Schema Decisions Explained

| Column | Type | Reason |
| :--- | :--- | :--- |
| `base_currency` | `VARCHAR(3)` | ISO 4217 currency codes are always 3 characters (e.g., `USD`, `EUR`) |
| `target_currency` | `VARCHAR(3)` | Same as above |
| `exchange_rate` | `DECIMAL(10, 6)` | Fixed-point avoids floating-point rounding errors in financial data |
| `rate_date` | `DATE` | The Frankfurter API returns one snapshot per calendar day |
| `ingestion_timestamp` | `TIMESTAMP DEFAULT NOW()` | Audit trail — when was this row written, not when the rate was valid |
| **Primary Key** | `(base, target, date)` | Enforces uniqueness at the database level as a last-resort guard against duplicates |

---

## 4. Step-by-Step NiFi Implementation

### Step 4.1: Controller Services Setup

Controller Services are shared background resources (like connection pools and caches) that processors use. They must be configured and **enabled** before any processor can run.

Navigate to: **NiFi Canvas → Gear Icon (top-right) → Controller Services tab**

#### DBCPConnectionPool

This manages a pool of JDBC connections to PostgreSQL so that `PutDatabaseRecord` doesn't open and close a new connection on every record.

| Property | Value |
| :--- | :--- |
| **Database Connection URL** | `jdbc:postgresql://postgres_fx:5432/fx_db` |
| **Database Driver Class Name** | `org.postgresql.Driver` |
| **Database User** | `nifi_user` |
| **Password** | `nifi_password` |

> [!NOTE]
> The hostname in the JDBC URL is `postgres_fx` — the Docker container name — **not** `localhost`. NiFi itself runs inside a container, so `localhost` would refer to the NiFi container, not the PostgreSQL container. Docker's internal DNS resolves `postgres_fx` to the correct internal IP.

After entering these values, click the **lightning bolt icon** to enable the service.

#### DistributedMapCacheServer

This is the **server-side** in-memory key-value store that holds the set of seen cache keys (i.e., the set of `base_target_date_rate` strings that have already been processed).

| Property | Value |
| :--- | :--- |
| **Port** | `4557` (default) |

Enable it. No further configuration needed for local use.

#### DistributedMapCacheClientService

This is the **client-side** connector that processors use to read from and write to the cache server above.

| Property | Value |
| :--- | :--- |
| **Server Hostname** | `localhost` |
| **Server Port** | `4557` |

> [!NOTE]
> Here, `localhost` **is** correct — both the client and server are running inside the same NiFi JVM process, so they share the same host. The client talks to the server over a loopback socket, not over the Docker network.

Enable it.

---

### Step 4.2: Data Ingestion — InvokeHTTP

This processor fires an HTTP GET request on a timer and passes the response body as a new FlowFile downstream.

| Property | Value |
| :--- | :--- |
| **HTTP Method** | `GET` |
| **Remote URL** | `https://api.frankfurter.app/latest?from=USD` |
| **Run Schedule** | `1 min` (set in the Scheduling tab) |

**Connections to create:**

- `Response` → `JoltTransformJSON`
- `No Retry`, `Retry`, `Failure` → Auto-terminate (or route to a logging funnel)

**What the response looks like:**

```json
{
  "amount": 1.0,
  "base": "USD",
  "date": "2026-04-15",
  "rates": {
    "AUD": 1.5821,
    "BGN": 1.8435,
    "EUR": 0.9501,
    "GBP": 0.8197
  }
}
```

---

### Step 4.3: The Brittle Transformation — JoltTransformJSON

**The problem:** The `rates` field is a dynamic JSON map (`{ "EUR": 0.95, "GBP": 0.82 }`). Relational databases do not accept dynamic key-value maps as column values — we need one **row per currency pair**. Jolt "shifts" the nested structure into a flat array.

| Property | Value |
| :--- | :--- |
| **Jolt Transform** | `jolt-transform-shift` |
| **Jolt Specification** | See below |

```json
[
  {
    "operation": "shift",
    "spec": {
      "rates": {
        "*": {
          "$":        "[#2].target_currency",
          "@":        "[#2].exchange_rate",
          "@(2,base)": "[#2].base_currency",
          "@(2,date)": "[#2].rate_date"
        }
      }
    }
  }
]
```

**How the Jolt spec works:**

| Jolt Expression | Meaning |
| :--- | :--- |
| `"rates": { "*": { ... } }` | Match every key inside the `rates` object |
| `"$"` | The matched key itself (e.g., `"EUR"`) → becomes `target_currency` |
| `"@"` | The matched value (e.g., `0.9501`) → becomes `exchange_rate` |
| `"@(2, base)"` | Walk 2 levels up the input tree, get the `base` field → becomes `base_currency` |
| `"@(2, date)"` | Walk 2 levels up, get the `date` field → becomes `rate_date` |
| `[#2]` | Output into an array, indexed at the current depth-2 iteration count |

**Output after Jolt (before splitting):**

```json
[
  { "base_currency": "USD", "target_currency": "AUD", "exchange_rate": 1.5821, "rate_date": "2026-04-15" },
  { "base_currency": "USD", "target_currency": "EUR", "exchange_rate": 0.9501, "rate_date": "2026-04-15" },
  { "base_currency": "USD", "target_currency": "GBP", "exchange_rate": 0.8197, "rate_date": "2026-04-15" }
]
```

**Connections to create:** `success` → `SplitJson`

---

### Step 4.4: Record Splitting — SplitJson

The Jolt output is a **single FlowFile containing an array** of ~33 objects (one per currency). `PutDatabaseRecord` can handle arrays, but we need individual FlowFiles so `DetectDuplicate` can evaluate each record separately.

| Property | Value |
| :--- | :--- |
| **JsonPath Expression** | `$.*` |

`$.*` selects every element at the root of the array. Each element becomes its own FlowFile.

**Connections to create:** `split` → `EvaluateJsonPath` | `original` → Auto-terminate

---

### Step 4.5: State Management — Delta Detection

This two-processor stage prevents NiFi from inserting the **same daily rate** into PostgreSQL on every 60-second tick. Without it, each day would accumulate 1,440 identical rows and hit primary key violations after the first.

#### Processor 1 — EvaluateJsonPath

Extracts values from the FlowFile body and promotes them to **FlowFile attributes** (metadata). Attributes are needed because `DetectDuplicate` operates on attribute expressions, not on the body of the FlowFile.

| Destination | Value |
| :--- | :--- |
| **Destination** | `flowfile-attribute` |

Add the following custom attribute mappings via the **`+` button**:

| Attribute Name | JsonPath Expression |
| :--- | :--- |
| `base` | `$.base_currency` |
| `target` | `$.target_currency` |
| `date` | `$.rate_date` |
| `rate` | `$.exchange_rate` |

**Connections to create:** `matched` → `DetectDuplicate` | `unmatched` → Auto-terminate

#### Processor 2 — DetectDuplicate

Queries the `DistributedMapCache` for the composite key. If the key already exists in the cache, the FlowFile is routed to `duplicate`. If it is new, it is added to the cache and routed to `non-duplicate`.

| Property | Value |
| :--- | :--- |
| **Cache Entry Identifier** | `${base}_${target}_${date}_${rate}` |
| **Distributed Cache Service** | Select `DistributedMapCacheClientService` |

> [!IMPORTANT]
> You **must** handle the `duplicate` relationship — either connect it to a funnel (for visibility) or set it to **Auto-terminate**. If you leave it unconnected, NiFi will refuse to start the processor. This is the path where redundant data is silently discarded before it ever reaches the database.

**Connections to create:** `non-duplicate` → `PutDatabaseRecord` | `duplicate` → Auto-terminate (or a logging funnel)

---

### Step 4.6: Database Load — PutDatabaseRecord

Writes each unique FlowFile into the `fx_rates` table using a JDBC batch insert.

| Property | Value |
| :--- | :--- |
| **Record Reader** | `JsonTreeReader` *(create and enable this Controller Service)* |
| **Statement Type** | `INSERT` |
| **Database Connection Pooling Service** | Select `DBCPConnectionPool` |
| **Table Name** | `fx_rates` |

NiFi automatically maps JSON field names to column names — `base_currency`, `target_currency`, `exchange_rate`, and `rate_date` must match the column names in the DDL exactly.

**Connections to create:** `success` → Auto-terminate | `failure` → Auto-terminate (or a failure funnel for alerting)

---

## 5. Critical Failure Analysis

Once the pipeline is running, intentionally probe these two failure modes to understand the fragility of the ETL pattern.

---

> [!CAUTION]
> **Failure Mode 1 — JOLT Schema Fragility**
>
> **Scenario:** The Frankfurter API team renames the `"rates"` key to `"exchange_rates"` in a future API version.
>
> **What happens:** The Jolt spec has `"rates": { "*": { ... } }` hardcoded. When the key no longer exists, the shift operation produces an **empty array `[]`**. NiFi does not throw an error — it produces empty FlowFiles that propagate silently through the pipeline. No data lands in PostgreSQL, but no alert fires either. The pipeline *appears* healthy.
>
> **Root cause:** The transformation logic is encoded in an opaque Jolt JSON spec embedded in NiFi's UI. There are no unit tests, no schema contracts, and no schema-drift detection.
>
> **ELT alternative:** If you were using Airbyte + dbt, the raw JSON (including the now-renamed key) would land untouched in a `JSONB` column in Postgres. A dbt schema test (`accepted_values`, `not_null` on the extracted field) would **immediately fail** on the next dbt run, surfacing the problem with a clear error message. You fix the SQL model — you don't touch the ingestion infrastructure at all.

---

> [!CAUTION]
> **Failure Mode 2 — Container Restart Causes Duplicate Flood**
>
> **Scenario:** You run `docker-compose down` (scheduled maintenance, system reboot, or accidental Ctrl+C) and then `docker-compose up -d` to bring the stack back.
>
> **What happens:** The `DistributedMapCacheServer` stores its state **purely in JVM heap memory**. When the NiFi container stops, that memory is gone. When NiFi restarts, the cache is empty — it has no memory of what it already ingested.
>
> On the next scheduled tick, `InvokeHTTP` fetches the current day's rates. `DetectDuplicate` sees an **empty cache**, so every record looks new. It routes all ~33 currency pairs to `PutDatabaseRecord`, which attempts to INSERT rows that already exist in `fx_rates`.
>
> **PostgreSQL's response:** The primary key constraint `pk_fx_rate` on `(base_currency, target_currency, rate_date)` fires. PostgreSQL rejects every row with a `duplicate key value violates unique constraint` error. `PutDatabaseRecord` routes all FlowFiles to its `failure` relationship.
>
> **Cascading effect:** If `failure` is set to Auto-terminate (the quickest setup), you lose all visibility. If you have a failure funnel, the FlowFiles pile up. Either way, the deduplication contract you thought you had was actually provided by the *database constraint*, not NiFi — making the entire `DetectDuplicate` stage a redundant, fragile approximation of what a simple `INSERT ... ON CONFLICT DO NOTHING` statement would have guaranteed.
>
> **ELT alternative:** A dbt incremental model with `unique_key` set would issue `MERGE` or `INSERT ... ON CONFLICT DO NOTHING` SQL natively, making idempotency a first-class database guarantee rather than an in-memory approximation.

---

## Project Structure

```text
Fx-Rate-Pipeline/
├── docker-compose.yml        # Spins up NiFi + PostgreSQL on a shared bridge network
├── sql/
│   └── init.sql              # DDL: CREATE TABLE fx_rates (...)
├── docs/
│   ├── architecture.png      # Pipeline architecture diagram (PNG, 2000px wide)
│   ├── architecture.svg      # Same diagram as scalable SVG (for GitHub rendering)
│   ├── architecture.mmd      # Mermaid source file for the diagram
│   └── data_lineage.md       # Field-level source-to-target lineage documentation
├── nifi_templates/           # Export your NiFi flow XML here for version control
├── data/                     # Scratch space — gitignored
├── .gitignore
├── LICENSE                   # MIT
└── README.md
```
