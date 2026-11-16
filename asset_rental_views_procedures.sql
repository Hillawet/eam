-- =============================================================================
-- asset_rental_views_procedures.sql      Deliverable 8: views, procedures, triggers
-- Run AFTER asset_rental_management.sql.
-- =============================================================================
-- DESIGN RULE: declarative constraints first (CHECK / UNIQUE / FK). A trigger or
-- procedure exists below only where MySQL cannot express the rule declaratively:
--   * cycles in the location tree                    -> trg_locations_*
--   * overlapping bookings / rentals for one asset   -> sp_assert_slot_free + triggers
--   * rental eligibility (status, category.rentable) -> sp_assert_asset_rentable + triggers
--   * append-only audit table                        -> trg_asset_history_*
--   * multi-table workflows that must be atomic      -> sp_decide_booking, sp_checkout_asset,
--                                                       sp_return_asset, sp_start/complete_maintenance
-- =============================================================================
USE asset_rental;
SET NAMES utf8mb4;

-- =============================================================================
-- PART A - VIEWS
-- =============================================================================

-- A1. Assets that can be handed out right now.
CREATE OR REPLACE VIEW v_available_assets AS
SELECT a.asset_id, a.asset_tag, a.name AS asset_name, c.category_name,
       l.name AS location_name, a.`condition`, a.daily_rate
FROM assets a
JOIN asset_categories c ON c.category_id = a.category_id
JOIN locations l        ON l.location_id = a.location_id
WHERE a.status = 'available'
  AND c.rentable = TRUE
  AND NOT EXISTS (SELECT 1 FROM checkout k WHERE k.asset_id = a.asset_id AND k.in_time IS NULL);

-- A2. Rentals currently running (asset physically out or contract in force).
CREATE OR REPLACE VIEW v_active_rentals AS
SELECT r.rental_id, r.contract_ref, a.asset_tag, a.name AS asset_name,
       cu.customer_id, cu.name AS customer_name, u.full_name AS handled_by,
       r.start_date, r.end_date,
       DATEDIFF(r.end_date, CURDATE()) AS days_remaining,   -- negative = overdue
       r.total_charge, r.deposit
FROM rentals r
JOIN assets a     ON a.asset_id = r.asset_id
JOIN customers cu ON cu.customer_id = r.customer_id
JOIN users u      ON u.user_id = r.handled_by
WHERE r.status = 'active';

-- A3. Balance per rental, computed from the payment ledger (never stored).
--     outstanding = total_charge - (completed payments - completed refunds)
--     Deposits are tracked separately (deposit_held) and are NOT part of the balance.
CREATE OR REPLACE VIEW v_rental_balance AS
SELECT r.rental_id, r.contract_ref, r.customer_id, r.asset_id, r.status AS rental_status,
       r.total_charge,
       COALESCE(p.paid, 0)       AS amount_paid,
       COALESCE(p.refunded, 0)   AS amount_refunded,
       r.total_charge - (COALESCE(p.paid, 0) - COALESCE(p.refunded, 0)) AS outstanding_balance,
       CASE
         WHEN r.total_charge - (COALESCE(p.paid, 0) - COALESCE(p.refunded, 0)) < 0 THEN 'overpaid'
         WHEN r.total_charge - (COALESCE(p.paid, 0) - COALESCE(p.refunded, 0)) = 0 THEN 'settled'
         WHEN COALESCE(p.paid, 0) - COALESCE(p.refunded, 0) > 0                    THEN 'partially_paid'
         ELSE 'unpaid'
       END AS payment_status,
       r.deposit               AS deposit_required,
       COALESCE(p.deposit_held, 0) AS deposit_held
FROM rentals r
LEFT JOIN (
  SELECT rental_id,
         SUM(CASE WHEN txn_type = 'payment'        AND status = 'completed' THEN amount END) AS paid,
         SUM(CASE WHEN txn_type = 'refund'         AND status = 'completed' THEN amount END) AS refunded,
         SUM(CASE WHEN txn_type = 'deposit'        AND status = 'completed' THEN  amount
                  WHEN txn_type = 'deposit_refund' AND status = 'completed' THEN -amount END) AS deposit_held
  FROM payments
  GROUP BY rental_id
) p ON p.rental_id = r.rental_id;

