-- =============================================================================
-- asset_rental_sample_data.sql        Deliverable 6: sample data (100% fictional)
-- Run AFTER asset_rental_management.sql and asset_rental_views_procedures.sql.
-- Reference date used by the examples: 2026-10-15.
--   * Password hashes are dummy bcrypt-SHAPED strings. They match no password and cannot log in.
--   * Customer id_number values are obvious DEMO tokens, not real identification numbers.
--   * Emails use the reserved example.com / example.org / *.example domains; phones use fake numbers.
-- Inserts run through the real triggers, so the data itself proves the rules accept valid input.
-- =============================================================================
USE asset_rental;
SET NAMES utf8mb4;
START TRANSACTION;

-- ---- ROLES ------------------------------------------------------------------
INSERT INTO roles (role_id, role_name, permissions) VALUES
(1,'Administrator','{"users":["read","create","update","deactivate"],"roles":["read","update"],"assets":["read","create","update","retire"],"bookings":["read","create","approve","cancel"],"rentals":["read","create","update","cancel"],"payments":["read","create","refund"],"maintenance":["read","create","update"],"reports":["read"]}'),
(2,'Asset Manager','{"assets":["read","create","update","retire"],"bookings":["read","create","approve","cancel"],"rentals":["read"],"payments":["read"],"maintenance":["read","create","update"],"reports":["read"]}'),
(3,'Rental Clerk','{"assets":["read"],"bookings":["read"],"rentals":["read","create","update","cancel"],"payments":["read","create"],"customers":["read","create","update"],"reports":["read"]}'),
(4,'Technician','{"assets":["read"],"maintenance":["read","update"]}'),
(5,'Staff','{"assets":["read"],"bookings":["read","create","cancel"]}');

-- ---- USERS ------------------------------------------------------------------
INSERT INTO users (user_id, role_id, full_name, email, password_hash, department, status) VALUES
(1,1,'Amara Okafor','amara.okafor@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL01xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','IT','active'),
(2,2,'Liam Becker','liam.becker@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL02xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Operations','active'),
(3,3,'Priya Nair','priya.nair@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL03xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Rentals','active'),
(4,3,'Daniel Mwangi','daniel.mwangi@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL04xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Rentals','active'),
(5,4,'Sofia Alvarez','sofia.alvarez@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL05xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Maintenance','active'),
(6,4,'Tomasz Kowalski','tomasz.kowalski@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL06xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Maintenance','active'),
(7,5,'Hannah Fischer','hannah.fischer@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL07xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Marketing','active'),
(8,5,'Ethan Brooks','ethan.brooks@meridian-rentals.example','$2b$12$DUMMYHASHNOTREAL08xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx','Finance','inactive');

-- ---- ASSET_CATEGORIES -------------------------------------------------------
INSERT INTO asset_categories (category_id, category_name, rentable, mobile) VALUES
(1,'Power Tools',TRUE,TRUE),
(2,'Heavy Equipment',TRUE,TRUE),
(3,'Vehicles',TRUE,TRUE),
(4,'AV & Electronics',TRUE,TRUE),
(5,'Office Furniture',FALSE,FALSE),
(6,'Fixed Machinery',FALSE,FALSE);

-- ---- LOCATIONS (Company -> Branch -> Warehouse -> Storage room) --------------
INSERT INTO locations (location_id, parent_location_id, name, type) VALUES
(1,NULL,'Meridian Rentals Group','company'),
(2,1,'Johannesburg Branch','branch'),
(3,1,'Cape Town Branch','branch'),
(4,2,'JHB Main Warehouse','warehouse'),
(5,4,'Tool Cage A','storage_room'),
(6,4,'Electronics Room B','storage_room'),
(7,2,'JHB Equipment Yard','yard'),
(8,3,'CPT Warehouse','warehouse'),
(9,2,'JHB Head Office','office');

