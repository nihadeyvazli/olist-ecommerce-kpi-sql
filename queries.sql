

-- DDL:

DROP VIEW  IF EXISTS v_base;
DROP TABLE IF EXISTS order_reviews;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS sellers;
DROP TABLE IF EXISTS category_translation;

CREATE TABLE customers (
    customer_id              TEXT PRIMARY KEY,     
    customer_unique_id       TEXT NOT NULL,        
    customer_zip_code_prefix INTEGER,
    customer_city            TEXT,
    customer_state           TEXT
);

CREATE TABLE sellers (
    seller_id              TEXT PRIMARY KEY,
    seller_zip_code_prefix INTEGER,
    seller_city            TEXT,
    seller_state           TEXT
);

CREATE TABLE category_translation (
    product_category_name         TEXT PRIMARY KEY,   
    product_category_name_english TEXT
);

CREATE TABLE products (
    product_id                 TEXT PRIMARY KEY,
    product_category_name      TEXT REFERENCES category_translation(product_category_name), 
    product_name_lenght        INTEGER,          
    product_description_lenght INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           REAL,
    product_length_cm          REAL,
    product_height_cm          REAL,
    product_width_cm           REAL
);

CREATE TABLE orders (
    order_id                      TEXT PRIMARY KEY,
    customer_id                   TEXT NOT NULL REFERENCES customers(customer_id),
    order_status                  TEXT,
    order_purchase_timestamp      TEXT,
    order_approved_at             TEXT,
    order_delivered_carrier_date  TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

CREATE TABLE order_items (
    order_id            TEXT    NOT NULL REFERENCES orders(order_id),
    order_item_id       INTEGER NOT NULL,          
    product_id          TEXT    NOT NULL REFERENCES products(product_id),
    seller_id           TEXT    NOT NULL REFERENCES sellers(seller_id),
    shipping_limit_date TEXT,
    price               REAL,
    freight_value       REAL,
    PRIMARY KEY (order_id, order_item_id)         
);

CREATE TABLE order_reviews (
    review_id               TEXT NOT NULL,
    order_id                TEXT NOT NULL REFERENCES orders(order_id),
    review_score            INTEGER,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT,
    PRIMARY KEY (review_id, order_id)             
);


-- Q1a: row count per table
SELECT 'orders'               AS table_name, COUNT(*) AS row_count FROM orders
UNION ALL SELECT 'order_items',          COUNT(*) FROM order_items
UNION ALL SELECT 'products',             COUNT(*) FROM products
UNION ALL SELECT 'order_reviews',        COUNT(*) FROM order_reviews
UNION ALL SELECT 'sellers',              COUNT(*) FROM sellers
UNION ALL SELECT 'customers',            COUNT(*) FROM customers
UNION ALL SELECT 'category_translation', COUNT(*) FROM category_translation;


-- Q1b: join cardinality orders 
WITH items_per_order AS (
    SELECT o.order_id,
           COUNT(i.order_item_id) AS n_items
    FROM orders o
    LEFT JOIN order_items i ON i.order_id = o.order_id
    GROUP BY o.order_id
)
SELECT COUNT(*)                                       AS orders,
       SUM(n_items)                                   AS order_items,
       ROUND(AVG(n_items), 3)                         AS avg_items_per_order_all,
       ROUND(AVG(CASE WHEN n_items > 0 THEN n_items END), 3) AS avg_items_per_order_with_items,
       SUM(n_items = 0)                               AS orders_with_0_items,
       SUM(n_items = 1)                               AS orders_with_1_item,
       SUM(n_items > 1)                               AS orders_with_2plus_items,
       MAX(n_items)                                   AS max_items_in_one_order
FROM items_per_order;


-- Q2: analytical base table as a VIEW (bonus: every KPI query below reads from it)
CREATE VIEW v_base AS
WITH

delivered_orders AS (
    SELECT order_id, customer_id, order_purchase_timestamp,
           order_delivered_customer_date, order_estimated_delivery_date
    FROM orders
    WHERE order_status = 'delivered'
),

order_lines AS (
    SELECT o.*, i.order_item_id, i.product_id, i.seller_id, i.price, i.freight_value
    FROM delivered_orders o
    INNER JOIN order_items i ON i.order_id = o.order_id
),

order_lines_category AS (
    SELECT l.*,
           COALESCE(t.product_category_name_english,
                    p.product_category_name,
                    'unknown') AS category
    FROM order_lines l
    LEFT JOIN products             p ON p.product_id = l.product_id
    LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name
),

review_per_order AS (
    SELECT order_id,
           AVG(review_score) AS review_score,
           COUNT(*)          AS n_reviews
    FROM order_reviews
    GROUP BY order_id
)

SELECT c.order_id,
       c.customer_id,
       c.order_item_id,
       c.product_id,
       c.seller_id,
       c.price,
       c.freight_value,
       c.category,
       c.order_purchase_timestamp,
       strftime('%Y-%m', c.order_purchase_timestamp)                AS purchase_month,
       julianday(c.order_delivered_customer_date)
         - julianday(c.order_purchase_timestamp)                    AS delivery_days,  -- NULL for 8 orders with no delivered date
       CASE WHEN c.order_delivered_customer_date IS NULL THEN NULL
            WHEN date(c.order_delivered_customer_date)
                 <= date(c.order_estimated_delivery_date) THEN 1
            ELSE 0 END                                              AS on_time,
       r.review_score,
       r.n_reviews
FROM order_lines_category c
LEFT JOIN review_per_order r ON r.order_id = c.order_id;


-- Q2b: join audit
SELECT 1 AS step, 'delivered orders'                    AS join_step, 'filter'     AS join_type,
       (SELECT COUNT(*) FROM orders WHERE order_status = 'delivered') AS rows_after,
       (SELECT COUNT(*) FROM orders WHERE order_status = 'delivered') AS orders_after
UNION ALL
SELECT 2, '+ order_items', 'INNER',
       (SELECT COUNT(*) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         WHERE o.order_status = 'delivered'),
       (SELECT COUNT(DISTINCT o.order_id) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         WHERE o.order_status = 'delivered')
UNION ALL
SELECT 3, '+ products', 'LEFT',
       (SELECT COUNT(*) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         LEFT JOIN products p ON p.product_id = i.product_id
         WHERE o.order_status = 'delivered'),
       (SELECT COUNT(DISTINCT o.order_id) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         LEFT JOIN products p ON p.product_id = i.product_id
         WHERE o.order_status = 'delivered')
UNION ALL
SELECT 4, '+ category_translation', 'LEFT',
       (SELECT COUNT(*) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         LEFT JOIN products p ON p.product_id = i.product_id
         LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name
         WHERE o.order_status = 'delivered'),
       (SELECT COUNT(DISTINCT o.order_id) FROM orders o JOIN order_items i ON i.order_id = o.order_id
         LEFT JOIN products p ON p.product_id = i.product_id
         LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name
         WHERE o.order_status = 'delivered')
UNION ALL
SELECT 5, '+ reviews (1 row per order) = v_base', 'LEFT',
       (SELECT COUNT(*) FROM v_base),
       (SELECT COUNT(DISTINCT order_id) FROM v_base);


-- Q2c: what each join drops or leaves NULL 
SELECT
    (SELECT COUNT(*) FROM orders o
      WHERE o.order_status = 'delivered'
        AND NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.order_id))
                                                        AS delivered_orders_dropped_by_inner_items,
    (SELECT COUNT(*) FROM v_base b
      WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = b.product_id))
                                                        AS items_without_product_row,
    (SELECT COUNT(*) FROM v_base WHERE category = 'unknown')
                                                        AS items_with_no_category,
    (SELECT COUNT(*) FROM v_base b JOIN products p ON p.product_id = b.product_id
      LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name
      WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL)
                                                        AS items_with_untranslated_category,
    (SELECT COUNT(DISTINCT order_id) FROM v_base WHERE review_score IS NULL)
                                                        AS delivered_orders_without_review,
    (SELECT COUNT(DISTINCT order_id) FROM v_base WHERE n_reviews > 1)
                                                        AS delivered_orders_with_2plus_reviews;


