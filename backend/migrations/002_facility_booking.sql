ALTER TABLE resources ADD COLUMN preferred_unit text;
UPDATE resources SET preferred_unit = CASE WHEN 'hourly' = ANY(allowed_units) THEN 'hourly' ELSE 'daily' END;
ALTER TABLE resources ALTER COLUMN preferred_unit SET NOT NULL;
ALTER TABLE resources ADD CONSTRAINT preferred_unit_allowed CHECK (preferred_unit = ANY(allowed_units));
ALTER TABLE bookings DROP CONSTRAINT bookings_check;
ALTER TABLE bookings ALTER COLUMN duration TYPE numeric(4,1);
ALTER TABLE bookings ADD CONSTRAINT bookings_duration_check CHECK (
    (duration_unit = 'hourly' AND duration BETWEEN 0.5 AND 24 AND mod(duration,0.5)=0)
    OR (duration_unit = 'daily' AND duration BETWEEN 1 AND 30 AND duration=trunc(duration))
);
-- Each entry represents one independently reservable physical facility.
-- Preserve local names, policies and active flags on repeat runs.
INSERT INTO resources (id, name, allowed_units, preferred_unit) VALUES
('outdoor-court', 'Multi Game Outdoor Court', ARRAY['hourly','daily'], 'hourly'),
('swimming-pool', 'Swimming Pool', ARRAY['hourly'], 'hourly'),
('sauna', 'Sauna', ARRAY['hourly'], 'hourly'),
('steam-bath', 'Steam Bath', ARRAY['hourly'], 'hourly'),
('suite-1', 'Suite 1', ARRAY['daily'], 'daily'),
('suite-2', 'Suite 2', ARRAY['daily'], 'daily'),
('suite-3', 'Suite 3', ARRAY['daily'], 'daily'),
('basketball', 'Basketball', ARRAY['hourly'], 'hourly'),
('badminton', 'Badminton', ARRAY['hourly'], 'hourly'),
('tennis', 'Tennis', ARRAY['hourly'], 'hourly'),
('conference-hall', 'Conference Hall', ARRAY['daily'], 'daily'),
('meeting-room', 'Meeting Room', ARRAY['daily'], 'daily'),
('workspaces', 'Workspaces', ARRAY['daily'], 'daily')
ON CONFLICT (id) DO NOTHING;
