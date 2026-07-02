# dbt Subscription Analytics Pipeline

Analytics Engineering case study. Bronze-to-Gold dbt pipeline on subscription revenue data, built on BigQuery. Covers MRR analysis, customer retention, churn definition, and cross-sell performance.

---

## How to run

### Requirements
- Python 3.8+
- dbt-bigquery (`pip install dbt-bigquery`)
- A GCP project with BigQuery enabled and a service account with BigQuery Admin role

### Setup

```bash
git clone https://github.com/robertofernandezmartinez/dbt-subscription-analytics-pipeline
cd dbt-subscription-analytics-pipeline/subscription_analytics
```

Configure `~/.dbt/profiles.yml`:

```yaml
subscription_analytics:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: service-account
      project: YOUR_GCP_PROJECT_ID
      dataset: subscription_analytics
      keyfile: /path/to/your/keyfile.json
      threads: 4
      timeout_seconds: 300
```

### Run

```bash
dbt seed          # load source CSVs into BigQuery
dbt run           # build all models
dbt test          # run data quality tests
```

---

## Pipeline architecture

```
Bronze (seeds/)
  raw CSVs loaded as-is into BigQuery
  └── orders_in_ · customers_in_ · products_in_ · subscriptions_in_

Silver (models/staging/)
  cleaning, type casting, deduplication, status derivation
  └── stg_orders · stg_customers · stg_products · stg_subscriptions

Gold (models/marts/)
  analytics-ready tables, the single source of truth
  └── dim_customers · dim_products · dim_subscriptions
      fct_orders · fct_mrr_monthly · fct_mrr_waterfall
```

**Note on seeds:** In production, source data would be ingested by an external ETL process (Fivetran, Airbyte, or a custom pipeline) and referenced via `{{ source() }}`. Seeds are used here as a pragmatic substitute for the purposes of this exercise.

---

## Data Product Definition


**`fct_mrr_monthly`** is the core data product. Grain: one row per `client_id × month_date × product_cat_desc`.

Why this grain: it is the minimum granularity that supports every KPI in the framework without re-deriving from raw orders each time. Going coarser
(month-only) would lose the ability to do cohort and churn analysis per client. Going finer (per order) would push all aggregation logic into every downstream query, risking inconsistent numbers across reports — the exact problem the Director of Revenue is trying to solve.


**`fct_mrr_waterfall`** decomposes MRR movement month-over-month into New, Expansion, Contraction, Churn, and Reactivation — the standard breakdown for understanding revenue growth drivers.


**`fct_orders`** is the order-grain fact table, kept for traceability. Every number in `fct_mrr_monthly` can be reconciled to specific order lines.

---

## KPI Framework

| # | KPI | Why it matters |
|---|-----|----------------|
| 1 | MRR | Core growth number. Built from revenue-valid orders only — excludes 0.01€ placeholder lines and zero-quantity records. |
| 2 | MRR Growth Rate (MoM %) | Signals acceleration or deceleration, not just direction. |
| 3 | New MRR | Isolates growth from new customer acquisition vs. expansion of existing accounts. |
| 4 | Active Subscription Base | Foundation for ARPU and churn calculations. Requires the explicit ACTIVE definition below. |
| 5 | ARPU | Distinguishes "more customers" growth from "more value per customer" growth — cross-sell signal. |
| 6 | Churn Rate (subscriptions) | Raw signal of subscription lapses, using the 30-day grace window definition. |
| 7 | Customer Churn Rate (%) | Normalizes churn against the active base — a raw count is meaningless without the denominator. |
| 8 | Cross-Sell Rate (2+ categories) | Directly tracks the strategic goal stated in the business case. |
| 9 | Cohort Retention (M3/M6/M12) | The most honest signal of product-market fit. |
| 10 | Customer LTV (simplified) | Anchors acquisition spend decisions to long-term value. |

Full SQL in `analyses/kpi_framework.sql`.

---

## Insights Memo

### How data quality issues were handled

**`productprice = 0.01` (33% of orders), concentrated in Applications (63%).**
Too large and too consistent a pattern to be random noise — most likely internal/bundled line items, free add-ons, or system migration placeholders. Rather than dropping these rows, they are flagged via `is_revenue_valid = FALSE` in `stg_orders`. MRR calculations filter on this flag; order-volume analysis does not. This preserves the full audit trail while protecting MRR accuracy.

**`quantity = 0` (37% of orders).** 
Overlaps heavily with the 0.01 price rows (49,201 rows have both conditions) but is not identical — both conditions are needed independently in `is_revenue_valid`. A zero-quantity order generates `productprice × 0 = 0` revenue regardless of price.

