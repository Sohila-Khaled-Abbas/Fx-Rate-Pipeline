# Data Lineage Documentation

This document describes the flow and transformation of data from the source API to the destination PostgreSQL database.

## Lineage Diagram

![Architecture Diagram](architecture.png)

> **Tip:** The SVG version [`architecture.svg`](architecture.svg) is fully scalable and renders crisp on GitHub.

## System-Level Lineage

| Source System | Integration Tool | Caching/State | Target System |
| :--- | :--- | :--- | :--- |
| **Frankfurter API** (`api.frankfurter.app`) | **Apache NiFi** | **NiFi Distributed Map Cache** | **PostgreSQL** (`fx_db`) |

## Field-Level Lineage

The incoming JSON payload contains a nested structure that is flattened via Jolt Transform. 

**Sample Source Payload:**
```json
{
  "amount": 1.0,
  "base": "USD",
  "date": "2026-04-15",
  "rates": {
    "EUR": 0.95,
    "GBP": 0.82
  }
}
```

### Table: `fx_rates`

| Target Column | Target Data Type | Source Path (JSON) | Transformation Applied | Description |
| :--- | :--- | :--- | :--- | :--- |
| `base_currency` | `VARCHAR(3)` | `$.base` | Copied to `$[*].base_currency` array via Jolt. | The quoting currency (e.g., USD). |
| `target_currency` | `VARCHAR(3)` | `$.rates.<key>` | Key unnested to `$[*].target_currency` via Jolt. | The currency being priced (e.g., EUR). |
| `exchange_rate` | `DECIMAL(10,6)` | `$.rates.<value>` | Value unnested to `$[*].exchange_rate` via Jolt. | The conversion rate. |
| `rate_date` | `DATE` | `$.date` | Copied to `$[*].rate_date` array via Jolt. | The effective date of the FX rate. |
| `ingestion_timestamp` | `TIMESTAMP` | *System Default* | `CURRENT_TIMESTAMP` fallback in Postgres. | Timestamp of row insertion into the DB. |

## Data Quality & Primary Keys

- **Duplicate Prevention Rules:** 
  The compound check in NiFi uses the cache entry identifier: `${base}_${target}_${date}_${rate}`.
  If this exact composite string exists in the `DistributedMapCache`, the record is routed to the `duplicate` relationship and dropped.
- **Constraints:**
  Target schema enforces a composite Primary Key on `(base_currency, target_currency, rate_date)`. This serves as a secondary defense mechanism in case the NiFi Cache is cleared (e.g., after a container restart).
