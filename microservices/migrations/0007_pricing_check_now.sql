-- 0007_pricing_check_now.sql — two-part checker pricing (ADR-002).
--
-- A checker can be bought on its own (keep it for later, or share it) or bought
-- and spent in the same pass, which also pays for the retrieval. Those are two
-- different products and therefore two different amounts, both served from
-- config so a fee change never needs an app release (plan §2.2).
--
-- `amount_pesewas` (0003) keeps meaning "checker only".
-- `check_now_pesewas` is the new "checker + retrieve the result now" total.

ALTER TABLE pricing_config
    ADD COLUMN check_now_pesewas BIGINT NOT NULL DEFAULT 0
        CHECK (check_now_pesewas >= 0);

-- Backfill: an exam type that already had a price must not be left without a
-- combined price after this migration. The seed matches the launch promotion
-- (checker GHS 26.00 / checker + immediate retrieval GHS 36.00) and keeps the
-- relative margin on every other exam type.
UPDATE pricing_config
SET check_now_pesewas = CASE exam_type
    WHEN 'BECE'           THEN 2600
    WHEN 'WASSCE_SC'      THEN 3600
    WHEN 'WASSCE_PRIVATE' THEN 3600
    -- Any future exam type defaults to the combined launch fee rather than 0,
    -- which the CHECK above would otherwise allow and would mean "free result".
    ELSE 3600
END;

-- Launch pricing: a checker bought on its own is GHS 26.00; buying the checker
-- and retrieving the result in the same pass is GHS 36.00.
UPDATE pricing_config SET amount_pesewas = 2600 WHERE exam_type = 'BECE';
UPDATE pricing_config SET amount_pesewas = 2600 WHERE exam_type = 'WASSCE_SC';
UPDATE pricing_config SET amount_pesewas = 2600 WHERE exam_type = 'WASSCE_PRIVATE';