-- A4. Overdue rentals: still active after the inclusive end_date.
--     estimated_late_fee is informational (days overdue x daily rate); the real fee is
--     whatever the clerk records as an adjustment / increased total_charge.
CREATE OR REPLACE VIEW v_overdue_rentals AS
SELECT r.rental_id, r.contract_ref, cu.name AS customer_name, cu.phone, cu.email,
       a.asset_tag, a.name AS asset_name, r.end_date,
       DATEDIFF(CURDATE(), r.end_date)                  AS days_overdue,
       DATEDIFF(CURDATE(), r.end_date) * a.daily_rate   AS estimated_late_fee,
       b.outstanding_balance
FROM rentals r
JOIN customers cu     ON cu.customer_id = r.customer_id
JOIN assets a         ON a.asset_id = r.asset_id
JOIN v_rental_balance b ON b.rental_id = r.rental_id
WHERE r.status = 'active' AND r.end_date < CURDATE();

-- A5. Maintenance history rolled up per asset.
CREATE OR REPLACE VIEW v_asset_maintenance_summary AS
SELECT a.asset_id, a.asset_tag, a.name AS asset_name, a.status AS asset_status,
       COUNT(m.maintenance_id)                                          AS jobs_total,
       SUM(m.status IN ('scheduled','in_progress'))                     AS jobs_open,
       SUM(m.status = 'completed')                                      AS jobs_completed,
       COALESCE(SUM(CASE WHEN m.status = 'completed' THEN m.cost END), 0) AS total_cost,
       MAX(CASE WHEN m.status = 'completed' THEN m.completed_date END)  AS last_completed,
       MIN(CASE WHEN m.status IN ('scheduled','in_progress') THEN m.scheduled_date END) AS next_scheduled
FROM assets a
LEFT JOIN maintenance m ON m.asset_id = a.asset_id
GROUP BY a.asset_id, a.asset_tag, a.name, a.status;

-- =============================================================================
-- PART B - HELPER PROCEDURES (called by triggers and by workflow procedures)
-- =============================================================================
DELIMITER $$

-- B1. Raise an error unless the asset may enter a new customer rental.
CREATE PROCEDURE sp_assert_asset_rentable (IN p_asset_id INT)
BEGIN
  DECLARE v_status   VARCHAR(20) DEFAULT NULL;
  DECLARE v_rentable TINYINT(1)  DEFAULT NULL;

  SELECT a.status, c.rentable INTO v_status, v_rentable
  FROM assets a JOIN asset_categories c ON c.category_id = a.category_id
  WHERE a.asset_id = p_asset_id;

  IF v_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset does not exist';
  ELSEIF v_rentable = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset category is not rentable';
  ELSEIF v_status NOT IN ('available','rented') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Asset is not eligible for rental (maintenance, retired or lost)';
  END IF;
END$$

-- B2. Raise an error if [p_start, p_end) collides with an approved/fulfilled booking
--     or a reserved/active rental of the same asset. The asset row is locked first so
--     that two concurrent sessions are serialised and cannot both pass the check.
CREATE PROCEDURE sp_assert_slot_free (
  IN p_asset_id INT, IN p_start DATETIME, IN p_end DATETIME,
  IN p_exclude_booking INT, IN p_exclude_rental INT)
BEGIN
  DECLARE v_lock INT;
  DECLARE v_hits INT DEFAULT 0;

  SELECT asset_id INTO v_lock FROM assets WHERE asset_id = p_asset_id FOR UPDATE;

  SELECT COUNT(*) INTO v_hits FROM bookings
  WHERE asset_id = p_asset_id
    AND status IN ('approved','fulfilled')
    AND booking_id <> IFNULL(p_exclude_booking, 0)
    AND start_time < p_end AND end_time > p_start;
  IF v_hits > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset already booked for an overlapping period';
  END IF;

  SELECT COUNT(*) INTO v_hits FROM rentals
  WHERE asset_id = p_asset_id
    AND status IN ('reserved','active')
    AND rental_id <> IFNULL(p_exclude_rental, 0)
    AND TIMESTAMP(start_date) < p_end
    AND TIMESTAMP(DATE_ADD(end_date, INTERVAL 1 DAY)) > p_start;
  IF v_hits > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset already rented for an overlapping period';
  END IF;
END$$

-- B3. Append one row to the audit trail.
CREATE PROCEDURE sp_log_asset_event (
  IN p_asset_id INT, IN p_user_id INT, IN p_event_type VARCHAR(50),
  IN p_details TEXT, IN p_old JSON, IN p_new JSON)
