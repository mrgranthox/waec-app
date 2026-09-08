-- 0001_users.sql — Auth user accounts (plan §2.7 schema).
-- Stores ONLY Argon2id hashes + lockout state; zero grades, zero PINs.

CREATE TABLE users (
    user_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    index_number         CHAR(10) NOT NULL UNIQUE,
    password_hash        TEXT NOT NULL,                -- Argon2id PHC string
    biometric_public_key TEXT,
    failed_attempts      INT NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
