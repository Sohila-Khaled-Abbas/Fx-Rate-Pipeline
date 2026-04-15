CREATE TABLE fx_rates (
    base_currency VARCHAR(3),
    target_currency VARCHAR(3),
    exchange_rate DECIMAL(10, 6),
    rate_date DATE,
    ingestion_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fx_rate PRIMARY KEY (base_currency, target_currency, rate_date)
);
