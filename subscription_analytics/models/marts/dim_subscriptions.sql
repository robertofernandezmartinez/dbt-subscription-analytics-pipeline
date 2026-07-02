with source as (
    select * from {{ ref('stg_subscriptions') }}
)

select
    subscription_id,
    creation_date,
    start_date,
    expire_date,
    status_raw,
    subscription_status_clean,
    is_at_risk,
    product_code,

    case
        when subscription_status_clean in ('ACTIVE', 'IN_TRANSITION') then false
        when expire_date is not null
         and expire_date < date_sub(current_date, interval 30 day) then true
        else false
    end as is_churned

from source