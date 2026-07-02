with source as (
    select * from {{ ref('stg_products') }}
)

select
    product_id,
    product_code,
    product_desc,
    product_subgroup_desc,
    product_group_desc,
    product_subcat_desc,
    product_cat_desc

from source