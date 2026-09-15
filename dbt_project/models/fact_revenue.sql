{{ config(materialized='table', tags=['mart', 'finance', 'revenue']) }}

-- This is the same unsolved model used in Lesson 1. Lesson 2 changes the tool
-- harness, not the business task.
with daily_sales as (
    select
        order_date,
        currency_code,
        source_system,
        count(distinct order_id) as total_orders,
        count(distinct customer_id) as unique_customers,
        count(order_line_id) as total_line_items,
        sum(extended_price) as gross_revenue,
        sum(discount_amount) as total_discounts,
        sum(extended_price - discount_amount) as net_revenue,
        sum(tax_amount) as total_tax,
        sum(line_total) as total_revenue,
        avg(unit_price) as avg_unit_price,
        avg(extended_price) as avg_line_value,
        sum(quantity_ordered) as total_units_ordered,
        sum(quantity_shipped) as total_units_shipped,
        count(case when is_fully_shipped then 1 end) as fully_shipped_lines,
        count(case when is_cancelled then 1 end) as cancelled_lines
    from {{ source('retail', 'fct_sales') }}
    where order_date is not null
    group by order_date, currency_code, source_system
),
final as (
    select
        order_date,
        extract(year from order_date) as year,
        extract(month from order_date) as month,
        extract(quarter from order_date) as quarter,
        extract(dayofweek from order_date) as day_of_week,
        extract(week from order_date) as week_of_year,
        currency_code,
        source_system,
        total_orders,
        unique_customers,
        total_line_items,
        gross_revenue,
        total_discounts,
        net_revenue,
        total_tax,
        total_revenue,
        avg_unit_price,
        avg_line_value,
        case when total_orders > 0 then total_revenue / total_orders else 0 end as avg_order_value,
        total_units_ordered,
        total_units_shipped,
        case when total_line_items > 0 then fully_shipped_lines::decimal / total_line_items::decimal else 0 end as fulfillment_rate,
        case when total_line_items > 0 then cancelled_lines::decimal / total_line_items::decimal else 0 end as cancellation_rate,
        case when gross_revenue > 0 then total_discounts / gross_revenue else 0 end as discount_rate,
        current_timestamp as dbt_updated_at
    from daily_sales
)
select * from final