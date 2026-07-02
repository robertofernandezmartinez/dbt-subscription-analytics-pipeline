# dbt Subscription Analytics Pipeline

This project builds a unified revenue and product performance model for a subscription business, transforming four raw Bronze datasets into a Gold analytics layer that enables the Director of Revenue to understand MRR trends, growth drivers, customer retention, and cross-sell performance.

---

## Pipeline Architecture

```
Bronze (seeds/)
  Raw CSVs loaded as-is into BigQuery
  └── orders_in_ · customers_in_ · products_in_ · subscriptions_in_

Silver (models/staging/)
  Cleaning, type casting, deduplication, status derivation
  └── stg_orders · stg_customers · stg_products · stg_subscriptions

Gold (models/marts/)
  Analytics-ready tables — the single source of truth
  └── dim_customers · dim_products · dim_subscriptions
      fct_orders · fct_mrr_monthly · fct_mrr_waterfall
```

**Note on seeds:** In production, source data would be ingested by an external ETL process (Fivetran, Airbyte, or a custom pipeline) and referenced via `{{ source() }}`. Seeds are used here as a pragmatic substitute for the purposes of this exercise.

---

## Deliverable 1 — Transformation Logic

All transformation logic lives in `models/staging/` (Silver layer) and `models/marts/` (Gold layer). Each model is documented inline with the decisions made and why.

Key transformations:

- **Deduplication** — 10,011 exact duplicate orders removed via `QUALIFY ROW_NUMBER()` on the full row signature
- **Revenue validity flag** — `is_revenue_valid` in `stg_orders` protects MRR from three distinct classes of non-revenue records (see Insights Memo)
- **Status derivation** — `subscription_status_clean` derived from a combination of raw `status` and `expire_date` (see Insights Memo)
- **Category cleanup** — trailing commas stripped from `product_cat_desc` values, a source CSV export artifact

---

## Deliverable 2 — Data Product Definition

**`fct_mrr_monthly`** is the core data product. Grain: one row per `client_id × month_date × product_cat_desc`.

Why this grain: it is the minimum granularity that supports every KPI in the framework without re-deriving from raw orders each time. Going coarser (month-only) would lose the ability to do cohort and cross-sell analysis per client. Going finer (per order) would push all aggregation logic into every downstream query, risking inconsistent numbers across reports — the exact fragmentation problem the Director of Revenue is trying to solve.

**`fct_mrr_waterfall`** decomposes MRR movement month-over-month into New, Expansion, Contraction, Churn, and Reactivation — the standard breakdown for understanding revenue growth drivers.

**`fct_orders`** is the order-grain fact table, kept for traceability. Every number in `fct_mrr_monthly` can be reconciled to specific order lines.

The three dimension tables (`dim_customers`, `dim_products`, `dim_subscriptions`) provide the context for slicing and filtering: by segment, product category, subscription status, and customer cohort.

---

## Deliverable 3 — KPI Framework

Full SQL for each KPI in `analyses/kpi_framework.sql`.

### 1. MRR (Monthly Recurring Revenue)
The single number that tells the Director of Revenue whether the business is growing. Built from revenue-valid orders only — excludes 0.01€ placeholder lines, zero-quantity records, and one-time charges that would inflate the recurring revenue figure if included naively.

### 2. MRR Growth Rate (Month-over-Month %)
The trend matters more than the absolute number. A business growing at 5% MoM is in a fundamentally different position than one at -2%, even if the absolute MRR is similar. This KPI signals acceleration or deceleration early.

### 3. New MRR
Isolates the contribution of newly acquired customers from expansion of existing accounts. Essential for understanding whether growth is driven by acquisition efficiency or by deepening relationships with the existing base.

### 4. Active Subscription Base
The foundation for ARPU and churn calculations. Without a precise definition of "active" (see Insights Memo), every downstream KPI built on this number is unreliable. Tracked at subscription level to reflect the true operational base, not just billing accounts.

### 5. ARPU (Average Revenue Per User)
The key signal for the cross-sell strategy. If MRR grows but ARPU stays flat, growth is coming from volume, not from increasing value per customer. If ARPU grows, the cross-sell initiative is working. Tracked monthly to detect trend changes early.

### 6. Churn Rate (Subscriptions)
The raw count of subscriptions lost each month, using a 30-day grace window past `expire_date` to avoid counting late renewals as churn. Essential for understanding product stickiness and the rate at which the business is losing its base.

### 7. Customer Churn Rate (%)
The churn count normalized against the active base. A raw count of 500 churned subscriptions means something very different on a base of 5,000 vs 50,000. This percentage is the comparable, trackable signal that tells the business if retention is improving or deteriorating over time.

### 8. Cross-Sell Rate (customers with 2+ product categories)
The business case explicitly states the ambition to cross-sell across categories to increase ARPU. This KPI directly measures progress against that goal: what percentage of the customer base has purchased products from more than one category. It is the leading indicator for ARPU growth.

### 9. Cohort Retention (M3 / M6 / M12)
The most honest signal of product-market fit. Not "are we adding customers" but "do the customers we add stay." Tracked at 3, 6, and 12 months post acquisition to identify at which point customers are most likely to churn and whether product improvements are extending retention over time.

### 10. Customer LTV (Simplified)
Connects acquisition decisions to long-term value. Without LTV, there is no rational basis for deciding how much to spend on acquiring a customer. Even a simplified `average revenue × average lifespan` gives the Director of Revenue a number to anchor commercial decisions against.

