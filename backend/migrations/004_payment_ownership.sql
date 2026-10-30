ALTER TABLE payments ADD COLUMN IF NOT EXISTS ownership_conflict boolean NOT NULL DEFAULT false;
