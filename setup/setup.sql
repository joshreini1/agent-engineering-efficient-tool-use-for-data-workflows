-- Provision the Lesson 1 lab in a Snowflake account, from nothing.
--
--   uvx --from snowflake-cli snow sql -c <connection> -f setup/setup.sql
--
-- Run it as a role that can create databases, warehouses and roles, such as
-- ACCOUNTADMIN. It is idempotent: every statement is IF NOT EXISTS, and the tables are
-- created without touching any rows that are already there, so re-running is safe.
--
-- This creates the objects and the empty tables. It does not load data, because the rows
-- come from the data-eng-bench dataset rather than from this repository. After running
-- this, load the data with:
--
--   setup/export_data.sh <source-connection>   # once, from an account that has the data
--   setup/load_data.sh   <target-connection>   # into the new account
--
-- See setup/README.md for the two paths and why the data is not committed here.

-- ---------------------------------------------------------------------------
-- Database and schemas
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS DLAI_AGENT_ENGINEERING
  COMMENT = 'DeepLearning.AI Agent Engineering for Data Tasks';

USE DATABASE DLAI_AGENT_ENGINEERING;

-- Source data. Read-only to the lab role, so no experiment can mutate it.
CREATE SCHEMA IF NOT EXISTS L1_FX_SOURCE
  COMMENT = 'Lesson 1 source data (FX settlement-date task)';

-- Working schema. Views over the source plus the table the agent builds.
CREATE SCHEMA IF NOT EXISTS L1_LAB
  COMMENT = 'Lesson 1 working schema, reset between experiments';

-- Snowflake creates PUBLIC with every database and the lab never uses it.
DROP SCHEMA IF EXISTS DLAI_AGENT_ENGINEERING.PUBLIC;

-- ---------------------------------------------------------------------------
-- Warehouse
-- ---------------------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS DLAI_LAB_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'DeepLearning.AI Agent Engineering lab';

-- ---------------------------------------------------------------------------
-- Role
--
-- The lab runs coding agents with permissions bypassed and no approval prompts, so this
-- grant set is the backstop: an agent can read the source and write only to L1_LAB.
-- CREATE SCHEMA is needed because reset_lab.sql and the batch runner create schemas.
-- ---------------------------------------------------------------------------

CREATE ROLE IF NOT EXISTS DLAI_LAB_RL
  COMMENT = 'Lesson 1 lab: read-only on the source, read-write on the working schema';

GRANT USAGE ON WAREHOUSE DLAI_LAB_WH TO ROLE DLAI_LAB_RL;
GRANT USAGE ON DATABASE DLAI_AGENT_ENGINEERING TO ROLE DLAI_LAB_RL;
GRANT CREATE SCHEMA ON DATABASE DLAI_AGENT_ENGINEERING TO ROLE DLAI_LAB_RL;

GRANT USAGE ON SCHEMA DLAI_AGENT_ENGINEERING.L1_FX_SOURCE TO ROLE DLAI_LAB_RL;
GRANT SELECT ON ALL TABLES IN SCHEMA DLAI_AGENT_ENGINEERING.L1_FX_SOURCE TO ROLE DLAI_LAB_RL;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DLAI_AGENT_ENGINEERING.L1_FX_SOURCE TO ROLE DLAI_LAB_RL;

GRANT ALL ON SCHEMA DLAI_AGENT_ENGINEERING.L1_LAB TO ROLE DLAI_LAB_RL;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA DLAI_AGENT_ENGINEERING.L1_LAB TO ROLE DLAI_LAB_RL;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DLAI_AGENT_ENGINEERING.L1_LAB TO ROLE DLAI_LAB_RL;

-- Grant the role to whoever will run the lab. Set this to your own user.
SET lab_user = CURRENT_USER();
GRANT ROLE DLAI_LAB_RL TO USER IDENTIFIER($lab_user);

