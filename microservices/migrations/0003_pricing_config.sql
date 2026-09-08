-- 0003_pricing_config.sql — dynamic GHS rates served by the config
-- endpoint (plan §2.2: fee changes without app releases).

CREATE TABLE pricing_config (
    exam_type      TEXT PRIMARY KEY
        CHECK (exam_type IN ('BECE', 'WASSCE_SC', 'WASSCE_PRIVATE')),
    amount_pesewas BIGINT NOT NULL CHECK (amount_pesewas >= 0),
    currency       TEXT NOT NULL DEFAULT 'GHS',
    effective_from TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO pricing_config (exam_type, amount_pesewas) VALUES
    ('BECE', 1500),          -- GHS 15.00
    ('WASSCE_SC', 2000),     -- GHS 20.00
    ('WASSCE_PRIVATE', 2000) -- GHS 20.00
ON CONFLICT (exam_type) DO NOTHING;
