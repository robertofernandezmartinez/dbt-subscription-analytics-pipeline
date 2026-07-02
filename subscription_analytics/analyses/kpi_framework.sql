-- 10 KPIs for the subscription business
-- Run each block independently against the Gold layer


-- 1. MRR — Monthly Recurring Revenue

select
    month_date,
    sum(mrr) as total_mrr
from {{ ref('fct_mrr_monthly') }}
group by 1
order by 1;



-- 2. MRR Growth Rate (Month-over-Month %)

with monthly as (
    select month_date, sum(mrr) as mrr
    from {{ ref('fct_mrr_monthly') }}
    group by 1
)
select
    month_date,
    mrr,
    lag(mrr) over (order by month_date) as prev_mrr,
    round(
        100.0 * (mrr - lag(mrr) over (order by month_date))
        / nullif(lag(mrr) over (order by month_date), 0), 2
    ) as mrr_growth_pct
from monthly
order by 1;



-- 3. New MRR

with client_first_month as (
    select client_id, min(month_date) as first_month
    from {{ ref('fct_mrr_monthly') }}
    group by 1
)
select
    f.month_date,
    sum(f.mrr) as new_mrr
from {{ ref('fct_mrr_monthly') }} f
join client_first_month c
    on f.client_id = c.client_id
    and f.month_date = c.first_month
group by 1
order by 1;



-- 4. Active Customer Base

select
    count(distinct client_id) as active_clients
from {{ ref('dim_subscriptions') }}
where subscription_status_clean = 'ACTIVE';



-- 5. ARPU — Average Revenue Per User

select
    month_date,
    sum(mrr)                            as total_mrr,
    count(distinct client_id)           as active_clients,
    round(sum(mrr) / nullif(count(distinct client_id), 0), 2) as arpu
from {{ ref('fct_mrr_monthly') }}
group by 1
order by 1;



-- 6. Churned Subscriptions per Month

select
    date_trunc(expire_date, month)  as churn_month,
    count(*)                        as churned_subscriptions
from {{ ref('dim_subscriptions') }}
where is_churned = true
group by 1
order by 1;



-- 7. Customer Churn Rate (%)

with monthly_active as (
    select month_date, count(distinct client_id) as active_clients
    from {{ ref('fct_mrr_monthly') }}
    group by 1
),
monthly_churned as (
    select
        date_trunc(s.expire_date, month) as month_date,
        count(distinct o.client_id)      as churned_clients
    from {{ ref('dim_subscriptions') }} s
    join {{ ref('stg_orders') }} o on s.subscription_id = o.subscription_id
    where s.is_churned = true
    group by 1
)
select
    a.month_date,
    a.active_clients,
    coalesce(c.churned_clients, 0)                                          as churned_clients,
    round(100.0 * coalesce(c.churned_clients, 0) / nullif(a.active_clients, 0), 2) as churn_rate_pct
from monthly_active a
left join monthly_churned c on a.month_date = c.month_date
order by 1;



-- 8. Cross-Sell Rate (customers with 2+ product categories)

with client_categories as (
    select
        client_id,
        count(distinct product_cat_desc) as n_categories
    from {{ ref('fct_mrr_monthly') }}
    where product_cat_desc is not null
    group by 1
)
select
    count(*)                                                                as total_clients,
    countif(n_categories >= 2)                                             as cross_sell_clients,
    round(100.0 * countif(n_categories >= 2) / nullif(count(*), 0), 2)   as cross_sell_rate_pct
from client_categories;



-- 9. Cohort Retention (M3 / M6 / M12)

with cohorts as (
    select
        c.client_id,
        c.join_month                                            as cohort_month,
        f.month_date,
        date_diff(f.month_date, c.join_month, month)           as months_since_join
    from {{ ref('dim_customers') }} c
    join {{ ref('fct_mrr_monthly') }} f on c.client_id = f.client_id
)
select
    cohort_month,
    count(distinct case when months_since_join = 0  then client_id end) as cohort_size,
    count(distinct case when months_since_join = 3  then client_id end) as retained_m3,
    count(distinct case when months_since_join = 6  then client_id end) as retained_m6,
    count(distinct case when months_since_join = 12 then client_id end) as retained_m12
from cohorts
group by 1
order by 1;



-- 10. Simplified Customer LTV

with client_lifespan as (
    select
        client_id,
        date_diff(max(month_date), min(month_date), month) + 1 as lifespan_months,
        sum(mrr)                                                as total_revenue
    from {{ ref('fct_mrr_monthly') }}
    group by 1
)
select
    round(avg(lifespan_months), 1)                                          as avg_lifespan_months,
    round(avg(total_revenue), 2)                                            as avg_total_revenue,
    round(avg(total_revenue) / nullif(avg(lifespan_months), 0), 2)         as avg_monthly_arpu,
    round(avg(total_revenue), 2)                                            as simplified_ltv
from client_lifespan;