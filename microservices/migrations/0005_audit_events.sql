-- 0005_audit_events.sql — audit topic mirror (plan §2.7: "audit topics
-- mirrored to PostgreSQL by Admin"). Metadata only.

CREATE TABLE audit_events (
    id              BIGSERIAL PRIMARY KEY,
    transaction_id  UUID,
    index_number    CHAR(10),
    exam_type       TEXT,
    outcome         TEXT NOT NULL
        CHECK (outcome IN ('success', 'failed', 'grace_refetch')),
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_index_time ON audit_events(index_number, occurred_at DESC);