-- ---- ASSETS -----------------------------------------------------------------
INSERT INTO assets (asset_id, asset_tag, category_id, location_id, name, status, `condition`, purchase_date, daily_rate) VALUES
(1,'PT-0001',1,5,'Rotary Hammer Drill 800W','available','good','2024-03-15',35.00),
(2,'PT-0002',1,5,'Angle Grinder 230mm','available','good','2024-03-15',20.00),
(3,'PT-0003',1,7,'Concrete Mixer 140L','rented','fair','2023-06-20',45.00),
(4,'HE-0001',2,7,'Mini Excavator 1.8t','available','good','2022-11-01',650.00),
(5,'HE-0002',2,7,'Plate Compactor','maintenance','fair','2022-11-01',120.00),
(6,'VH-0001',3,7,'Flatbed Truck 3t','rented','good','2023-02-10',420.00),
(7,'VH-0002',3,8,'Panel Van','available','good','2024-08-05',280.00),
(8,'AV-0001',4,6,'Projector 5000 lumens','available','good','2025-01-12',90.00),
(9,'AV-0002',4,6,'PA Speaker System','available','good','2024-05-30',110.00),
(10,'AV-0003',4,6,'Wireless Microphone Set','retired','poor','2020-09-14',25.00),
(11,'OF-0001',5,9,'Boardroom Table','available','good','2021-04-01',0.00),
(12,'FM-0001',6,4,'Workshop Lathe','available','good','2019-08-19',0.00),
(13,'PT-0004',1,4,'Portable Generator 5kVA','available','good','2024-09-09',150.00);

-- ---- CUSTOMERS (phone/email deliberately not unique) -------------------------
INSERT INTO customers (customer_id, name, phone, email, id_number, is_active) VALUES
(1,'Lindiwe Dube','+27-555-0101','lindiwe.dube@example.com','DEMO-ID-000101',TRUE),
(2,'Brightpath Construction Ltd','+27-555-0102','accounts@brightpath.example.org',NULL,TRUE),
(3,'Marco Rossi','+27-555-0103',NULL,'DEMO-ID-000103',TRUE),
(4,'Evergreen Events','+27-555-0104','hire@evergreen-events.example.com',NULL,TRUE),
(5,'Sana Khalid','+27-555-0105','sana.khalid@example.com','DEMO-ID-000105',TRUE),
(6,'Oliver Grant','+27-555-0105','oliver.grant@example.com','DEMO-ID-000106',TRUE);   -- shares a phone with customer 5

-- ---- BOOKINGS ---------------------------------------------------------------
INSERT INTO bookings (booking_id, asset_id, requested_by, approved_by, start_time, end_time, purpose, status, created_at, decided_at) VALUES
(1,9,7,2,'2026-10-22 09:00:00','2026-10-23 17:00:00','Staff year-end function','approved','2026-10-08 09:30:00','2026-10-09 08:15:00'),
(2,9,8,NULL,'2026-10-22 12:00:00','2026-10-22 16:00:00','Training session (clashes with booking 1)','pending','2026-10-13 14:00:00',NULL),
(3,8,7,2,'2026-09-10 08:00:00','2026-09-10 18:00:00','Quarterly review presentation','fulfilled','2026-09-05 10:00:00','2026-09-06 09:00:00'),
(4,1,8,2,'2026-10-05 08:00:00','2026-10-06 17:00:00','Personal weekend project','rejected','2026-10-01 16:20:00','2026-10-02 09:10:00'),
(5,7,7,NULL,'2026-11-02 08:00:00','2026-11-03 18:00:00','Site visits','cancelled','2026-10-10 11:00:00',NULL),
(6,4,8,2,'2026-11-10 08:00:00','2026-11-12 17:00:00','Depot levelling','approved','2026-10-12 08:40:00','2026-10-13 10:00:00');

-- ---- RENTALS ----------------------------------------------------------------
INSERT INTO rentals (rental_id, asset_id, customer_id, handled_by, start_date, end_date, total_charge, deposit, contract_ref, status) VALUES
(1,13,1,3,'2026-08-24','2026-08-28',750.00,300.00,'RC-2026-0001','completed'),
(2,4,2,4,'2026-09-01','2026-09-07',4550.00,1000.00,'RC-2026-0002','completed'),
(3,3,3,4,'2026-09-28','2026-10-05',360.00,150.00,'RC-2026-0003','active'),     -- overdue as of 2026-10-15
(4,6,4,3,'2026-10-12','2026-10-18',2940.00,800.00,'RC-2026-0004','active'),
(5,7,5,3,'2026-10-25','2026-10-27',840.00,300.00,'RC-2026-0005','reserved'),
(6,8,1,3,'2026-09-14','2026-09-15',180.00,0.00,NULL,'completed'),
(7,2,6,4,'2026-10-20','2026-10-22',0.00,0.00,'RC-2026-0007','cancelled');       -- charge zeroed on cancellation