-- Q3: RECONCILIATION - total revenue computed several ways
WITH
a_all AS (
    SELECT SUM(price) AS revenue FROM order_items
),
a_delivered AS (
    SELECT SUM(i.price) AS revenue
    FROM order_items i
    JOIN orders o ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
),
b_naive AS (
    SELECT SUM(i.price) AS revenue, COUNT(*) AS n_rows
    FROM orders o
    JOIN order_items i        ON i.order_id = o.order_id
    LEFT JOIN products p      ON p.product_id = i.product_id
    LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name
    LEFT JOIN order_reviews r ON r.order_id = o.order_id          
    WHERE o.order_status = 'delivered'
),
b_fixed AS (
    SELECT SUM(price) AS revenue, COUNT(*) AS n_rows FROM v_base
)
SELECT '(a) order_items, all statuses'            AS method, ROUND(revenue, 2) AS revenue, NULL AS n_rows,
       ROUND(revenue - (SELECT revenue FROM a_delivered), 2) AS diff_vs_a_delivered FROM a_all
UNION ALL
SELECT '(a) order_items, delivered only',          ROUND(revenue, 2),
       (SELECT COUNT(*) FROM order_items i JOIN orders o ON o.order_id = i.order_id
         WHERE o.order_status = 'delivered'),
       0 FROM a_delivered
