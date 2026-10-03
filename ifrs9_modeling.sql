DROP TABLE IF EXISTS staging_credit_card;

CREATE TABLE staging_credit_card (
    id INT PRIMARY KEY,
    limit_bal NUMERIC(12, 2),
    sex INT,
    education INT,
    marriage INT,
    age INT,
    pay_0 INT,
    pay_2 INT,
    pay_3 INT,
    pay_4 INT,
    pay_5 INT,
    pay_6 INT,
    bill_amt1 NUMERIC(12, 2),
    bill_amt2 NUMERIC(12, 2),
    bill_amt3 NUMERIC(12, 2),
    bill_amt4 NUMERIC(12, 2),
    bill_amt5 NUMERIC(12, 2),
    bill_amt6 NUMERIC(12, 2),
    pay_amt1 NUMERIC(12, 2),
    pay_amt2 NUMERIC(12, 2),
    pay_amt3 NUMERIC(12, 2),
    pay_amt4 NUMERIC(12, 2),
    pay_amt5 NUMERIC(12, 2),
    pay_amt6 NUMERIC(12, 2),
    default_payment_next_month INT
);

COPY staging_credit_card 
FROM 'C:/tmp/UCI_Credit_Card.csv' 
WITH (FORMAT csv, HEADER true, DELIMITER ',');

DROP TABLE IF EXISTS fact_statements;

CREATE TABLE fact_statements AS
SELECT
	s.id AS customer_id,
	u.month_index,
	u.statement_month,
	u.bill_amount,
	u.paid_amount,
	u.delay_status
FROM staging_credit_card s
CROSS JOIN LATERAL (
	VALUES
		(1, '2005-09', s.bill_amt1, s.pay_amt1, s.pay_0),
		(2, '2005-08', s.bill_amt2, s.pay_amt2, s.pay_2),
		(3, '2005-07', s.bill_amt3, s.pay_amt3, s.pay_3),
		(4, '2005-06', s.bill_amt4, s.pay_amt4, s.pay_4),
		(5, '2005-05', s.bill_amt5, s.pay_amt5, s.pay_5),
		(6, '2005-04', s.bill_amt6, s.pay_amt6, s.pay_6)
) AS u(month_index, statement_month, bill_amount, paid_amount, delay_status);

SELECT
	f.customer_id,
	f.statement_month,
	s.limit_bal,
	f.bill_amount,
	f.paid_amount,
	f.delay_status,
	ROUND(100.0 * f.bill_amount / NULLIF(s.limit_bal, 0), 2) AS utilization_rate,
	ROUND(100.0 * f.paid_amount / NULLIF(f.bill_amount, 0), 2) AS payment_ratio
FROM fact_statements AS f 
JOIN staging_credit_card AS s
ON f.customer_id = s.id
WHERE f.customer_id IN (1, 2, 3)
ORDER BY f.customer_id, f.month_index;

WITH customer_buckets AS (
	SELECT
		customer_id,
		statement_month,
		delay_status,
		CASE
			WHEN delay_status <= 0 THEN 'Current'
			WHEN delay_status = 1 THEN '1-30 DPD'
			WHEN delay_status = 2 THEN '31-60 DPD'
			WHEN delay_status >= 3 THEN '60+ DPD'
			ELSE 'Unknown'
		END AS dpd_bucket
	FROM fact_statements 
	WHERE month_index = 1
)
SELECT
	dpd_bucket,
	COUNT(*) AS customer_count,
	ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS portfolio_percentage
FROM customer_buckets
GROUP BY dpd_bucket
ORDER BY customer_count DESC;

WITH lagged_statements AS (
	SELECT
		customer_id,
		statement_month,
		delay_status,
		LAG(delay_status, 1) OVER (PARTITION BY customer_id ORDER BY statement_month) AS prev_delay_status
	FROM fact_statements
),

bucketed_transitions AS (
	SELECT
		customer_id,
		statement_month,
		delay_status,
		prev_delay_status,
		CASE
			WHEN delay_status <= 0 THEN 'Current'
			WHEN delay_status = 1 THEN '1-30 DPD'
			WHEN delay_status = 2 THEN '31-60 DPD'
			WHEN delay_status >= 3 THEN '60+ DPD'
			ELSE 'Unknown'
		END AS current_bucket,
		CASE
			WHEN prev_delay_status <= 0 THEN 'Current'
			WHEN prev_delay_status = 1 THEN '1-30 DPD'
			WHEN prev_delay_status = 2 THEN '31-60 DPD'
			WHEN prev_delay_status >= 3 THEN '60+ DPD'
			ELSE NULL
		END AS prev_bucket
	FROM lagged_statements
),

matrix_counts AS (
	SELECT 
		prev_bucket,
		COUNT(CASE WHEN current_bucket = 'Current' THEN 1 END) AS to_current,
		COUNT(CASE WHEN current_bucket = '1-30 DPD' THEN 1 END) AS to_dpd_1_30,
		COUNT(CASE WHEN current_bucket = '31-60 DPD' THEN 1 END) AS to_dpd_31_60,
		COUNT(CASE WHEN current_bucket = '60+ DPD' THEN 1 END) AS to_dpd_60_plus,
		COUNT(*) AS total_starting_accounts
	FROM bucketed_transitions
	WHERE prev_bucket IS NOT NULL
	GROUP BY prev_bucket
)
SELECT 
	prev_bucket,
	ROUND(100.0 * to_current / total_starting_accounts, 2) AS pct_to_current,
	ROUND(100.0 * to_dpd_1_30 / total_starting_accounts, 2) AS pct_to_1_30,
	ROUND(100.0 * to_dpd_31_60 / total_starting_accounts, 2) AS pct_to_31_60,
	ROUND(100.0 * to_dpd_60_plus / total_starting_accounts, 2) AS pct_to_60_plus,
	CASE
		WHEN prev_bucket = 'Current' THEN NULL
		ELSE ROUND(100.0 * to_current / total_starting_accounts, 2)
	END AS cure_rate,
	CASE 
    	WHEN prev_bucket = '60+ DPD' THEN NULL
    	ELSE ROUND(100.0 * to_dpd_60_plus / total_starting_accounts, 2)
	END AS roll_to_worst
