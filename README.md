# FX Rate Pipeline: Dockerized In-Flight State Management

[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![Apache NiFi](https://img.shields.io/badge/Apache%20NiFi-72B043.svg?style=for-the-badge&logo=Apache%20NiFi&logoColor=white)](https://nifi.apache.org/)
[![Postgres](https://img.shields.io/badge/postgres-%23316192.svg?style=for-the-badge&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

> **A project demonstrating an ETL stateful approach using Apache NiFi and PostgreSQL.**

## 📖 Table of Contents
- [1. The Architectural Critique](#1-the-architectural-critique)
- [2. Docker Infrastructure](#2-docker-infrastructure)
- [3. Database Initialization](#3-database-initialization)
- [4. Step-by-Step NiFi Implementation](#4-step-by-step-nifi-implementation)
- [5. Required Critical Analysis](#5-required-critical-analysis)

---

## 🏗️ 1. The Architectural Critique

> [!WARNING]
> **Before building this, acknowledge the flaw in the design:**
> You are doing transformation in the ingestion layer. 

In a modern Analytics Engineering stack (ELT), you would use a tool like **Airbyte** or **Fivetran** to dump the raw JSON response directly into a PostgreSQL `JSONB` column, and then use **dbt (SQL)** to unnest and deduplicate the records. 

By forcing NiFi to flatten the JSON and maintain a stateful cache to drop duplicates, you are building a fragile, hard-to-maintain ETL pipeline. **Building this will demonstrate exactly why ELT replaced ETL.**

---

## 🐳 2. Docker Infrastructure

You must deploy NiFi and PostgreSQL in the same Docker network so they can communicate natively. The `docker-compose.yml` is provided at the root of the project.

Run the environment:
```bash
docker-compose up -d
```
Access NiFi at **[https://localhost:8443/nifi](https://localhost:8443/nifi)** *(bypass the self-signed certificate warning).*

---

## 🗄️ 3. Database Initialization

Connect to your PostgreSQL container (using DBeaver, pgAdmin, or CLI) and execute the target DDL found in `sql/init.sql` (or see below):

```sql
CREATE TABLE fx_rates (
    base_currency VARCHAR(3),
    target_currency VARCHAR(3),
    exchange_rate DECIMAL(10, 6),
    rate_date DATE,
    ingestion_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fx_rate PRIMARY KEY (base_currency, target_currency, rate_date)
);
```

---

## ⚙️ 4. Step-by-Step NiFi Implementation

### > Step 4.1: Controller Services Setup
You must configure background services before adding processors. Click the gear icon on the NiFi canvas.

- **DBCPConnectionPool:**
  - **Database Connection URL**: `jdbc:postgresql://postgres_fx:5432/fx_db` *(Note the use of the Docker container name `postgres_fx`)*
  - **Database Driver Class Name**: `org.postgresql.Driver`
  - **Database User**: `nifi_user`
  - **Password**: `nifi_password`
  - *Enable the service.*

- **DistributedMapCacheServer:**
  - Leave defaults. *Enable it.*

- **DistributedMapCacheClientService:**
  - **Server Hostname**: `localhost`
  - *Enable it.*

### > Step 4.2: Data Ingestion
Drag a Processor to the canvas.
- **Processor**: `InvokeHTTP`
- **Properties**:
  - **HTTP Method**: `GET`
  - **Remote URL**: `https://api.frankfurter.app/latest?from=USD`
- **Scheduling**: Set "Run Schedule" to 1 min.

### > Step 4.3: The Brittle Transformation (JOLT)
The API returns: `{"amount": 1.0, "base": "USD", "date": "2026-04-15", "rates": {"EUR": 0.95, "GBP": 0.82}}`
Relational databases cannot ingest dynamic maps. We must pivot this into an array of objects.

- **Processor**: `JoltTransformJSON`
- **Properties**:
  - **Jolt Transform**: `jolt-transform-shift`
  - **Jolt Specification**:
    ```json
    [
      {
        "operation": "shift",
        "spec": {
          "rates": {
            "*": {
              "$": "[#2].target_currency",
              "@": "[#2].exchange_rate",
              "@(2,base)": "[#2].base_currency",
              "@(2,date)": "[#2].rate_date"
            }
          }
        }
      }
    ]
    ```
- **Routing**: Connect `InvokeHTTP` (Response) to `JoltTransformJSON`.

### > Step 4.4: Record Splitting
We now have a single file containing a JSON array. We need one file per currency pair.

- **Processor**: `SplitJson`
- **Properties**:
  - **JsonPath Expression**: `$.*`
- **Routing**: Connect `JoltTransformJSON` (success) to `SplitJson`.

### > Step 4.5: State Management (Delta Detection)
Here, we prevent NiFi from sending the same data to PostgreSQL every minute.

- **Processor 1**: `EvaluateJsonPath`
  - **Destination**: flowfile-attribute
  - Add custom properties (click the + icon):
    - `base`: `$.base_currency`
    - `target`: `$.target_currency`
    - `date`: `$.rate_date`
    - `rate`: `$.exchange_rate`
  - **Routing**: Connect `SplitJson` (split) to `EvaluateJsonPath`.

- **Processor 2**: `DetectDuplicate`
  - **Cache Entry Identifier**: `${base}_${target}_${date}_${rate}`
  - **Distributed Cache Service**: Select your `DistributedMapCacheClientService`.
  - **Routing**: Connect `EvaluateJsonPath` (matched) to `DetectDuplicate`.

> [!IMPORTANT]
> **CRITICAL**: Route the `duplicate` relationship to a funnel or Auto-Terminate it. This is where redundant data dies.

### > Step 4.6: Database Load

- **Processor**: `PutDatabaseRecord`
- **Record Reader**: Create and enable a `JsonTreeReader`.
- **Statement Type**: `INSERT`
- **Database Connection Pooling Service**: Select your `DBCPConnectionPool`.
- **Table Name**: `fx_rates`
- **Routing**: Connect `DetectDuplicate` (non-duplicate) to `PutDatabaseRecord`.

---

## 🚨 5. Required Critical Analysis

Once the pipeline is running, verify the following logical failure points:

> [!CAUTION]
> ### 1. JOLT Fragility
> What happens if the Frankfurter API changes `"rates"` to `"exchange_rates"` in their payload? Your JOLT spec fails silently or throws an exception, stopping the pipeline. If this were ELT, the raw JSON would land in Postgres, and your dbt test would catch the schema drift downstream, allowing you to fix the SQL without touching the ingestion infrastructure.

> [!CAUTION]
> ### 2. Container Lifecycle
> If you run `docker-compose down`, does your `DistributedMapCacheServer` retain its memory? **No.** When you bring it back up, NiFi will suffer "amnesia" and write a massive batch of duplicates to Postgres, violating the primary key constraint. How will your `PutDatabaseRecord` handle the SQL violation?
