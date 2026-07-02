# dbt Subscription Analytics Pipeline

Bronze-to-Gold dbt pipeline on subscription revenue data, built on BigQuery. Transforms four raw source datasets into a unified analytics layer for MRR analysis, customer retention, churn tracking, and cross-sell performance.

---

## What this delivers

| Deliverable | Where |
|-------------|-------|
| Transformation Logic | `models/staging/` + `models/marts/` |
| Data Product Definition | Below |
| KPI Framework (10 KPIs) | Below + `analyses/kpi_framework.sql` |
| Insights Memo | Below |

---

## Pipeline Architecture

```
Bronze   seeds/          raw CSVs loaded into BigQuery
Silver   models/staging/ cleaning, casting, dedup, status derivation
Gold     models/marts/   analytics-ready single source of truth
```

Models: `stg_orders` · `stg_customers` · `stg_products` · `stg_subscriptions` → `dim_customers` · `dim_products` · `dim_subscriptions` · `fct_orders` · `fct_mrr_monthly` · `fct_mrr_waterfall`

> In production, source data would arrive via an external ingestion layer (Fivetran, Airbyte) and be referenced with `{{ source() }}`. Seeds are used here as a substitute for the exercise.

---

## Data Product Definition

`fct_mrr_monthly` is the core data product — one row per `client_id × month_date × product_cat_desc`. This grain supports every downstream KPI (MRR trend, ARPU, cohort retention, cross-sell) without re-aggregating from raw orders each time, while remaining granular enough for per-client and per-category analysis.

`fct_mrr_waterfall` decomposes MRR change into New, Expansion, Contraction, Churn, and Reactivation — the breakdown the Director of Revenue needs to understand what is driving growth or decline each month.

`fct_orders` is kept as the order-grain traceability layer. Every number in `fct_mrr_monthly` reconciles back to specific order lines.

---

## KPI Framework

Full SQL in `analyses/kpi_framework.sql`.

**1. MRR** — the single number that tells whether the business is growing. Built from revenue-valid orders only, excluding placeholder prices, zero-quantity records, and one-time charges.

**2. MRR Growth Rate (MoM %)** — the trend matters more than the absolute. Signals acceleration or deceleration before it becomes visible in absolute MRR.

**3. New MRR** — isolates growth from new customer acquisition vs. expansion of existing accounts. Needed to separate acquisition efficiency from relationship depth.

**4. Active Subscription Base** — the denominator for ARPU and churn rate. Without a precise active definition (see below), every KPI built on this number is unreliable.

**5. ARPU** — distinguishes "more customers" growth from "more value per customer." If the cross-sell strategy is working, ARPU rises. If only volume grows, ARPU stays flat.

**6. Churn Rate (subscriptions)** — raw count of subscriptions lost per month. Signals product stickiness and the pace at which the base is eroding.

**7. Customer Churn Rate (%)** — churn normalized against the active base. A count of 500 churned subscriptions on a base of 5,000 is very different from the same count on 50,000.

**8. Cross-Sell Rate** — percentage of customers with 2+ product categories. Directly measures progress against the stated strategic goal of cross-selling across categories to increase ARPU.

**9. Cohort Retention (M3/M6/M12)** — the most honest signal of product-market fit. Tracks what share of customers acquired in a given month are still active at 3, 6, and 12 months.

**10. Customer LTV** — average revenue over average customer lifespan. Without LTV there is no rational basis for acquisition spend decisions.

---

## Insights Memo

### Data quality issues

**`productprice = 0.01` (33% of orders).** Systematic pattern concentrated in Applications (63%) — most likely bundled line items or migration placeholders, not noise. Flagged as `is_revenue_valid = FALSE` rather than dropped, so MRR excludes them while activity analysis retains them.

**`quantity = 0` (37% of orders).** Overlaps with the 0.01 rows but not identical — both conditions needed independently in `is_revenue_valid`. Zero quantity means zero revenue regardless of price.

**`flag_recurring = 0` (1.15% of orders).** One-time charges mixed into the same table as recurring subscriptions. Excluded from MRR — a one-time charge must not be spread across months as recurring revenue.

**Exact duplicate orders (10,011 rows).** Removed via `QUALIFY ROW_NUMBER()`. Rows sharing an `ordercode` but differing in `subscription_id` or price are kept — they are order splits or repricing events, not duplicates.

**Negative prices (1,744 rows).** Legitimate refunds. Kept as-is to correctly reduce MRR in the month recorded.

**`products` CSV malformed header** (`product_cat_desc,,,,`) and trailing commas in values. Fixed at ingestion and via `REGEXP_REPLACE` in `stg_products`.

**25,679 orders with no `subscription_id`.** Legitimate recurring orders not linked to a subscription record in the source system. Included in MRR, excluded from subscription-level analysis. Flagged for Data Management.

### Active and Churn definitions

`status` is NULL for 71.7% of subscriptions. This is not missing data — the source system only writes a status when something changes. NULL means "nothing happened yet." Splitting the NULL population by `expire_date` reveals two groups: future expire date (ACTIVE) and past expire date (EXPIRED_SILENT).

**Active:** `expire_date >= CURRENT_DATE AND (status IS NULL OR status NOT IN ('CANCELLED', 'TO DELETE', 'SUSPENDED'))`

**Churned:** not ACTIVE or IN_TRANSITION, AND `expire_date` more than 30 days in the past. The 30-day grace window covers payment retry cycles and late renewals common in subscription billing.

**AWAITING PAYMENT / UNPAID** are flagged separately as `is_at_risk` — an early churn signal distinct from confirmed churn.

### Scaling to 200M rows

- **Partition** `fct_orders` and `fct_mrr_monthly` by month — every MRR query filters by date, making partitioning the single highest-impact change.
- **Cluster** on `client_id` and `product_cat_desc` — the two most common secondary filter dimensions.
- **Incremental models** — replace full rebuilds of `fct_mrr_monthly` with dbt incremental materializations that process only new or changed records.
- **Upstream deduplication** — move the `QUALIFY ROW_NUMBER()` logic from staging to a streaming dedup layer before data lands in the warehouse.
- **Materialize the MRR aggregation** as a scheduled materialized view so BI tools hit the materialized layer, not the raw fact table.

The model is designed with this in mind: partition keys are implicit in the grain, all dedup and cleaning logic is isolated in staging, and no transformation assumes full-table availability.

---

## CI/CD

GitHub Actions runs `dbt build` (models + tests) on every push to `main` and on every pull request. See `.github/workflows/dbt_ci.yml`.

To enable: add `GCP_PROJECT_ID` and `GCP_SA_KEY` as repository secrets in GitHub → Settings → Secrets.

---

## How to run

```bash
pip install dbt-bigquery
cd subscription_analytics
dbt seed      # load source CSVs into BigQuery
dbt run       # build all models
dbt test      # run data quality and business logic tests
dbt docs generate && dbt docs serve  # browse lineage and column docs at localhost:8080
```

Configure `~/.dbt/profiles.yml` with your GCP project and service account keyfile before running.
