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