-- ---- CHECKOUT ---------------------------------------------------------------
INSERT INTO checkout (checkout_id, asset_id, booking_id, rental_id, out_time, in_time, condition_out, condition_in, released_by, received_by, notes) VALUES
(1,8,3,NULL,'2026-09-10 08:15:00','2026-09-10 17:40:00','good','good',3,3,NULL),
(2,13,NULL,1,'2026-08-24 09:00:00','2026-08-28 16:30:00','good','damaged',3,3,'Fuel pump leaking on return'),
(3,4,NULL,2,'2026-09-01 08:30:00','2026-09-07 15:45:00','good','good',4,4,NULL),
(4,8,NULL,6,'2026-09-14 10:00:00','2026-09-15 12:00:00','good','good',3,3,NULL),
(5,3,NULL,3,'2026-09-28 09:00:00',NULL,'fair',NULL,4,NULL,NULL),
(6,6,NULL,4,'2026-10-12 08:00:00',NULL,'good',NULL,3,NULL,NULL);

-- ---- MAINTENANCE ------------------------------------------------------------
INSERT INTO maintenance (maintenance_id, asset_id, performed_by, type, scheduled_date, completed_date, cost, status, completed_by, notes) VALUES
(1,5,6,'repair','2026-10-10',NULL,0.00,'in_progress',NULL,'Vibration plate bearing replacement'),
(2,4,5,'preventive','2026-08-20','2026-08-20',1200.00,'completed',5,'Hydraulic service and track tension'),
(3,6,6,'preventive','2026-07-15','2026-07-16',850.00,'completed',6,'Brakes and tyres'),
(4,3,5,'inspection','2026-11-05',NULL,0.00,'scheduled',NULL,NULL),
(5,13,5,'repair','2026-08-28','2026-09-02',340.50,'completed',5,'Fuel pump replaced'),
(6,1,6,'servicing','2026-09-20','2026-09-20',95.00,'completed',6,'Carbon brushes replaced'),
(7,8,5,'inspection','2026-10-01','2026-10-01',0.00,'completed',5,'Lamp hours checked'),
(8,7,6,'preventive','2026-11-15',NULL,0.00,'scheduled',NULL,NULL);

-- ---- PAYMENTS (ledger: amount > 0, txn_type gives the direction) --------------
INSERT INTO payments (payment_id, rental_id, amount, paid_on, method, txn_type, status, recorded_by, reference_no, related_payment_id) VALUES
(1,1,750.00,'2026-08-23','card','payment','completed',3,'POS-100231',NULL),
(2,1,300.00,'2026-08-23','card','deposit','completed',3,'POS-100232',NULL),
(3,1,100.00,'2026-08-29','card','deposit_refund','completed',3,'POS-100290',2),     -- 200.00 withheld towards the generator repair
(4,2,1500.00,'2026-08-30','bank_transfer','payment','completed',4,'EFT-55012',NULL),
(5,2,2000.00,'2026-09-01','bank_transfer','payment','completed',4,'EFT-55077',NULL),
(6,2,1050.00,'2026-09-08','bank_transfer','payment','completed',4,'EFT-55190',NULL),
(7,2,1000.00,'2026-08-30','bank_transfer','deposit','completed',4,'EFT-55013',NULL),
(8,2,1000.00,'2026-09-09','bank_transfer','deposit_refund','completed',4,'EFT-55201',7),
(9,3,150.00,'2026-09-28','cash','deposit','completed',4,'RCPT-3301',NULL),
(10,3,200.00,'2026-09-28','cash','payment','completed',4,'RCPT-3302',NULL),
(11,3,160.00,'2026-10-10','card','payment','failed',4,'POS-100877',NULL),            -- failed: ignored by balance
(12,4,800.00,'2026-10-12','card','deposit','completed',3,'POS-100901',NULL),
(13,4,1500.00,'2026-10-12','card','payment','completed',3,'POS-100902',NULL),
(14,4,500.00,'2026-10-14','bank_transfer','payment','pending',3,'EFT-55420',NULL),    -- pending: ignored by balance
(15,5,300.00,'2026-10-14','mobile_money','deposit','completed',3,'MM-77102',NULL),
(16,6,180.00,'2026-09-14','cash','payment','completed',3,'RCPT-3290',NULL),
(17,7,60.00,'2026-10-10','card','payment','completed',4,'POS-100870',NULL),
(18,7,60.00,'2026-10-12','card','refund','completed',4,'POS-100895',17);