BEGIN
  INSERT INTO asset_history (asset_id, user_id, event_type, details, event_time, old_value, new_value)
  VALUES (p_asset_id, p_user_id, p_event_type, p_details, NOW(), p_old, p_new);
END$$

-- =============================================================================
-- PART C - TRIGGERS
-- =============================================================================

-- C1. Location hierarchy: no self-parent, no cycles.
CREATE TRIGGER trg_locations_bi BEFORE INSERT ON locations FOR EACH ROW
BEGIN
  IF NEW.parent_location_id IS NOT NULL AND NEW.parent_location_id = NEW.location_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A location cannot be its own parent';
  END IF;
END$$

CREATE TRIGGER trg_locations_bu BEFORE UPDATE ON locations FOR EACH ROW
BEGIN
  DECLARE v_loop INT DEFAULT 0;
  IF NEW.parent_location_id IS NOT NULL
     AND NOT (NEW.parent_location_id <=> OLD.parent_location_id) THEN
    -- Walk up from the proposed parent; meeting NEW.location_id means a cycle.
    WITH RECURSIVE ancestors (location_id, parent_location_id) AS (
      SELECT location_id, parent_location_id FROM locations WHERE location_id = NEW.parent_location_id
      UNION ALL
      SELECT l.location_id, l.parent_location_id
      FROM locations l JOIN ancestors s ON l.location_id = s.parent_location_id
    )
    SELECT COUNT(*) INTO v_loop FROM ancestors WHERE location_id = NEW.location_id;
    IF v_loop > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid location hierarchy: circular reference';
    END IF;
  END IF;
END$$

-- C2. Bookings: an approved/fulfilled booking may not overlap another allocation.
CREATE TRIGGER trg_bookings_bi BEFORE INSERT ON bookings FOR EACH ROW
BEGIN
  DECLARE v_status VARCHAR(20);
  IF NEW.status IN ('approved','fulfilled') THEN
    SELECT status INTO v_status FROM assets WHERE asset_id = NEW.asset_id;
    IF v_status IN ('retired','lost') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Retired or lost assets cannot be booked';
    END IF;
    CALL sp_assert_slot_free(NEW.asset_id, NEW.start_time, NEW.end_time, NULL, NULL);
  END IF;
END$$

CREATE TRIGGER trg_bookings_bu BEFORE UPDATE ON bookings FOR EACH ROW
BEGIN
  DECLARE v_status VARCHAR(20);
  IF NEW.status IN ('approved','fulfilled')
     AND (OLD.status NOT IN ('approved','fulfilled')
          OR NEW.asset_id <> OLD.asset_id
          OR NEW.start_time <> OLD.start_time
          OR NEW.end_time <> OLD.end_time) THEN
    SELECT status INTO v_status FROM assets WHERE asset_id = NEW.asset_id;
    IF v_status IN ('retired','lost') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Retired or lost assets cannot be booked';
    END IF;
    CALL sp_assert_slot_free(NEW.asset_id, NEW.start_time, NEW.end_time, NEW.booking_id, NULL);
  END IF;
END$$

-- C3. Rentals: eligibility (status / rentable category) and no double allocation.
CREATE TRIGGER trg_rentals_bi BEFORE INSERT ON rentals FOR EACH ROW
BEGIN
  IF NEW.status IN ('pending','reserved','active') THEN
    CALL sp_assert_asset_rentable(NEW.asset_id);
  END IF;
  IF NEW.status IN ('reserved','active') THEN
    CALL sp_assert_slot_free(NEW.asset_id, TIMESTAMP(NEW.start_date),
                             TIMESTAMP(DATE_ADD(NEW.end_date, INTERVAL 1 DAY)), NULL, NULL);
  END IF;
END$$

CREATE TRIGGER trg_rentals_bu BEFORE UPDATE ON rentals FOR EACH ROW
BEGIN
  -- eligibility only when the rental ENTERS an open state or changes asset;
  -- an already-active rental must stay editable (extension, fees) even if the asset
  -- has since been flagged for maintenance.
  IF NEW.status IN ('pending','reserved','active')
     AND (NEW.status <> OLD.status OR NEW.asset_id <> OLD.asset_id) THEN
    CALL sp_assert_asset_rentable(NEW.asset_id);
  END IF;
  IF NEW.status IN ('reserved','active')
     AND (OLD.status NOT IN ('reserved','active')
          OR NEW.asset_id <> OLD.asset_id
          OR NEW.start_date <> OLD.start_date
          OR NEW.end_date <> OLD.end_date) THEN
    CALL sp_assert_slot_free(NEW.asset_id, TIMESTAMP(NEW.start_date),
                             TIMESTAMP(DATE_ADD(NEW.end_date, INTERVAL 1 DAY)), NULL, NEW.rental_id);
  END IF;
