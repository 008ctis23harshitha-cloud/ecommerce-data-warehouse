"""
ETL: Olist SQLite -> MySQL star schema (database: olist_dw)

Run from the project root:
    python etl/load_warehouse.py

Steps: Extract (SQLite) -> Transform (pandas) -> Load (MySQL).
Safe to re-run: all warehouse tables are emptied first.
"""
import getpass
import sqlite3
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

SQLITE_PATH = Path(__file__).resolve().parent.parent / "data" / "olist.sqlite"
DB_NAME = "olist_dw"
CHUNK = 5000

SOURCE_TABLES = [
    "customers",
    "sellers",
    "products",
    "product_category_name_translation",
    "orders",
    "order_items",
    "order_payments",
    "order_reviews",
]

# Child tables first, so foreign keys are never violated when clearing
WAREHOUSE_TABLES = [
    "fact_reviews",
    "fact_payments",
    "fact_order_items",
    "dim_date",
    "dim_product",
    "dim_seller",
    "dim_customer",
]


# ---------------------------------------------------------------- helpers
def get_engine():
    user = input("MySQL user [root]: ").strip() or "root"
    password = getpass.getpass("MySQL password (typing is hidden): ")
    host = input("MySQL host [localhost]: ").strip() or "localhost"
    url = URL.create(
        "mysql+pymysql",
        username=user,
        password=password,
        host=host,
        port=3306,
        database=DB_NAME,
    )
    return create_engine(url)


def load(engine, df, table):
    df.to_sql(table, engine, if_exists="append", index=False, chunksize=CHUNK)
    print(f"  loaded {len(df):,} rows into {table}")


def clear_tables(engine):
    with engine.begin() as conn:
        conn.execute(text("SET FOREIGN_KEY_CHECKS = 0"))
        for t in WAREHOUSE_TABLES:
            conn.execute(text(f"TRUNCATE TABLE {t}"))
        conn.execute(text("SET FOREIGN_KEY_CHECKS = 1"))
    print("Cleared existing warehouse tables.")


def zip_prefix(series):
    return series.astype(str).str.zfill(5)


def key_map(engine, table, key_col, business_col):
    return pd.read_sql(f"SELECT {key_col}, {business_col} FROM {table}", engine)


# ---------------------------------------------------------------- extract
def extract():
    if not SQLITE_PATH.exists():
        raise SystemExit(f"Cannot find {SQLITE_PATH}")
    con = sqlite3.connect(SQLITE_PATH)
    data = {name: pd.read_sql(f"SELECT * FROM {name}", con) for name in SOURCE_TABLES}
    con.close()
    for name, df in data.items():
        print(f"  extracted {len(df):>9,} rows from {name}")
    return data


# -------------------------------------------------------------- transform
def build_dim_date(start, end):
    days = pd.date_range(start, end, freq="D")
    return pd.DataFrame(
        {
            "date_key": days.strftime("%Y%m%d").astype(int),
            "full_date": days.date,
            "day": days.day,
            "month": days.month,
            "month_name": days.strftime("%B"),
            "quarter": days.quarter,
            "year": days.year,
            "weekday_name": days.strftime("%A"),
            "is_weekend": (days.dayofweek >= 5).astype(int),
        }
    )


def build_dim_customer(customers):
    return pd.DataFrame(
        {
            "customer_id": customers["customer_id"],
            "customer_unique_id": customers["customer_unique_id"],
            "zip_code_prefix": zip_prefix(customers["customer_zip_code_prefix"]),
            "city": customers["customer_city"].str.title(),
            "state": customers["customer_state"].str.upper(),
        }
    ).drop_duplicates(subset="customer_id")


def build_dim_seller(sellers):
    return pd.DataFrame(
        {
            "seller_id": sellers["seller_id"],
            "zip_code_prefix": zip_prefix(sellers["seller_zip_code_prefix"]),
            "city": sellers["seller_city"].str.title(),
            "state": sellers["seller_state"].str.upper(),
        }
    ).drop_duplicates(subset="seller_id")


def build_dim_product(products, translation):
    p = products.merge(translation, on="product_category_name", how="left")
    return pd.DataFrame(
        {
            "product_id": p["product_id"],
            "category_name_pt": p["product_category_name"].fillna("unknown"),
            # fall back to the Portuguese name when no translation exists
            "category_name_en": p["product_category_name_english"]
            .fillna(p["product_category_name"])
            .fillna("unknown"),
            "photos_qty": p["product_photos_qty"].astype("Int64"),
            "weight_g": p["product_weight_g"].astype("Int64"),
            "length_cm": p["product_length_cm"].astype("Int64"),
            "height_cm": p["product_height_cm"].astype("Int64"),
            "width_cm": p["product_width_cm"].astype("Int64"),
        }
    ).drop_duplicates(subset="product_id")


def prepare_orders(orders):
    orders = orders.copy()
    for col in [
        "order_purchase_timestamp",
        "order_delivered_customer_date",
        "order_estimated_delivery_date",
    ]:
        orders[col] = pd.to_datetime(orders[col], errors="coerce")
    return orders.dropna(subset=["order_purchase_timestamp"])


