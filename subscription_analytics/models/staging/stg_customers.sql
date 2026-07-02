with source as (
    select * from {{ ref('customers_in_') }}
),

final as (
    select
        client_id,
        coalesce(nullif(trim(client_country), ''), 'UNKNOWN') as client_country,
        case
            when join_date = 'NULL' or join_date is null then null
            else cast(join_date as date)
        end as join_date,
        upper(trim(segment)) as segment,
        join_date in ('2016-10-26', '2016-10-27') as is_migration_cohort

    from source
)

select * from final