END$$

-- C4. Checkout: a NEW open checkout needs an asset that is not in maintenance / retired / lost.
--     (One-open-checkout-per-asset is a UNIQUE index, not a trigger.)
CREATE TRIGGER trg_checkout_bi BEFORE INSERT ON checkout FOR EACH ROW
BEGIN
  DECLARE v_status VARCHAR(20);
  IF NEW.in_time IS NULL THEN
    SELECT status INTO v_status FROM assets WHERE asset_id = NEW.asset_id;
    IF v_status IN ('maintenance','retired','lost') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset cannot be checked out (maintenance, retired or lost)';
    END IF;
  END IF;
END$$

-- C5. LOCATION_LOG only makes sense for mobile categories.
CREATE TRIGGER trg_location_log_bi BEFORE INSERT ON location_log FOR EACH ROW
BEGIN
  DECLARE v_mobile TINYINT(1);
  SELECT c.mobile INTO v_mobile
  FROM assets a JOIN asset_categories c ON c.category_id = a.category_id
  WHERE a.asset_id = NEW.asset_id;
  IF v_mobile = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Coordinates may only be logged for mobile asset categories';
  END IF;
END$$

-- C6. Audit trail is append-only. (TRUNCATE bypasses triggers - withhold the DROP/ALTER
--     privilege from application accounts; see the security section.)
CREATE TRIGGER trg_asset_history_bu BEFORE UPDATE ON asset_history FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'asset_history is append-only: updates are not allowed';
END$$

CREATE TRIGGER trg_asset_history_bd BEFORE DELETE ON asset_history FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'asset_history is append-only: deletes are not allowed';
END$$

-- =============================================================================
-- PART D - WORKFLOW PROCEDURES (each one is a single atomic transaction)
-- =============================================================================

-- D1. Approve or reject a pending booking. The caller must hold bookings:approve.
CREATE PROCEDURE sp_decide_booking (
  IN p_booking_id INT, IN p_approver_id INT, IN p_decision VARCHAR(10))  -- 'approved' | 'rejected'
BEGIN
  DECLARE v_asset  INT;
  DECLARE v_status VARCHAR(20);
  DECLARE v_can    INT DEFAULT 0;
  DECLARE v_lock   INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_decision NOT IN ('approved','rejected') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Decision must be approved or rejected';
  END IF;

  START TRANSACTION;
  SELECT asset_id, status INTO v_asset, v_status FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
  IF v_asset IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
  END IF;
  IF v_status <> 'pending' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only pending bookings can be decided';
  END IF;

  SELECT COUNT(*) INTO v_can
  FROM users u JOIN roles r ON r.role_id = u.role_id
  WHERE u.user_id = p_approver_id AND u.status = 'active'
    AND JSON_CONTAINS(r.permissions, '"approve"', '$.bookings');
  IF v_can = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User may not approve bookings';
  END IF;

  SELECT asset_id INTO v_lock FROM assets WHERE asset_id = v_asset FOR UPDATE;   -- serialise per asset

  -- trg_bookings_bu performs the overlap test when status becomes 'approved'
  UPDATE bookings
     SET status = p_decision, approved_by = p_approver_id, decided_at = NOW()
   WHERE booking_id = p_booking_id;

  CALL sp_log_asset_event(v_asset, p_approver_id,
        IF(p_decision = 'approved', 'booking_approved', 'booking_rejected'),
        CONCAT('Booking #', p_booking_id, ' ', p_decision), NULL,
        JSON_OBJECT('booking_id', p_booking_id, 'status', p_decision));
  COMMIT;
END$$

-- D2. Hand an asset over. Exactly one of p_booking_id / p_rental_id is normally supplied.
CREATE PROCEDURE sp_checkout_asset (
  IN p_asset_id INT, IN p_booking_id INT, IN p_rental_id INT,
  IN p_user_id INT, IN p_condition_out VARCHAR(10), IN p_out_time DATETIME)
