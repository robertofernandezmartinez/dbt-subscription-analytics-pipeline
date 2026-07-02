with source as (
    select * from {{ ref('subscriptions_in_') }}
),

final as (
    select
        cast(subscription_id as int64)   as subscription_id,
        cast(creation_date as date)      as creation_date,
        cast(start_date as date)         as start_date,
        cast(expire_date as date)        as expire_date,
        nullif(trim(status), 'NULL')     as status_raw,
        trim(product_code)               as product_code,

        case
            when (status is null or status = 'NULL')
             and cast(expire_date as date) >= current_date then 'ACTIVE'
            when (status is null or status = 'NULL')
             and cast(expire_date as date) <  current_date then 'EXPIRED_SILENT'
            when status in ('CANCELLED', 'TO DELETE', 'LOST')       then 'CANCELLED'
            when status in ('SUSPENDED', 'UNPAID', 'AWAITING PAYMENT') then 'SUSPENDED'
            when status in ('MAINTENANCE CHANGED', 'OWNER CHANGED',
                            'OWNER CHANGE IN PROGRESS', 'TOWEPANEL',
                            'PRE-WAIVED', 'TO VERIFY')              then 'IN_TRANSITION'
            else 'OTHER'
        end as subscription_status_clean,

        status in ('AWAITING PAYMENT', 'UNPAID') as is_at_risk

    from source
)

select * from final