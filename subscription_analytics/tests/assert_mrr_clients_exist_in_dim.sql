select f.client_id
from {{ ref('fct_mrr_monthly') }} f
left join {{ ref('dim_customers') }} d on f.client_id = d.client_id
where d.client_id is null