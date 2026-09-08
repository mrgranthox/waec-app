-- 0004_grace_tokens.sql — 24h grace-period re-fetch pointers (plan §4.1,
-- §4.3): re-fetch without repurchase after mid-fetch disruption.

CREATE TABLE grace_tokens (
    token          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transaction_log(transaction_id),
    issued_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Hard invariant: expires at 24h (plan §6 global DoD).
    expires_at     TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
    consumed_at    TIMESTAMPTZ
);

CREATE INDEX idx_grace_expiry ON grace_tokens(expires_at);