def build_fact_order_items(items, orders, cust_map, prod_map, sell_map):
    o = orders[
        [
            "order_id",
            "customer_id",
            "order_status",
            "order_purchase_timestamp",
            "order_delivered_customer_date",
            "order_estimated_delivery_date",
        ]
    ]
    df = items.merge(o, on="order_id", how="inner")
    df = (
        df.merge(cust_map, on="customer_id", how="inner")
        .merge(prod_map, on="product_id", how="inner")
        .merge(sell_map, on="seller_id", how="inner")
    )

    purchase = df["order_purchase_timestamp"]
    delivered = df["order_delivered_customer_date"]
    estimated = df["order_estimated_delivery_date"]

    late = (delivered.dt.normalize() > estimated.dt.normalize()).astype("Int64")
    late = late.where(delivered.notna())  # NULL when not delivered

    return pd.DataFrame(
        {
            "order_id": df["order_id"],
            "order_item_id": df["order_item_id"],
            "customer_key": df["customer_key"],
            "product_key": df["product_key"],
            "seller_key": df["seller_key"],
            "purchase_date_key": purchase.dt.strftime("%Y%m%d").astype(int),
            "delivered_date_key": pd.to_numeric(
                delivered.dt.strftime("%Y%m%d"), errors="coerce"
            ).astype("Int64"),
            "order_status": df["order_status"],
            "purchase_ts": purchase,
            "delivered_ts": delivered,
            "estimated_delivery_dt": estimated.dt.date,
            "price": df["price"].round(2),
            "freight_value": df["freight_value"].round(2),
            "total_item_value": (df["price"] + df["freight_value"]).round(2),
            "delivery_days": (delivered - purchase).dt.days.astype("Int64"),
            "is_late": late,
        }
    )


def build_fact_payments(payments, orders, cust_map):
    o = orders[["order_id", "customer_id", "order_purchase_timestamp"]]
    df = payments.merge(o, on="order_id", how="inner").merge(
        cust_map, on="customer_id", how="inner"
    )
    return pd.DataFrame(
        {
            "order_id": df["order_id"],
            "payment_sequential": df["payment_sequential"],
            "customer_key": df["customer_key"],
            "purchase_date_key": df["order_purchase_timestamp"]
            .dt.strftime("%Y%m%d")
            .astype(int),
            "payment_type": df["payment_type"],
            "payment_installments": df["payment_installments"],
            "payment_value": df["payment_value"].round(2),
        }
    )


def build_fact_reviews(reviews, orders, cust_map):
    r = reviews.copy()
    r["review_creation_date"] = pd.to_datetime(r["review_creation_date"], errors="coerce")
    r["review_answer_timestamp"] = pd.to_datetime(
        r["review_answer_timestamp"], errors="coerce"
    )
    r = r.dropna(subset=["review_creation_date"])
    df = r.merge(orders[["order_id", "customer_id"]], on="order_id", how="inner").merge(
        cust_map, on="customer_id", how="inner"
    )
    has_comment = (
        df["review_comment_message"].fillna("").str.strip().ne("").astype(int)
    )
    return pd.DataFrame(
        {
            "review_id": df["review_id"],
            "order_id": df["order_id"],
            "customer_key": df["customer_key"],
            "review_date_key": df["review_creation_date"].dt.strftime("%Y%m%d").astype(int),
            "review_score": df["review_score"],
            "has_comment": has_comment,
            "answer_ts": df["review_answer_timestamp"],
        }
    )


# ------------------------------------------------------------------- main
def main():
    print("1. EXTRACT")
    data = extract()

    engine = get_engine()
    clear_tables(engine)

    print("2. TRANSFORM + LOAD dimensions")
    orders = prepare_orders(data["orders"])

    reviews_dates = pd.to_datetime(
        data["order_reviews"]["review_creation_date"], errors="coerce"
    )
    all_dates = pd.concat(
        [
            orders["order_purchase_timestamp"],
            orders["order_delivered_customer_date"],
            orders["order_estimated_delivery_date"],
            reviews_dates,
        ]
    ).dropna()
    start = pd.Timestamp(year=all_dates.min().year, month=1, day=1)
    end = pd.Timestamp(year=all_dates.max().year, month=12, day=31)

    load(engine, build_dim_date(start, end), "dim_date")
    load(engine, build_dim_customer(data["customers"]), "dim_customer")
    load(engine, build_dim_seller(data["sellers"]), "dim_seller")
    load(
        engine,
        build_dim_product(data["products"], data["product_category_name_translation"]),
        "dim_product",
    )

    # surrogate keys generated by MySQL, read back to link the facts
    cust_map = key_map(engine, "dim_customer", "customer_key", "customer_id")
    prod_map = key_map(engine, "dim_product", "product_key", "product_id")
    sell_map = key_map(engine, "dim_seller", "seller_key", "seller_id")

    print("3. TRANSFORM + LOAD facts")
    load(
        engine,
        build_fact_order_items(data["order_items"], orders, cust_map, prod_map, sell_map),
        "fact_order_items",
    )
    load(
        engine,
        build_fact_payments(data["order_payments"], orders, cust_map),
        "fact_payments",
    )
    load(
        engine,
        build_fact_reviews(data["order_reviews"], orders, cust_map),
        "fact_reviews",
    )

    print("4. VERIFY")
    with engine.connect() as conn:
        for t in reversed(WAREHOUSE_TABLES):
            n = conn.execute(text(f"SELECT COUNT(*) FROM {t}")).scalar()
            print(f"  {t:<18} {n:>9,} rows")
        wh_revenue = conn.execute(
            text("SELECT ROUND(SUM(price), 2) FROM fact_order_items")
        ).scalar()
    src_revenue = round(float(data["order_items"]["price"].sum()), 2)
    print(f"  source item revenue:    {src_revenue:,.2f}")
    print(f"  warehouse item revenue: {float(wh_revenue):,.2f}")
    print("  MATCH" if abs(src_revenue - float(wh_revenue)) < 0.01 else "  MISMATCH - check data")
    print("Done.")


if __name__ == "__main__":
    main()