---

## Deliverable 4 — Insights Memo

### How data quality issues were handled

**`productprice = 0.01` (33% of orders), concentrated in Applications (63%).**
Too large and too consistent a pattern to be random noise — most likely internal/bundled line items, free add-ons, or system migration placeholders. Rather than dropping these rows, they are flagged via `is_revenue_valid = FALSE` in `stg_orders`. MRR calculations filter on this flag; order-volume analysis does not. This preserves the full audit trail while protecting MRR accuracy.

**`quantity = 0` (37% of orders).** Overlaps heavily with the 0.01 price rows (49,201 rows have both conditions) but is not identical — both conditions are needed independently in `is_revenue_valid`. A zero-quantity order generates `productprice × 0 = 0` revenue regardless of price.

**`flag_recurring = 0` (1.15% of orders).** One-time charges (setup fees, domain transfers) mixed into the same table as recurring subscriptions. Excluded from MRR via a third condition in `is_revenue_valid` — a one-time charge must not be spread across months as if it were recurring revenue.

**Exact duplicate orders (10,011 rows, 5%).** Removed via `QUALIFY ROW_NUMBER()` on the full row signature. Duplicate `ordercode` values that differ in `subscription_id` or price are kept — they represent technical order splits or repricing events, not data errors.

**Negative prices (1,744 rows, min -2,159€).** Legitimate refunds. Kept as-is so they correctly reduce MRR in the month recorded rather than retroactively correcting the original order.

**`products` CSV had malformed header** (`product_cat_desc,,,,`) and trailing commas baked into category values (`Domains,,,,`). Fixed at ingestion and via `REGEXP_REPLACE` in `stg_products`.

**25,679 orders with no `subscription_id`** are legitimate recurring orders simply not linked to a subscription record in the source system. Included in MRR but excluded from subscription-level analysis. Flagged for Data Management.

**Referential integrity:** 1 orphan `product_id` and 4 orphan `subscription_id` values in orders. Kept, flagged for Data Management.

---

### How "Active" and "Churn" were defined

**The most consequential data quality decision in this dataset:** `status` is NULL for 71.7% of subscriptions. This is not missing data — the source system only writes a status value when something happens (cancelled, suspended, etc.). NULL means "nothing changed yet."

Splitting the NULL population by `expire_date` reveals two distinct groups:
- NULL + `expire_date` in the future → **ACTIVE**
- NULL + `expire_date` in the past → **EXPIRED_SILENT** (lapsed without an explicit status event)

**Active definition:**
```
expire_date >= CURRENT_DATE
AND (status IS NULL OR status NOT IN ('CANCELLED', 'TO DELETE', 'SUSPENDED'))
```

**Churned definition:** not ACTIVE or IN_TRANSITION, AND `expire_date` more than 30 days in the past. The 30-day grace window accounts for late renewals and payment retry cycles common in subscription billing — treating the exact expiration date as the churn event would overstate churn for customers who renew within a normal grace period.

**AWAITING PAYMENT and UNPAID** are flagged separately as `is_at_risk` in `dim_subscriptions` — an early churn signal worth monitoring independently from confirmed churn.

---

### Additional findings from exploration

**96% of customers are Italian.** The cross-sell strategy operates in effectively a single-country market. Cross-sell KPI benchmarks should reflect this context rather than multi-market norms.

**`join_date` spike on 2016-10-26/27** (1,050 customers in two days vs ~75 typical). Most likely a data migration event or major campaign. Flagged as `is_migration_cohort` in `dim_customers` to allow isolation from retention metrics until the business confirms the nature of the spike.

**Segment labels** (Ret-E, Ret-N, Res, obp, Registry) are not documented in the source. Business validation needed before using segment as an analysis dimension.

---

### Scaling from 200K to 200M rows

- **Partition `fct_orders` and `fct_mrr_monthly` by month.** Every MRR query filters by date — without partitioning, every query scans the full table.
- **Cluster on `client_id` and `product_cat_desc`** — the two most common filter dimensions after date, for retention and cross-sell queries.
- **Incremental models** instead of full rebuilds. The staging layer already isolates clean, datestamped records which makes the incremental predicate trivial.
- **Push deduplication upstream** — the `QUALIFY ROW_NUMBER()` logic moves to a streaming dedup layer before data lands in the warehouse.
- **Materialize the monthly MRR aggregation** as a scheduled materialized view. BI tools and analysts hit the materialized layer, not the fact table.

The model is designed with this transition in mind: partition keys are already implicit in the grain (`month_date`, `client_id`), all cleaning and dedup logic is isolated in the staging layer, and no transformation assumes full-table availability.

---

## CI/CD

This project uses GitHub Actions to run `dbt build` (models + tests) on
every push to `main` and on every pull request.

To enable it in your own fork, add these secrets in GitHub → Settings → Secrets:
- `GCP_PROJECT_ID` — your GCP project ID
- `GCP_SA_KEY` — the full contents of your service account JSON keyfile

---

## How to run

### Requirements
- Python 3.8+
- `pip install dbt-bigquery`
- GCP project with BigQuery enabled and a service account with BigQuery Admin role

### Setup

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
cd subscription_analytics
dbt seed    # load source CSVs into BigQuery
dbt run     # build all models
dbt test    # run data quality tests
```