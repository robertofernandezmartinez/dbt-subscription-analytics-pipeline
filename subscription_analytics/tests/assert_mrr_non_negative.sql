select *
from {{ ref('fct_mrr_monthly') }}
where mrr < 0