**`flag_recurring = 0` (1.15% of orders).** One-time charges (setup fees, domain transfers) mixed into the same table as recurring subscriptions. Excluded from MRR via a third condition in `is_revenue_valid` — a one-time charge must not be spread across months as if it were recurring revenue.

**Exact duplicate orders (10,011 rows, 5%).** Removed via `QUALIFY ROW_NUMBER()` on the full row signature. Duplicate `ordercode` values that differ in `subscription_id` or price are kept — they represent technical order splits or repricing events, not data errors.

**Negative prices (1,744 rows, min -2,159€).** Legitimate refunds. Kept as-is so they correctly reduce MRR in the month recorded rather than retroactively correcting the original order.

**`products` CSV had malformed header** (`product_cat_desc,,,,`) and trailing commas baked into category values (`Domains,,,,`). The header issue was fixed at ingestion; value cleanup applied via `REGEXP_REPLACE` in `stg_products`.

**25,679 orders with no `subscription_id`** are legitimate recurring orders (real prices, `flag_recurring = 1`, normal durations) simply not linked to a subscription record in the source system. Included in MRR but excluded from subscription-level analysis. Flagged for Data Management.

**Referential integrity:** 1 orphan `product_id` and 4 orphan `subscription_id` values in orders. Kept, flagged for Data Management.

---

### How "Active" and "Churn" were defined

**The most important data quality decision in this dataset:** `status` is NULL for 71.7% of subscriptions. This is not missing data — the source system only writes a status value when something happens (cancelled, suspended, etc.). NULL means "nothing changed."

Splitting the NULL population by `expire_date` reveals two distinct groups:
- NULL + `expire_date` in the future → **ACTIVE**
- NULL + `expire_date` in the past → **EXPIRED_SILENT** (lapsed without an explicit status event)

**Active definition:**
```
expire_date >= CURRENT_DATE
AND (status IS NULL OR status NOT IN ('CANCELLED', 'TO DELETE', 'SUSPENDED'))
```

**Churned definition:** not ACTIVE or IN_TRANSITION, AND `expire_date` is more than 30 days in the past. The 30-day grace window accounts for late renewals and payment retry cycles common in subscription billing — treating the exact expiration date as the churn event would overstate churn for customers who renew within a normal grace period.

**AWAITING PAYMENT and UNPAID** are flagged separately as `is_at_risk` — an early churn signal worth tracking independently.

---

### Additional findings from exploration

**96% of customers are Italian.** When the business case describes "cross-sell across categories," it is effectively a single-country play, not multi-market expansion. Cross-sell KPI interpretation should account for this.

**`join_date` spike on 2016-10-26/27** (1,050 customers in two days vs ~75 typical). Most likely a data migration event or major campaign. These customers are flagged as `is_migration_cohort` in `dim_customers` to allow isolation from retention metrics until the business confirms the nature of the spike.

**Segment labels** (Ret-E, Ret-N, Res, obp, Registry) are not documented in the source. Assumed to be internal customer classifications. Business validation needed before using segment as an analysis dimension.

**`duration_months`** goes up to 120 (10-year contracts). A handful of non-standard values (25, 55, 70, 72, 84 months) appear 1-3 times each — flagged for business validation. No impact on the model since MRR normalization handles all durations correctly.

---

### Scaling from 200K to 200M rows

- **Partition `fct_orders` and `fct_mrr_monthly` by month.** Every MRR query filters by date; without partitioning every query scans the full table.
- **Cluster on `client_id` and `product_cat_desc`** — the two most common filter dimensions after date, for retention and cross-sell queries.
- **Incremental models** instead of full rebuilds. At 200M rows, recomputing `fct_mrr_monthly` from scratch daily is not viable. The staging layer already isolates clean, datestamped records which makes the incremental predicate trivial.
- **Push deduplication upstream** — the `QUALIFY ROW_NUMBER()` logic in staging moves to a streaming dedup layer before data lands in the warehouse.
- **Materialize monthly MRR aggregation** as a scheduled materialized view. BI tools and analysts hit the materialized layer, not the fact table directly.

The model is designed with this transition in mind: partition keys are already implicit in the grain (`month_date`, `client_id`), all cleaning and dedup logic is isolated in the staging layer, and no transformation assumes full-table availability.

---

Roberto Fernández
Analytics Engineer
https://www.linkedin.com/in/robertofernandezmartinez/ 