UNION ALL
SELECT '(b1) naive join with raw reviews',         ROUND(revenue, 2), n_rows,
       ROUND(revenue - (SELECT revenue FROM a_delivered), 2) FROM b_naive
UNION ALL
SELECT '(b2) v_base, reviews 1 row per order',      ROUND(revenue, 2), n_rows,
       ROUND(revenue - (SELECT revenue FROM a_delivered), 2) FROM b_fixed;


-- Q3b:
WITH review_counts AS (
    SELECT order_id, COUNT(*) AS n_reviews FROM order_reviews GROUP BY order_id
)
SELECT rc.n_reviews,
       COUNT(DISTINCT i.order_id)                    AS delivered_orders,
       ROUND(SUM(i.price), 2)                        AS true_revenue,
       ROUND(SUM(i.price * rc.n_reviews), 2)         AS revenue_after_naive_join,
       ROUND(SUM(i.price * (rc.n_reviews - 1)), 2)   AS extra_revenue
FROM order_items i
JOIN orders o         ON o.order_id = i.order_id AND o.order_status = 'delivered'
JOIN review_counts rc ON rc.order_id = i.order_id
GROUP BY rc.n_reviews
ORDER BY rc.n_reviews;


-- Q4: core KPIs overall (delivered orders only)
WITH per_order AS (
    SELECT order_id,
           SUM(price)         AS revenue,
           MAX(delivery_days) AS delivery_days,   -- same value on every item row of the order
           MAX(review_score)  AS review_score
    FROM v_base
    GROUP BY order_id
)
SELECT COUNT(*)                               AS orders,
       ROUND(SUM(revenue), 2)                 AS total_revenue,
       ROUND(SUM(revenue) / COUNT(*), 2)      AS aov,
       ROUND(AVG(delivery_days), 2)           AS avg_delivery_days,
       ROUND(AVG(review_score), 3)            AS avg_review_score
FROM per_order;


-- Q5: the four KPIs by English category, with order count, ordered by revenue
WITH per_order_category AS (
    SELECT category, order_id,
           SUM(price)         AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score)  AS review_score
    FROM v_base
    GROUP BY category, order_id
)
SELECT category,
       COUNT(*)                          AS order_count,
       ROUND(SUM(revenue), 2)            AS total_revenue,
       ROUND(SUM(revenue) / COUNT(*), 2) AS aov,
       ROUND(AVG(delivery_days), 2)      AS avg_delivery_days,
       ROUND(AVG(review_score), 3)       AS avg_review_score
