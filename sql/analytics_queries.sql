-- Olist Data Warehouse: analytical queries (MySQL 8 / MySQL Workbench)
-- How to run: click inside ONE query and press Ctrl + Enter.
-- "Active" orders below means order_status is not 'canceled' or 'unavailable'.

USE olist_dw;

-- =====================================================================
-- Q1. Monthly revenue, running total and month-over-month growth
--     (CTE + window functions SUM() OVER and LAG())
-- =====================================================================
WITH monthly AS (
    SELECT d.year, d.month, SUM(f.price) AS revenue
    FROM fact_order_items f
    JOIN dim_date d ON f.purchase_date_key = d.date_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY d.year, d.month
)
SELECT
    year,
    month,
    ROUND(revenue, 2)                                         AS revenue,
    ROUND(SUM(revenue) OVER (ORDER BY year, month), 2)        AS running_total,
    ROUND((revenue - LAG(revenue) OVER (ORDER BY year, month))
          / LAG(revenue) OVER (ORDER BY year, month) * 100, 2) AS mom_growth_pct
FROM monthly
ORDER BY year, month;

-- =====================================================================
-- Q2. Average order value (AOV) and order count by month
-- =====================================================================
SELECT
    d.year,
    d.month,
    COUNT(DISTINCT f.order_id)                          AS orders,
    ROUND(SUM(f.price) / COUNT(DISTINCT f.order_id), 2) AS avg_order_value
FROM fact_order_items f
JOIN dim_date d ON f.purchase_date_key = d.date_key
WHERE f.order_status NOT IN ('canceled', 'unavailable')
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

-- =====================================================================
-- Q3. Top 10 product categories by revenue, with share of total
-- =====================================================================
SELECT
    p.category_name_en,
    COUNT(*)                                              AS items_sold,
    ROUND(SUM(f.price), 2)                                AS revenue,
    ROUND(SUM(f.price) * 100 / SUM(SUM(f.price)) OVER (), 2) AS revenue_share_pct
FROM fact_order_items f
JOIN dim_product p ON f.product_key = p.product_key
WHERE f.order_status NOT IN ('canceled', 'unavailable')
GROUP BY p.category_name_en
ORDER BY revenue DESC
LIMIT 10;

-- =====================================================================
-- Q4. Top 3 categories per year (RANK window function)
-- =====================================================================
WITH cat_year AS (
    SELECT d.year, p.category_name_en, SUM(f.price) AS revenue
    FROM fact_order_items f
    JOIN dim_product p ON f.product_key = p.product_key
    JOIN dim_date d    ON f.purchase_date_key = d.date_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY d.year, p.category_name_en
),
ranked AS (
    SELECT year, category_name_en, revenue,
           RANK() OVER (PARTITION BY year ORDER BY revenue DESC) AS rnk
    FROM cat_year
)
SELECT year, rnk, category_name_en, ROUND(revenue, 2) AS revenue
FROM ranked
WHERE rnk <= 3
ORDER BY year, rnk;

-- =====================================================================
-- Q5. Top 10 sellers by revenue
-- =====================================================================
SELECT
    s.seller_id,
    s.city,
    s.state,
    COUNT(DISTINCT f.order_id) AS orders,
    ROUND(SUM(f.price), 2)     AS revenue
FROM fact_order_items f
JOIN dim_seller s ON f.seller_key = s.seller_key
WHERE f.order_status NOT IN ('canceled', 'unavailable')
GROUP BY s.seller_id, s.city, s.state
ORDER BY revenue DESC
LIMIT 10;

-- =====================================================================
-- Q6. Revenue by customer state
-- =====================================================================
SELECT
    c.state,
    COUNT(DISTINCT f.order_id) AS orders,
    ROUND(SUM(f.price), 2)     AS revenue,
    ROUND(SUM(f.price) * 100 / SUM(SUM(f.price)) OVER (), 2) AS revenue_share_pct
FROM fact_order_items f
JOIN dim_customer c ON f.customer_key = c.customer_key
WHERE f.order_status NOT IN ('canceled', 'unavailable')
GROUP BY c.state
ORDER BY revenue DESC;

