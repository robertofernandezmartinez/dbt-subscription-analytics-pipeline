with orders as (
    select * from {{ ref('stg_orders') }}
),

products as (
    select * from {{ ref('stg_products') }}
)

select
    o.client_id,
    o.ordercode,
    o.subscription_id,
    o.product_id,
    p.product_cat_desc,
    p.product_subcat_desc,
    o.orderdate,
    date_trunc(o.orderdate, month)  as order_month,
    o.expiredate,
    o.quantity,
    o.productprice,
    o.duration_months,
    o.flag_recurring,
    o.is_revenue_valid,

    case
        when o.is_revenue_valid and o.duration_months > 0
        then round((o.productprice * o.quantity) / o.duration_months, 4)
        else 0
    end as mrr_contribution

from orders o
left join products p on o.product_id = cast(p.product_id as string)