FROM per_order_category
GROUP BY category
ORDER BY total_revenue DESC;


-- Q6: the four KPIs by purchase month
WITH per_order AS (
    SELECT purchase_month, order_id,
           SUM(price)         AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score)  AS review_score
    FROM v_base
    GROUP BY purchase_month, order_id
)
SELECT purchase_month,
       COUNT(*)                          AS order_count,
       ROUND(SUM(revenue), 2)            AS total_revenue,
       ROUND(SUM(revenue) / COUNT(*), 2) AS aov,
       ROUND(AVG(delivery_days), 2)      AS avg_delivery_days,
       ROUND(AVG(review_score), 3)       AS avg_review_score
FROM per_order
GROUP BY purchase_month
ORDER BY purchase_month;


-- Q7: top 5 and bottom 5 categories by revenue
WITH per_order_category AS (
    SELECT category, order_id, SUM(price) AS revenue
    FROM v_base
    GROUP BY category, order_id
),
category_revenue AS (
    SELECT category,
           COUNT(*)               AS order_count,
           ROUND(SUM(revenue), 2) AS total_revenue
    FROM per_order_category
    GROUP BY category
    HAVING COUNT(DISTINCT order_id) >= 100
),
ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY total_revenue DESC) AS rank_top,
           RANK() OVER (ORDER BY total_revenue ASC)  AS rank_bottom
    FROM category_revenue
)
SELECT CASE WHEN rank_top <= 5 THEN 'top 5' ELSE 'bottom 5' END AS segment,
       category, order_count, total_revenue
FROM ranked
WHERE rank_top <= 5 OR rank_bottom <= 5
ORDER BY total_revenue DESC;


-- Q8: top 5 and bottom 5 categories by average review score
WITH category_score AS (
    SELECT category,
           COUNT(DISTINCT order_id) AS order_count,
           ROUND(AVG(order_score), 3) AS avg_review_score
    FROM (SELECT category, order_id, MAX(review_score) AS order_score
          FROM v_base GROUP BY category, order_id)
    GROUP BY category
    HAVING COUNT(DISTINCT order_id) >= 100
),
ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY avg_review_score DESC) AS rank_top,
           RANK() OVER (ORDER BY avg_review_score ASC)  AS rank_bottom
    FROM category_score
)
SELECT CASE WHEN rank_top <= 5 THEN 'top 5' ELSE 'bottom 5' END AS segment,
       category, order_count, avg_review_score
FROM ranked
WHERE rank_top <= 5 OR rank_bottom <= 5
ORDER BY avg_review_score DESC;


-- Q9: seller KPIs ranked by revenue with RANK()
WITH per_seller_order AS (
    SELECT seller_id, order_id,
           SUM(price)         AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score)  AS review_score
    FROM v_base
    GROUP BY seller_id, order_id
),
seller_kpi AS (
    SELECT seller_id,
           COUNT(*)                     AS order_count,
           SUM(revenue)                 AS total_revenue,
           AVG(review_score)            AS avg_review_score,
           AVG(delivery_days)           AS avg_delivery_days
    FROM per_seller_order
    GROUP BY seller_id
)
SELECT RANK() OVER (ORDER BY k.total_revenue DESC)                     AS revenue_rank,
       k.seller_id,
       s.seller_city,
       s.seller_state,
       k.order_count,
       ROUND(k.total_revenue, 2)                                       AS total_revenue,
       ROUND(k.avg_review_score, 3)                                    AS avg_review_score,
       ROUND(k.avg_delivery_days, 2)                                   AS avg_delivery_days,
       ROUND(100.0 * k.total_revenue / SUM(k.total_revenue) OVER (), 3) AS revenue_share_pct,
       ROUND(100.0 * SUM(k.total_revenue) OVER (ORDER BY k.total_revenue DESC
                                                ROWS UNBOUNDED PRECEDING)
                   / SUM(k.total_revenue) OVER (), 2)                  AS cumulative_share_pct