-- =====================================================================
-- Q7. Delivery performance by customer state
--     (delivered orders only, one row per order, states with 100+ orders)
-- =====================================================================
WITH delivered_orders AS (
    SELECT f.order_id,
           c.state,
           MAX(f.delivery_days) AS delivery_days,
           MAX(f.is_late)       AS is_late
    FROM fact_order_items f
    JOIN dim_customer c ON f.customer_key = c.customer_key
    WHERE f.order_status = 'delivered'
      AND f.delivery_days IS NOT NULL
    GROUP BY f.order_id, c.state
)
SELECT
    state,
    COUNT(*)                         AS orders,
    ROUND(AVG(delivery_days), 1)     AS avg_delivery_days,
    ROUND(AVG(is_late) * 100, 2)     AS late_pct
FROM delivered_orders
GROUP BY state
HAVING COUNT(*) >= 100
ORDER BY late_pct DESC;

-- =====================================================================
-- Q8. Does late delivery hurt review scores?
-- =====================================================================
WITH order_lateness AS (
    SELECT order_id, MAX(is_late) AS is_late
    FROM fact_order_items
    WHERE order_status = 'delivered' AND is_late IS NOT NULL
    GROUP BY order_id
)
SELECT
    CASE WHEN o.is_late = 1 THEN 'Late' ELSE 'On time' END AS delivery,
    COUNT(*)                         AS reviews,
    ROUND(AVG(r.review_score), 2)    AS avg_review_score
FROM fact_reviews r
JOIN order_lateness o ON r.order_id = o.order_id
GROUP BY delivery;

-- =====================================================================
-- Q9. Payment type mix
-- =====================================================================
SELECT
    payment_type,
    COUNT(*)                                  AS payments,
    ROUND(SUM(payment_value), 2)              AS total_value,
    ROUND(AVG(payment_installments), 2)       AS avg_installments,
    ROUND(SUM(payment_value) * 100 / SUM(SUM(payment_value)) OVER (), 2) AS share_pct
FROM fact_payments
GROUP BY payment_type
ORDER BY total_value DESC;

-- =====================================================================
-- Q10. Repeat vs one-time customers
--      (uses customer_unique_id, the real person, not the per-order id)
-- =====================================================================
WITH per_person AS (
    SELECT c.customer_unique_id,
           COUNT(DISTINCT f.order_id) AS orders,
           SUM(f.price)               AS spend
    FROM fact_order_items f
    JOIN dim_customer c ON f.customer_key = c.customer_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
)
SELECT
    CASE WHEN orders = 1 THEN 'One-time' ELSE 'Repeat' END AS segment,
    COUNT(*)                  AS customers,
    ROUND(SUM(spend), 2)      AS total_spend,
    ROUND(AVG(spend), 2)      AS avg_spend
FROM per_person
GROUP BY segment;

-- =====================================================================
-- Q11. Customer segmentation: recency and monetary scores (RFM-style)
--      NTILE(4) splits customers into quartiles; 4 = best.
--      Frequency is left out because almost all customers order once.
-- =====================================================================
WITH cust AS (
    SELECT c.customer_unique_id,
           DATEDIFF((SELECT MAX(purchase_ts) FROM fact_order_items),
                    MAX(f.purchase_ts)) AS recency_days,
           SUM(f.price)                 AS monetary
    FROM fact_order_items f
    JOIN dim_customer c ON f.customer_key = c.customer_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
),
scored AS (
    SELECT customer_unique_id, recency_days, monetary,
           NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
           NTILE(4) OVER (ORDER BY monetary)          AS m_score
    FROM cust
),
labeled AS (
    SELECT *,
           CASE
               WHEN r_score = 4 AND m_score = 4 THEN 'Champions'
               WHEN r_score >= 3 AND m_score >= 3 THEN 'Valuable'
               WHEN r_score = 1 AND m_score >= 3 THEN 'At risk (high value)'
               WHEN r_score = 1 THEN 'Lost'
               ELSE 'Regular'
           END AS segment
    FROM scored
)
SELECT
    segment,
    COUNT(*)                     AS customers,
    ROUND(AVG(recency_days), 0)  AS avg_recency_days,
    ROUND(AVG(monetary), 2)      AS avg_spend,
    ROUND(SUM(monetary), 2)      AS total_spend
FROM labeled
GROUP BY segment
ORDER BY total_spend DESC;