BEGIN
  DECLARE v_status  VARCHAR(20);
  DECLARE v_state   VARCHAR(20);
  DECLARE v_cond    VARCHAR(10);
  DECLARE v_new_id  INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_booking_id IS NULL AND p_rental_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A checkout needs a booking or a rental';
  END IF;

  START TRANSACTION;
  SELECT status, `condition` INTO v_status, v_cond FROM assets WHERE asset_id = p_asset_id FOR UPDATE;
  IF v_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset does not exist';
  END IF;
  IF v_status <> 'available' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset is not available for checkout';
  END IF;

  IF p_booking_id IS NOT NULL THEN
    SELECT status INTO v_state FROM bookings WHERE booking_id = p_booking_id AND asset_id = p_asset_id FOR UPDATE;
    IF v_state IS NULL OR v_state <> 'approved' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking must exist for this asset and be approved';
    END IF;
  END IF;
  IF p_rental_id IS NOT NULL THEN
    SET v_state = NULL;
    SELECT status INTO v_state FROM rentals WHERE rental_id = p_rental_id AND asset_id = p_asset_id FOR UPDATE;
    IF v_state IS NULL OR v_state <> 'reserved' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental must exist for this asset and be reserved';
    END IF;
  END IF;

  INSERT INTO checkout (asset_id, booking_id, rental_id, out_time, condition_out, released_by)
  VALUES (p_asset_id, p_booking_id, p_rental_id, IFNULL(p_out_time, NOW()), p_condition_out, p_user_id);
  SET v_new_id = LAST_INSERT_ID();

  IF p_booking_id IS NOT NULL THEN
    UPDATE bookings SET status = 'fulfilled' WHERE booking_id = p_booking_id;
  END IF;
  IF p_rental_id IS NOT NULL THEN
    UPDATE rentals SET status = 'active' WHERE rental_id = p_rental_id;
  END IF;
  UPDATE assets SET status = 'rented' WHERE asset_id = p_asset_id;

  CALL sp_log_asset_event(p_asset_id, p_user_id, 'checked_out',
        CONCAT('Checkout #', v_new_id, ' condition ', p_condition_out),
        JSON_OBJECT('status', 'available'), JSON_OBJECT('status', 'rented', 'checkout_id', v_new_id));
  COMMIT;
  SELECT v_new_id AS checkout_id;
END$$

-- D3. Receive a returned asset. Damaged assets go to maintenance with a repair job.
CREATE PROCEDURE sp_return_asset (
  IN p_checkout_id INT, IN p_user_id INT, IN p_condition_in VARCHAR(10),
  IN p_notes TEXT, IN p_in_time DATETIME)
BEGIN
  DECLARE v_asset     INT;
  DECLARE v_rental    INT;
  DECLARE v_booking   INT;
  DECLARE v_out       DATETIME;
  DECLARE v_in        DATETIME;
  DECLARE v_in_time   DATETIME;
  DECLARE v_due       DATETIME;
  DECLARE v_old_cond  VARCHAR(10);
  DECLARE v_new_state VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT asset_id, rental_id, booking_id, out_time, in_time
    INTO v_asset, v_rental, v_booking, v_out, v_in
    FROM checkout WHERE checkout_id = p_checkout_id FOR UPDATE;
  IF v_asset IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Checkout does not exist';
  END IF;
  IF v_in IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset was already returned';
  END IF;

  SET v_in_time = IFNULL(p_in_time, NOW());
  UPDATE checkout
     SET in_time = v_in_time, condition_in = p_condition_in, received_by = p_user_id, notes = p_notes
   WHERE checkout_id = p_checkout_id;

  -- due moment: end of the rental's last day, or the booking's end_time
  IF v_rental IS NOT NULL THEN
    SELECT TIMESTAMP(DATE_ADD(end_date, INTERVAL 1 DAY)) INTO v_due FROM rentals WHERE rental_id = v_rental;
    UPDATE rentals SET status = 'completed' WHERE rental_id = v_rental;
  ELSE
    SELECT end_time INTO v_due FROM bookings WHERE booking_id = v_booking;
  END IF;

  SELECT `condition` INTO v_old_cond FROM assets WHERE asset_id = v_asset FOR UPDATE;
  SET v_new_state = IF(p_condition_in = 'damaged', 'maintenance', 'available');
  UPDATE assets SET status = v_new_state, `condition` = p_condition_in WHERE asset_id = v_asset;

  CALL sp_log_asset_event(v_asset, p_user_id, 'returned',
        CONCAT('Checkout #', p_checkout_id, ' returned; condition ', p_condition_in,
               IF(v_in_time > v_due, '; LATE', '')),
        JSON_OBJECT('status', 'rented', 'condition', v_old_cond),
        JSON_OBJECT('status', v_new_state, 'condition', p_condition_in));

  IF p_condition_in = 'damaged' THEN
    -- performed_by = returning user as a placeholder assignee; the manager reassigns it
    INSERT INTO maintenance (asset_id, performed_by, type, scheduled_date, status, notes)
    VALUES (v_asset, p_user_id, 'repair', CURDATE(), 'scheduled',
            CONCAT('Auto-created: returned damaged on checkout #', p_checkout_id));
    CALL sp_log_asset_event(v_asset, p_user_id, 'condition_changed',
          'Returned damaged; repair job created', NULL, JSON_OBJECT('condition', 'damaged'));
  END IF;
  COMMIT;

  SELECT p_checkout_id AS checkout_id,
         GREATEST(0, TIMESTAMPDIFF(MINUTE, v_due, v_in_time)) AS minutes_late,
         v_new_state AS asset_status;
