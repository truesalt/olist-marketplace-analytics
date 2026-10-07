# Entity-relationship diagrams

GitHub renders the Mermaid blocks below. PK = primary key, FK = enforced foreign key.

## 1. Core (normalised, constrained) schema - `sql/setup/03_core_schema.sql`

```mermaid
erDiagram
    customers ||--o{ orders : "places (customer_id)"
    orders ||--|{ order_items : "contains"
    orders ||--o{ order_payments : "paid by"
    orders ||--o| order_reviews : "reviewed (1 after dedup)"
    products ||--o{ order_items : "sold as"
    sellers ||--o{ order_items : "sells"
    category_translation ||..o{ products : "translates (no FK)"
    geolocation_zip ||..o{ customers : "locates zip (no FK)"
    geolocation_zip ||..o{ sellers : "locates zip (no FK)"
    sellers |o..o| seller_leads : "won lead (no FK)"

    customers {
        char32 customer_id PK "one per ORDER"
        char32 customer_unique_id "the person (indexed)"
        char5 zip_prefix
        varchar city
        varchar city_clean
        char2 state
        varchar region
    }
    orders {
        char32 order_id PK
        char32 customer_id FK
        varchar order_status "CHECK in 8 values"
        datetime purchase_ts
        datetime approved_ts
        datetime carrier_ts
        datetime delivered_ts
        date estimated_date
        int delivery_days
        int delay_days
        bool is_late
        bool ts_anomaly
        bool is_valid_delivery
    }
    order_items {
        char32 order_id PK,FK
        int order_item_id PK
        char32 product_id FK
        char32 seller_id FK
        datetime shipping_limit_ts
        decimal price "CHECK > 0"
        decimal freight_value "CHECK >= 0"
    }
    order_payments {
        char32 order_id PK,FK
        int payment_sequential PK
        varchar payment_type
        int payment_installments "CHECK >= 1"
        decimal payment_value "CHECK >= 0"
    }
    order_reviews {
        char32 order_id PK,FK
        char32 review_id "not unique in source"
        tinyint review_score "CHECK 1-5"
        bool has_comment
        date review_created_date
        datetime review_answer_ts
    }
    products {
        char32 product_id PK
        varchar category_pt
        varchar category_en
        int weight_g "CHECK >= 0"
        int length_cm
        int height_cm
        int width_cm
    }
    sellers {
        char32 seller_id PK
        char5 zip_prefix
        varchar city_clean
        char2 state
        varchar region
    }
    category_translation {
        varchar category_pt PK
        varchar category_en
    }
    geolocation_zip {
        char5 zip_prefix PK
        decimal lat "CHECK -34..6"
        decimal lng "CHECK -74..-34"
        varchar city
        char2 state
        int n_points
    }
    seller_leads {
        char32 mql_id PK
        date first_contact_date
        varchar origin
        bool is_won
        char32 seller_id "not FK: most won sellers never sell"
        date won_date
        int days_to_close
    }
```

## 2. Star schema (analysis + Power BI) - `sql/setup/09_star_schema_views.sql`

One fact at **order-item grain**; order-level attributes (delivery, review, payment) are denormalised onto each item.
All relationships are many-to-one, single direction. `fact_seller_leads` and the marts stand alone.

```mermaid
erDiagram
    dim_date ||--o{ fact_order_items : "date = purchase_date"
    dim_customer ||--o{ fact_order_items : "customer_unique_id"
    dim_seller ||--o{ fact_order_items : "seller_id"
    dim_product ||--o{ fact_order_items : "product_id"

    fact_order_items {
        char32 order_id
        int order_item_id
        date purchase_date FK
        char32 customer_unique_id FK
        char32 seller_id FK
        char32 product_id FK
        decimal price
        decimal freight_value
        decimal item_gmv
        varchar order_status
        int is_valid_delivery
        int is_late
        int delivery_days
        int delay_days
        varchar delay_bucket
        int review_score
        int is_low_review
        int has_voucher
        varchar payment_type_main
        int max_installments
        double distance_km
        varchar seller_region
        varchar customer_region
    }
    dim_date {
        date date PK
        int year
        int quarter
        int month_num
        varchar month_name
        char7 year_month
        date week_start
        bool is_weekend
        bool in_window
    }
    dim_customer {
        char32 customer_unique_id PK
        char2 state
        varchar region
        datetime first_order_ts
        char7 first_order_month
        int first_order_is_late
        int first_order_has_voucher
        decimal first_order_value
        int total_orders
        decimal total_gmv
        int eligible_repeat
        int repeat_180d
        varchar rfm_segment
    }
    dim_seller {
        char32 seller_id PK
        char2 state
        varchar region
        char7 first_sale_month
        char7 last_sale_month
        varchar lead_origin
        int is_acquired_via_funnel
    }
    dim_product {
        char32 product_id PK
        varchar category_en
        int weight_g
        bigint volume_cm3
        int photos_qty
    }
    fact_seller_leads {
        char32 mql_id PK
        varchar origin
        int is_won
        int days_to_close
        int made_first_sale
        decimal gmv_first_90d
        int active_months_first_6
    }
```

Helper view `v_valid_orders` (order grain) feeds the fact and `v_dim_customer`; it is the single place where
"valid order" is defined. Marts (`mart_monthly_kpis`, `mart_lane_sla`, `mart_cohort_retention`,
`mart_seller_monthly`, `mart_pareto_sellers`) are pre-aggregated tables refreshed by `sp_refresh_marts()`.