-- ---------------------------------------------------------------------------
-- Source tables, empty
--
-- Column types are exact, and they matter: PROCESSED_AT is TIMESTAMP_NTZ, and the whole
-- task turns on it resolving to the right settlement date. Loading it as a string or a
-- date silently changes the answer.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS L1_FX_SOURCE.FCT_SALES (
	ORDER_LINE_ID VARCHAR(16777216),
	ORDER_ID VARCHAR(16777216),
	LINE_NUMBER NUMBER(38,0),
	CUSTOMER_ID VARCHAR(16777216),
	PRODUCT_ID VARCHAR(16777216),
	SKU VARCHAR(16777216),
	SOURCE_SYSTEM VARCHAR(16777216),
	CURRENCY_CODE VARCHAR(16777216),
	ORDER_NUMBER VARCHAR(16777216),
	ORDER_TYPE VARCHAR(16777216),
	ORDER_STATUS VARCHAR(16777216),
	PAYMENT_STATUS VARCHAR(16777216),
	FULFILLMENT_STATUS VARCHAR(16777216),
	PRODUCT_NAME VARCHAR(16777216),
	VARIANT_NAME VARCHAR(16777216),
	QUANTITY_ORDERED NUMBER(10,2),
	QUANTITY_SHIPPED NUMBER(10,2),
	QUANTITY_BACKORDER NUMBER(11,2),
	UNIT_PRICE NUMBER(18,2),
	EXTENDED_PRICE NUMBER(18,2),
	DISCOUNT_AMOUNT NUMBER(18,2),
	TAX_AMOUNT NUMBER(18,2),
	LINE_TOTAL NUMBER(18,2),
	ORDER_GRAND_TOTAL NUMBER(18,2),
	ORDER_DISCOUNT_TOTAL NUMBER(18,2),
	ORDER_TAX_TOTAL NUMBER(18,2),
	LINE_DISCOUNT_RATE FLOAT,
	ORDER_DISCOUNT_RATE FLOAT,
	DAYS_TO_FULFILL NUMBER(38,0),
	ORDERED_AT TIMESTAMP_NTZ(9),
	SHIPPED_AT TIMESTAMP_NTZ(9),
	DELIVERED_AT TIMESTAMP_NTZ(9),
	CANCELLED_AT TIMESTAMP_NTZ(9),
	ORDER_DATE DATE,
	ORDER_YEAR NUMBER(38,0),
	ORDER_MONTH NUMBER(38,0),
	ORDER_DAY NUMBER(38,0),
	ORDER_QUARTER NUMBER(38,0),
	IS_CANCELLED BOOLEAN,
	IS_DELIVERED BOOLEAN,
	IS_FULLY_SHIPPED BOOLEAN,
	DBT_UPDATED_AT TIMESTAMP_TZ(9)
);

CREATE TABLE IF NOT EXISTS L1_FX_SOURCE.ORDER_PAYMENTS (
	PAYMENT_ID VARCHAR(16777216),
	ORDER_ID VARCHAR(16777216),
	PAYMENT_METHOD_ID VARCHAR(16777216),
	PAYMENT_METHOD VARCHAR(16777216),
	AMOUNT NUMBER(18,4),
	CURRENCY_CODE VARCHAR(16777216),
	STATUS VARCHAR(16777216),
	TRANSACTION_ID VARCHAR(16777216),
	AUTHORIZATION_CODE VARCHAR(16777216),
	CARD_LAST_FOUR VARCHAR(16777216),
	CARD_TYPE VARCHAR(16777216),
	PROCESSED_AT TIMESTAMP_NTZ(9),
	CREATED_AT TIMESTAMP_NTZ(9),
	UPDATED_AT TIMESTAMP_NTZ(9)
);

CREATE TABLE IF NOT EXISTS L1_FX_SOURCE.DIM_EXCHANGE_RATES (
	EXCHANGE_RATE_ID VARCHAR(16777216),
	RATE_DATE DATE,
	FROM_CURRENCY VARCHAR(16777216),
	TO_CURRENCY VARCHAR(16777216),
	RATE FLOAT,
	DBT_UPDATED_AT TIMESTAMP_TZ(9)
);

-- Stage the loaders use.
CREATE STAGE IF NOT EXISTS L1_FX_SOURCE.FXSTAGE FILE_FORMAT = (TYPE = PARQUET);

-- ---------------------------------------------------------------------------
-- What you should see once data is loaded
--
--   FCT_SALES            9,456 rows   (989 with a non-null ORDER_DATE)
--   ORDER_PAYMENTS       1,973 rows   (one row per order)
--   DIM_EXCHANGE_RATES  13,242 rows   (6 currencies x 2,207 calendar days)
--
-- And these properties, which are what make the task discriminating:
--
--   977 sales rows settle on a date other than the order date
--   476 rows have a different rate on the settlement date than the order date
--   163 distinct output groups are affected by that difference
--    17 non-USD rows have no rate on the settlement date (MXN is absent entirely)
--    60 rows have no currency code recorded at all
--
-- The correct answer is 340 rows totalling 118,720.75 USD net. setup/verify_setup.sql
-- checks all of it.
-- ---------------------------------------------------------------------------

SHOW GRANTS TO ROLE DLAI_LAB_RL;
