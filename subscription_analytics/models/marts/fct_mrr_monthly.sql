with orders as (
    select * from {{ ref('fct_orders') }}
)

select
    client_id,
    order_month                         as month_date,
    product_cat_desc,
    sum(mrr_contribution)               as mrr,
    count(distinct subscription_id)     as active_subscriptions,
    count(distinct product_id)          as distinct_products

from orders
where is_revenue_valid = true
group by 1, 2, 3