END$$

-- D4. Start a maintenance job: asset becomes unavailable.
CREATE PROCEDURE sp_start_maintenance (IN p_maintenance_id INT, IN p_user_id INT)
BEGIN
  DECLARE v_asset  INT;
  DECLARE v_state  VARCHAR(20);
  DECLARE v_astat  VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT asset_id, status INTO v_asset, v_state FROM maintenance WHERE maintenance_id = p_maintenance_id FOR UPDATE;
  IF v_asset IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance job does not exist';
  END IF;
  IF v_state <> 'scheduled' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only scheduled jobs can be started';
  END IF;
  SELECT status INTO v_astat FROM assets WHERE asset_id = v_asset FOR UPDATE;
  IF v_astat = 'rented' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset is currently checked out; return it first';
  END IF;

  UPDATE maintenance SET status = 'in_progress' WHERE maintenance_id = p_maintenance_id;
  IF v_astat = 'available' THEN
    UPDATE assets SET status = 'maintenance' WHERE asset_id = v_asset;
  END IF;
  CALL sp_log_asset_event(v_asset, p_user_id, 'maintenance_started',
        CONCAT('Maintenance #', p_maintenance_id, ' started'),
        JSON_OBJECT('status', v_astat), JSON_OBJECT('status', 'maintenance'));
  COMMIT;
END$$

-- D5. Complete a job; the asset returns to service unless another job is still open.
CREATE PROCEDURE sp_complete_maintenance (
  IN p_maintenance_id INT, IN p_user_id INT, IN p_cost DECIMAL(10,2),
  IN p_notes TEXT, IN p_new_condition VARCHAR(10))   -- NULL keeps current condition
BEGIN
  DECLARE v_asset  INT;
  DECLARE v_state  VARCHAR(20);
  DECLARE v_open   INT DEFAULT 0;
  DECLARE v_cond   VARCHAR(10);
  DECLARE v_astat  VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT asset_id, status INTO v_asset, v_state FROM maintenance WHERE maintenance_id = p_maintenance_id FOR UPDATE;
  IF v_asset IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance job does not exist';
  END IF;
  IF v_state NOT IN ('scheduled','in_progress') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Job is already closed';
  END IF;

  UPDATE maintenance
     SET status = 'completed', completed_date = CURDATE(), completed_by = p_user_id,
         cost = p_cost, notes = IFNULL(p_notes, notes)
   WHERE maintenance_id = p_maintenance_id;

  SELECT `condition`, status INTO v_cond, v_astat FROM assets WHERE asset_id = v_asset FOR UPDATE;
  SELECT COUNT(*) INTO v_open FROM maintenance
   WHERE asset_id = v_asset AND status = 'in_progress';

  UPDATE assets
     SET `condition` = IFNULL(p_new_condition, `condition`),
         status = IF(v_astat = 'maintenance' AND v_open = 0, 'available', status)
   WHERE asset_id = v_asset;

  CALL sp_log_asset_event(v_asset, p_user_id, 'maintenance_completed',
        CONCAT('Maintenance #', p_maintenance_id, ' completed, cost ', p_cost),
        JSON_OBJECT('status', v_astat, 'condition', v_cond),
        JSON_OBJECT('status', IF(v_astat = 'maintenance' AND v_open = 0, 'available', v_astat),
                    'condition', IFNULL(p_new_condition, v_cond)));
  COMMIT;
END$$

DELIMITER ;
