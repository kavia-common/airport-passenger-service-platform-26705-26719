-- Flyway migration V2: Seed data (facilities catalog + sample admin)
-- Note: Password hashes are placeholders; services should replace with a real bcrypt hash.
-- For local dev, this provides initial rows to verify end-to-end flows.

-- Seed permissions
INSERT INTO permissions (name, description)
VALUES
  ('ADMIN_READ', 'Read admin users and roles'),
  ('ADMIN_WRITE', 'Create/update admin users and roles'),
  ('FACILITY_READ', 'Read facilities catalog'),
  ('FACILITY_WRITE', 'Create/update facilities'),
  ('BOOKING_READ', 'Read bookings'),
  ('BOOKING_WRITE', 'Create/update bookings'),
  ('FEEDBACK_READ', 'Read feedback and grievances'),
  ('FEEDBACK_WRITE', 'Update feedback and grievances status')
ON CONFLICT (name) DO NOTHING;

-- Seed role
INSERT INTO roles (name, description)
VALUES ('SUPER_ADMIN', 'Full access administrator')
ON CONFLICT (name) DO NOTHING;

-- Assign all permissions to SUPER_ADMIN
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON true
WHERE r.name = 'SUPER_ADMIN'
ON CONFLICT DO NOTHING;

-- Seed sample admin
INSERT INTO admins (email, password_hash, full_name, is_active)
VALUES ('admin@airport.local', '{noop}change-me', 'Sample Super Admin', true)
ON CONFLICT (email) DO NOTHING;

-- Map admin to SUPER_ADMIN role
INSERT INTO admin_roles (admin_id, role_id)
SELECT a.id, r.id
FROM admins a
JOIN roles r ON r.name = 'SUPER_ADMIN'
WHERE a.email = 'admin@airport.local'
ON CONFLICT DO NOTHING;

-- Seed facilities catalog
INSERT INTO facilities (facility_type, code, name, description, location_text, is_active, price_base, currency_code, metadata)
VALUES
  ('PARKING', 'PARK_STD', 'Standard Parking', 'Hourly standard parking near terminal', 'T1 - Parking Zone A', true, 100.00, 'INR', '{"unit":"HOUR"}'::jsonb),
  ('PARKING', 'PARK_PREM', 'Premium Parking', 'Premium covered parking', 'T1 - Parking Zone P', true, 200.00, 'INR', '{"unit":"HOUR"}'::jsonb),
  ('LOUNGE', 'LONGE_DOM', 'Domestic Lounge', 'Comfortable seating, snacks and Wi-Fi', 'T1 - Level 2', true, 899.00, 'INR', '{"duration_minutes":180}'::jsonb),
  ('HOTEL', 'HOTEL_T1', 'Terminal Hotel', 'Short stay rooms within airport campus', 'Airport Campus', true, 2500.00, 'INR', '{"unit":"NIGHT"}'::jsonb),
  ('RESTAURANT', 'REST_FOOD', 'Food Court', 'Multi-cuisine food court', 'T1 - Concourse', true, NULL, 'INR', '{"tags":["veg","non_veg"]}'::jsonb),
  ('SERVICE', 'SERV_PORTER', 'Porter Service', 'Porter assistance for baggage', 'T1 - Arrivals', true, 300.00, 'INR', '{"unit":"TRIP"}'::jsonb)
ON CONFLICT (facility_type, code) DO NOTHING;
