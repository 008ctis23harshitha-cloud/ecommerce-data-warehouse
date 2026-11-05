-- Olist E-Commerce Data Warehouse: star schema (MySQL 8 / MySQL Workbench)
-- Run in Workbench: File > Open SQL Script > create_schema.sql > lightning bolt
--
-- Facts:       fact_order_items (grain: one order item), fact_payments, fact_reviews
-- Dimensions:  dim_customer, dim_seller, dim_product, dim_date

CREATE DATABASE IF NOT EXISTS olist_dw;
USE olist_dw;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS fact_reviews;
DROP TABLE IF EXISTS fact_payments;
DROP TABLE IF EXISTS fact_order_items;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_customer;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------- Dimensions ----------

CREATE TABLE dim_customer (
    customer_key        INT AUTO_INCREMENT PRIMARY KEY,
    customer_id         VARCHAR(32) NOT NULL UNIQUE,   -- per-order id from source
    customer_unique_id  VARCHAR(32) NOT NULL,          -- the real person
    zip_code_prefix     VARCHAR(10),
    city                VARCHAR(100),
    state               CHAR(2),
    INDEX idx_customer_unique (customer_unique_id)
);

CREATE TABLE dim_seller (
    seller_key          INT AUTO_INCREMENT PRIMARY KEY,
    seller_id           VARCHAR(32) NOT NULL UNIQUE,
    zip_code_prefix     VARCHAR(10),
    city                VARCHAR(100),
    state               CHAR(2)
);

CREATE TABLE dim_product (
    product_key         INT AUTO_INCREMENT PRIMARY KEY,
    product_id          VARCHAR(32) NOT NULL UNIQUE,
    category_name_pt    VARCHAR(100),                  -- original Portuguese
    category_name_en    VARCHAR(100),                  -- from translation table
    photos_qty          SMALLINT,
    weight_g            INT,
    length_cm           SMALLINT,
    height_cm           SMALLINT,
    width_cm            SMALLINT
);

CREATE TABLE dim_date (
    date_key            INT PRIMARY KEY,               -- format YYYYMMDD
    full_date           DATE NOT NULL UNIQUE,
    day                 TINYINT NOT NULL,
    month               TINYINT NOT NULL,
    month_name          VARCHAR(10) NOT NULL,
    quarter             TINYINT NOT NULL,
    year                SMALLINT NOT NULL,
    weekday_name        VARCHAR(10) NOT NULL,
    is_weekend          BOOLEAN NOT NULL
);

-- ---------- Facts ----------

CREATE TABLE fact_order_items (
    order_item_key        BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id              VARCHAR(32) NOT NULL,
    order_item_id         SMALLINT NOT NULL,           -- line number within the order
    customer_key          INT NOT NULL,
    product_key           INT NOT NULL,
    seller_key            INT NOT NULL,
    purchase_date_key     INT NOT NULL,
    delivered_date_key    INT NULL,                    -- NULL if not delivered
    order_status          VARCHAR(20) NOT NULL,
    purchase_ts           DATETIME NOT NULL,
    delivered_ts          DATETIME NULL,
    estimated_delivery_dt DATE NULL,
    price                 DECIMAL(10, 2) NOT NULL,
    freight_value         DECIMAL(10, 2) NOT NULL,
    total_item_value      DECIMAL(10, 2) NOT NULL,     -- price + freight_value
    delivery_days         INT NULL,                    -- delivered - purchase
    is_late               BOOLEAN NULL,                -- delivered after estimate
    UNIQUE KEY uq_order_item (order_id, order_item_id),
    FOREIGN KEY (customer_key)       REFERENCES dim_customer (customer_key),
    FOREIGN KEY (product_key)        REFERENCES dim_product (product_key),
    FOREIGN KEY (seller_key)         REFERENCES dim_seller (seller_key),
    FOREIGN KEY (purchase_date_key)  REFERENCES dim_date (date_key),
    FOREIGN KEY (delivered_date_key) REFERENCES dim_date (date_key),
    INDEX idx_foi_customer (customer_key),
    INDEX idx_foi_product  (product_key),
    INDEX idx_foi_seller   (seller_key),
    INDEX idx_foi_date     (purchase_date_key)
);

CREATE TABLE fact_payments (
    payment_key           BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id              VARCHAR(32) NOT NULL,
    payment_sequential    SMALLINT NOT NULL,
    customer_key          INT NOT NULL,
    purchase_date_key     INT NOT NULL,
    payment_type          VARCHAR(20) NOT NULL,
    payment_installments  SMALLINT NOT NULL,
    payment_value         DECIMAL(10, 2) NOT NULL,
    UNIQUE KEY uq_payment (order_id, payment_sequential),
    FOREIGN KEY (customer_key)      REFERENCES dim_customer (customer_key),
    FOREIGN KEY (purchase_date_key) REFERENCES dim_date (date_key),
    INDEX idx_pay_customer (customer_key),
    INDEX idx_pay_date     (purchase_date_key)
);

CREATE TABLE fact_reviews (
    review_key            BIGINT AUTO_INCREMENT PRIMARY KEY,
    review_id             VARCHAR(32) NOT NULL,        -- not unique in source data
    order_id              VARCHAR(32) NOT NULL,
    customer_key          INT NOT NULL,
    review_date_key       INT NOT NULL,
    review_score          TINYINT NOT NULL,            -- 1 to 5
    has_comment           BOOLEAN NOT NULL,
    answer_ts             DATETIME NULL,
    FOREIGN KEY (customer_key)    REFERENCES dim_customer (customer_key),
    FOREIGN KEY (review_date_key) REFERENCES dim_date (date_key),
    INDEX idx_rev_order    (order_id),
    INDEX idx_rev_customer (customer_key),
    INDEX idx_rev_date     (review_date_key)
);
