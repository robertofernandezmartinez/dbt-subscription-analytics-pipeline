with source as (
    select * from {{ ref('stg_customers') }}
)

select
    client_id,
    client_country,
    join_date,
    date_trunc(join_date, month)    as join_month,
    segment,
    is_migration_cohort

from source