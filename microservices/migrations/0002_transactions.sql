-- 0002_transactions.sql — encrypted transaction logs + idempotency ledger
-- (plan §2.7). Metadata only: NO raw grade values anywhere (hard rule 2).
-- Vendor PIN/serial are stored as AES-256-GCM ciphertext (vendor_blob).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Idempotency ledger: first outcome wins (plan §4.9).
CREATE TABLE payment_idempotency (
    idempotency_key UUID PRIMARY KEY,
    response_json   JSONB NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transaction_log (
    transaction_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID REFERENCES users(user_id),
    index_number    CHAR(10) NOT NULL,
    exam_type       TEXT NOT NULL
        CHECK (exam_type IN ('BECE', 'WASSCE_SC', 'WASSCE_PRIVATE')),
    exam_year       SMALLINT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN (
        'pending', 'paid', 'voucher_acquired', 'fetching',
        'success', 'failed', 'grace_refetch')),
    amount_pesewas  BIGINT NOT NULL CHECK (amount_pesewas >= 0),
    idempotency_key UUID NOT NULL UNIQUE
        REFERENCES payment_idempotency(idempotency_key),
    -- AES-256-GCM ciphertext of {pin, serial} — pgcrypto-adjacent storage,
    -- plaintext never touches disk (hard rule 1).
    vendor_blob     BYTEA,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_txn_index_number ON transaction_log(index_number, created_at DESC);
CREATE INDEX idx_txn_status ON transaction_log(status) WHERE status IN ('pending', 'paid', 'fetching');
