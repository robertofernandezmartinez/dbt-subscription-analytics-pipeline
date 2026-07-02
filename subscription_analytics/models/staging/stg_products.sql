with source as (
    select * from {{ ref('products_in_') }}
),

final as (
    select
        cast(product_id as int64)                              as product_id,
        trim(product_code)                                     as product_code,
        trim(product_desc)                                     as product_desc,
        trim(product_subgroup_desc)                            as product_subgroup_desc,
        trim(product_group_desc)                               as product_group_desc,
        trim(product_subcat_desc)                              as product_subcat_desc,
        trim(regexp_replace(product_cat_desc, r',+$', ''))     as product_cat_desc

    from source
    where product_code is not null
)

select * from final