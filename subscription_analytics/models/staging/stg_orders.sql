with source as (
    select * from {{ ref('orders_in_') }}
),
final as (
    select
        client_id,
        ordercode,
        renewcode,
        cast(orderdate as date)                 as orderdate,
        cast(expiredate as date)                as expiredate,
        cast(nullif(subscription_id, 'NULL')    as int64) as subscription_id,
        cast(product_id as string)              as product_id,
        cast(quantity as int64)                 as quantity,
        cast(productprice as float64)           as productprice,
        currency,
        cast(duration_months as float64)        as duration_months,
        cast(flag_recurring as int64)           as flag_recurring,

        case
            when cast(productprice as float64) > 0.01
             and cast(quantity as int64) > 0
             and cast(flag_recurring as int64) = 1 then true
            else false
        end as is_revenue_valid

    from source
    qualify row_number() over (
        partition by
            client_id, ordercode, renewcode, orderdate, expiredate,
            subscription_id, product_id, quantity,
            cast(productprice as string),
            currency,
            cast(duration_months as string),
            cast(flag_recurring as string)
        order by ordercode
    ) = 1
)

select * from final