-- ---- ASSET_HISTORY (append-only audit trail) -----------------------------------
INSERT INTO asset_history (asset_id, user_id, event_type, details, event_time, old_value, new_value) VALUES
(1,2,'registered','Asset registered','2024-03-15 10:00:00',NULL,'{"status":"available","condition":"new"}'),
(3,2,'registered','Asset registered','2023-06-20 09:30:00',NULL,'{"status":"available","condition":"good"}'),
(4,2,'registered','Asset registered','2022-11-01 11:00:00',NULL,'{"status":"available","condition":"new"}'),
(4,5,'maintenance_completed','Maintenance #2 completed, cost 1200.00','2026-08-20 15:00:00','{"status":"available"}','{"status":"available"}'),
(13,3,'checked_out','Checkout #2 condition good','2026-08-24 09:00:00','{"status":"available"}','{"status":"rented","checkout_id":2}'),
(13,3,'returned','Checkout #2 returned; condition damaged','2026-08-28 16:30:00','{"status":"rented","condition":"good"}','{"status":"maintenance","condition":"damaged"}'),
(13,5,'maintenance_completed','Maintenance #5 completed, cost 340.50','2026-09-02 14:00:00','{"status":"maintenance","condition":"damaged"}','{"status":"available","condition":"good"}'),
(4,4,'checked_out','Checkout #3 condition good','2026-09-01 08:30:00','{"status":"available"}','{"status":"rented","checkout_id":3}'),
(4,4,'returned','Checkout #3 returned; condition good','2026-09-07 15:45:00','{"status":"rented","condition":"good"}','{"status":"available","condition":"good"}'),
(8,2,'booking_approved','Booking #3 approved','2026-09-06 09:00:00',NULL,'{"booking_id":3,"status":"approved"}'),
(8,3,'checked_out','Checkout #1 condition good','2026-09-10 08:15:00','{"status":"available"}','{"status":"rented","checkout_id":1}'),
(8,3,'returned','Checkout #1 returned; condition good','2026-09-10 17:40:00','{"status":"rented","condition":"good"}','{"status":"available","condition":"good"}'),
(7,2,'location_changed','Van moved from JHB Equipment Yard to CPT Warehouse','2026-09-25 10:00:00','{"location_id":7}','{"location_id":8}'),
(3,4,'checked_out','Checkout #5 condition fair','2026-09-28 09:00:00','{"status":"available"}','{"status":"rented","checkout_id":5}'),
(6,3,'checked_out','Checkout #6 condition good','2026-10-12 08:00:00','{"status":"available"}','{"status":"rented","checkout_id":6}'),
(5,6,'maintenance_started','Maintenance #1 started','2026-10-10 08:30:00','{"status":"available"}','{"status":"maintenance"}'),
(9,2,'booking_approved','Booking #1 approved','2026-10-09 08:15:00',NULL,'{"booking_id":1,"status":"approved"}'),
(4,2,'booking_approved','Booking #6 approved','2026-10-13 10:00:00',NULL,'{"booking_id":6,"status":"approved"}'),
(10,2,'retired','Asset retired: end of life','2026-06-30 16:00:00','{"status":"available","condition":"poor"}','{"status":"retired","condition":"poor"}');

-- ---- LOCATION_LOG (mobile assets only; gps = device, manual = typed by a user) --
INSERT INTO location_log (asset_id, latitude, longitude, recorded_at, source, recorded_by) VALUES
(6,-26.204100,28.047300,'2026-10-12 08:05:00','gps',NULL),
(6,-26.107600,28.056700,'2026-10-12 11:30:00','gps',NULL),
(6,-26.087400,28.015200,'2026-10-13 09:00:00','gps',NULL),
(6,-26.087900,28.014800,'2026-10-14 09:00:00','gps',NULL),
(3,-26.195200,28.034100,'2026-09-28 09:30:00','gps',NULL),
(3,-26.011800,28.113900,'2026-09-29 07:45:00','gps',NULL),
(3,-26.011900,28.114000,'2026-10-14 07:45:00','gps',NULL),
(4,-26.204500,28.046900,'2026-09-01 08:40:00','gps',NULL),
(4,-26.250300,28.171200,'2026-09-03 07:50:00','gps',NULL),
(13,-26.178000,28.062500,'2026-08-24 09:20:00','manual',3),
(7,-33.924900,18.424100,'2026-09-25 11:00:00','manual',2);

COMMIT;