FROM matrix_counts
ORDER BY
	CASE
		WHEN prev_bucket = 'Current' THEN 1
		WHEN prev_bucket = '1-30 DPD' THEN 2
		WHEN prev_bucket = '31-60 DPD' THEN 3
		WHEN prev_bucket = '60+ DPD' THEN 4
	END;

WITH lagged_statements AS (
	SELECT
		customer_id,
		statement_month,
		delay_status,
		LAG(delay_status, 1) OVER (PARTITION BY customer_id ORDER BY statement_month) AS prev_delay_status,
		LAG(bill_amount, 1) OVER (PARTITION BY customer_id ORDER BY statement_month) AS prev_bill_amount
	FROM fact_statements			
),

bucketed_transitions AS (
	SELECT
		CASE
		    WHEN prev_delay_status <= 0 THEN 'Current'
		    WHEN prev_delay_status = 1 THEN '1-30 DPD'
		    WHEN prev_delay_status = 2 THEN '31-60 DPD'
		    WHEN prev_delay_status >= 3 THEN '60+ DPD'
		    ELSE 'Unknown'
		END AS prev_bucket,
		CASE
		    WHEN delay_status <= 0 THEN 'Current'
		    WHEN delay_status = 1 THEN '1-30 DPD'
		    WHEN delay_status = 2 THEN '31-60 DPD'
		    WHEN delay_status >= 3 THEN '60+ DPD'
		    ELSE 'Unknown'
		END AS current_bucket,
		prev_bill_amount
	FROM lagged_statements
	WHERE prev_delay_status IS NOT NULL
 	AND prev_bill_amount > 0
),

matrix_balances AS (
	SELECT 
		prev_bucket,
		SUM(CASE WHEN current_bucket = 'Current' THEN prev_bill_amount ELSE 0 END) AS to_current_balance,
		SUM(CASE WHEN current_bucket = '1-30 DPD' THEN prev_bill_amount ELSE 0 END) AS to_1_30_balance,		
		SUM(CASE WHEN current_bucket = '31-60 DPD' THEN prev_bill_amount ELSE 0 END) AS to_31_60_balance,
		SUM(CASE WHEN current_bucket = '60+ DPD' THEN prev_bill_amount ELSE 0 END) AS to_60_plus_balance,
		SUM(prev_bill_amount) AS total_start_balance
	FROM bucketed_transitions
	GROUP BY prev_bucket
)
SELECT
	prev_bucket,
	total_start_balance,
	ROUND(100.0 * to_current_balance / NULLIF(total_start_balance, 0), 2) AS to_current_rate,
	ROUND(100.0 * to_1_30_balance / NULLIF(total_start_balance, 0), 2) AS to_1_30_dpd_rate,
	ROUND(100.0 * to_31_60_balance / NULLIF(total_start_balance, 0), 2) AS to_31_60_dpd_rate,
	ROUND(100.0 * to_60_plus_balance / NULLIF(total_start_balance, 0), 2) AS to_60_plus_dpd_rate
FROM matrix_balances
ORDER BY
	CASE
		WHEN prev_bucket = 'Current' THEN 1
		WHEN prev_bucket = '1-30 DPD' THEN 2
		WHEN prev_bucket = '31-60 DPD' THEN 3
		WHEN prev_bucket = '60+ DPD' THEN 4
	END;

WITH latest_portfolio AS (
	SELECT
		CASE
			WHEN delay_status <= 0 THEN 'Current'
			WHEN delay_status = 1 THEN '1-30 DPD'
			WHEN delay_status = 2 THEN '31-60 DPD'
			WHEN delay_status >= 3 THEN '60+ DPD'
		END AS risk_bucket,
		SUM(bill_amount) AS ead,
		CASE
			WHEN delay_status <= 0 THEN 0.0000
			WHEN delay_status = 1 THEN 0.0000
			WHEN delay_status = 2 THEN 0.0505
			WHEN delay_status >= 3 THEN 0.6434
		END AS pd,
		0.70 AS lgd
	FROM fact_statements
	WHERE statement_month = '2005-09'
	  AND bill_amount > 0
	GROUP BY 
		CASE
			WHEN delay_status <= 0 THEN 'Current'
			WHEN delay_status = 1 THEN '1-30 DPD'
			WHEN delay_status = 2 THEN '31-60 DPD'
			WHEN delay_status >= 3 THEN '60+ DPD'
		END,
		CASE
			WHEN delay_status <= 0 THEN 0.0000
			WHEN delay_status = 1 THEN 0.0000
			WHEN delay_status = 2 THEN 0.0505
			WHEN delay_status >= 3 THEN 0.6434
		END
)
SELECT
	risk_bucket,
	ead,
	pd,
	lgd,
	ROUND(ead * pd * lgd, 2) AS ecl
FROM latest_portfolio
ORDER BY
	CASE
		WHEN risk_bucket = 'Current' THEN 1
		WHEN risk_bucket = '1-30 DPD' THEN 2
		WHEN risk_bucket = '31-60 DPD' THEN 3
		WHEN risk_bucket = '60+ DPD' THEN 4
	END;