FROM seller_kpi k
LEFT JOIN sellers s ON s.seller_id = k.seller_id
ORDER BY revenue_rank;


-- Q10: per category - avg delivery days and avg review score side by side
WITH per_order_category AS (
    SELECT category, order_id,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score)  AS review_score
    FROM v_base
    GROUP BY category, order_id
)
SELECT category,
       COUNT(*)                     AS order_count,
       ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
       ROUND(AVG(review_score), 3)  AS avg_review_score
FROM per_order_category
GROUP BY category
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY avg_delivery_days DESC;


-- B2: on-time delivery rate 
WITH per_order AS (
    SELECT order_id, MAX(on_time) AS on_time, MAX(review_score) AS review_score,
           MAX(delivery_days) AS delivery_days
    FROM v_base
    GROUP BY order_id
)
SELECT CASE on_time WHEN 1 THEN 'on time' WHEN 0 THEN 'late' ELSE 'no delivery date' END AS delivery_status,
       COUNT(*)                                            AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS share_pct,
       ROUND(AVG(delivery_days), 2)                        AS avg_delivery_days,
       ROUND(AVG(review_score), 3)                         AS avg_review_score
FROM per_order
GROUP BY on_time
ORDER BY orders DESC;


-- B3: anti-join - orders that never received a review
SELECT o.order_status,
       COUNT(*)                                                        AS orders,
       SUM(r.order_id IS NULL)                                         AS orders_without_review,
       ROUND(100.0 * SUM(r.order_id IS NULL) / COUNT(*), 2)            AS share_without_review_pct
FROM orders o
LEFT JOIN (SELECT DISTINCT order_id FROM order_reviews) r ON r.order_id = o.order_id
GROUP BY o.order_status
UNION ALL
SELECT 'ALL',
       COUNT(*),
       SUM(r.order_id IS NULL),
       ROUND(100.0 * SUM(r.order_id IS NULL) / COUNT(*), 2)
FROM orders o
LEFT JOIN (SELECT DISTINCT order_id FROM order_reviews) r ON r.order_id = o.order_id
ORDER BY orders DESC;


-- B4: freight-cost-to-revenue ratio per category
SELECT category,
       COUNT(DISTINCT order_id)                       AS order_count,
       ROUND(SUM(price), 2)                           AS total_revenue,
       ROUND(SUM(freight_value), 2)                   AS total_freight,
       ROUND(100.0 * SUM(freight_value) / SUM(price), 2) AS freight_to_revenue_pct,
       CASE WHEN SUM(freight_value) / SUM(price) >= 0.25
            THEN 'shipping erodes margin' ELSE 'ok' END  AS flag
FROM v_base
GROUP BY category
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY freight_to_revenue_pct DESC;


-- B5: each category's share of monthly revenue (window function) and its change vs last month
WITH monthly_category AS (
    SELECT purchase_month, category, SUM(price) AS revenue
    FROM v_base
    GROUP BY purchase_month, category
),
valid_months AS (
    SELECT purchase_month
    FROM v_base
    GROUP BY purchase_month
    HAVING COUNT(DISTINCT order_id) >= 100
),
shares AS (
    SELECT m.purchase_month, m.category, m.revenue,
           100.0 * m.revenue / SUM(m.revenue) OVER (PARTITION BY m.purchase_month) AS share_pct
    FROM monthly_category m
    JOIN valid_months v ON v.purchase_month = m.purchase_month
)
SELECT purchase_month,
       category,
       ROUND(revenue, 2)   AS revenue,
       ROUND(share_pct, 2) AS share_pct,
       ROUND(share_pct - LAG(share_pct) OVER (PARTITION BY category ORDER BY purchase_month), 2)
                           AS share_change_pp
FROM shares
ORDER BY purchase_month, share_pct DESC;
