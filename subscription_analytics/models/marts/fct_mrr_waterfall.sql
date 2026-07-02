with monthly_mrr as (
    select
        client_id,
        month_date,
        sum(mrr) as mrr
    from {{ ref('fct_mrr_monthly') }}
    group by 1, 2
),

with_prev as (
    select
        client_id,
        month_date,
        mrr,
        lag(mrr) over (partition by client_id order by month_date) as prev_mrr,
        lag(month_date) over (partition by client_id order by month_date) as prev_month
    from monthly_mrr
),

classified as (
    select
        client_id,
        month_date,
        mrr,
        prev_mrr,

        case
            when prev_mrr is null and mrr > 0
                then 'new'
            when prev_mrr is null
             and date_diff(month_date, prev_month, month) > 1
             and mrr > 0
                then 'reactivation'
            when prev_mrr is not null and mrr > prev_mrr
                then 'expansion'
            when prev_mrr is not null and mrr < prev_mrr and mrr > 0
                then 'contraction'
            when prev_mrr is not null and mrr = 0
                then 'churn'
            else 'flat'
        end as mrr_movement_type,

        mrr - coalesce(prev_mrr, 0) as mrr_change

    from with_prev
)

select
    month_date,
    mrr_movement_type,
    count(distinct client_id)   as clients,
    sum(mrr)                    as total_mrr,
    sum(mrr_change)             as mrr_change
from classified
group by 1, 2
order by 1, 2