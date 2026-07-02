select *
from {{ ref('stg_orders') }}
where is_revenue_valid = true
and productprice <= 0.01