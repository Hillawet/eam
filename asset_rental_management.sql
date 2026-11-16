-- =============================================================================
-- asset_rental_management.sql        Deliverable 5: complete schema
-- Asset Rental Management System     MySQL 8.0+ / InnoDB / utf8mb4
-- =============================================================================
-- Load order:  1) this file   2) asset_rental_views_procedures.sql
--              3) asset_rental_sample_data.sql   4) asset_rental_extensions.sql (optional)
--
-- CONVENTIONS
--   * The 13 original tables keep their original names and columns.
--   * Columns that were ADDED during design review carry a tag in their COMMENT:
--        [ADD-M] mandatory     - schema is unsafe/incorrect without it
--        [ADD-R] recommended   - strongly improves integrity or accountability
--        [ADD-O] optional      - convenience
--   * Original columns whose definition was tightened are tagged [FIX].
--   * NOTHING cascades. Every foreign key is ON DELETE RESTRICT ON UPDATE RESTRICT:
--     surrogate keys never change, and financial / audit rows must never vanish
--     because a parent row was deleted. Retire records with a status flag instead.
--   * `condition` is a reserved word in MySQL, so it is always written with
--     backticks. The column name is kept to preserve the original specification.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS asset_rental
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE asset_rental;

SET NAMES utf8mb4;
SET time_zone = '+00:00';   -- store DATETIME values in UTC; convert in the application

-- -----------------------------------------------------------------------------
-- 1. ROLES
-- permissions is a JSON document: {"assets":["read","create"], "bookings":["approve"]}
-- Kept as JSON (original design). A normalised alternative is in
-- asset_rental_extensions.sql (PERMISSIONS / ROLE_PERMISSIONS).
-- -----------------------------------------------------------------------------
CREATE TABLE roles (
  role_id      INT          NOT NULL AUTO_INCREMENT,
  role_name    VARCHAR(50)  NOT NULL,
  permissions  JSON         NOT NULL DEFAULT (JSON_OBJECT())
               COMMENT '[FIX] now NOT NULL, defaults to {}. Structured permission map read by the application',
  PRIMARY KEY (role_id),
  UNIQUE KEY uq_roles_role_name (role_name),
  CONSTRAINT ck_roles_permissions_object CHECK (JSON_TYPE(permissions) = 'OBJECT')
) ENGINE=InnoDB COMMENT='Roles assigned to system users; permissions drive RBAC in the application';

-- -----------------------------------------------------------------------------
-- 2. USERS
-- password_hash holds an application-generated bcrypt/argon2id string. The
-- database never sees or computes plaintext passwords.
-- -----------------------------------------------------------------------------
CREATE TABLE users (
  user_id        INT           NOT NULL AUTO_INCREMENT,
  role_id        INT           NOT NULL,
  full_name      VARCHAR(120)  NOT NULL,
  email          VARCHAR(190)  NOT NULL COMMENT 'Login identifier; unique, case-insensitive collation',
  password_hash  VARCHAR(255)  NOT NULL COMMENT 'bcrypt / argon2id hash produced by the application. Never plaintext',
  department     VARCHAR(80)   NULL,
  status         ENUM('active','inactive','suspended') NOT NULL DEFAULT 'active'
                 COMMENT '[FIX] ENUM. inactive = left the company, suspended = temporarily blocked. Users are never deleted',
  created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '[ADD-O] account creation time',
  PRIMARY KEY (user_id),
  UNIQUE KEY uq_users_email (email),
  KEY ix_users_role (role_id),
  CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles (role_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_users_email_shape CHECK (email LIKE '%_@_%._%'),
  CONSTRAINT ck_users_hash_length CHECK (CHAR_LENGTH(password_hash) >= 20)
) ENGINE=InnoDB COMMENT='Employees and system users';

-- -----------------------------------------------------------------------------
-- 3. ASSET_CATEGORIES
-- -----------------------------------------------------------------------------
CREATE TABLE asset_categories (
  category_id    INT          NOT NULL AUTO_INCREMENT,
  category_name  VARCHAR(80)  NOT NULL,
  rentable       BOOLEAN      NOT NULL DEFAULT TRUE
                 COMMENT 'FALSE = internal-use only; assets of this category can never be rented to customers',
  mobile         BOOLEAN      NOT NULL DEFAULT FALSE
                 COMMENT 'TRUE = assets move between places and may be tracked in LOCATION_LOG',
  PRIMARY KEY (category_id),
  UNIQUE KEY uq_asset_categories_name (category_name)
) ENGINE=InnoDB COMMENT='Asset classification; decides rentability and mobility';

-- -----------------------------------------------------------------------------
-- 5. LOCATIONS  (created before ASSETS because ASSETS references it)
-- Adjacency-list hierarchy: Company -> Branch -> Warehouse -> Storage room.
-- Cycles and self-parenting are blocked by triggers trg_locations_bi / trg_locations_bu.
-- -----------------------------------------------------------------------------
CREATE TABLE locations (
  location_id         INT          NOT NULL AUTO_INCREMENT,
  parent_location_id  INT          NULL COMMENT 'NULL = top of the hierarchy (the company)',
  name                VARCHAR(120) NOT NULL,
  type                ENUM('company','branch','warehouse','storage_room','office','yard','other')
                      NOT NULL DEFAULT 'other' COMMENT '[FIX] ENUM',
  PRIMARY KEY (location_id),
  UNIQUE KEY uq_locations_parent_name (parent_location_id, name),
  CONSTRAINT fk_locations_parent FOREIGN KEY (parent_location_id) REFERENCES locations (location_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
  -- MySQL forbids CHECK constraints on AUTO_INCREMENT columns, so "a location cannot be its own
  -- parent" and the cycle check are both enforced by triggers (trg_locations_bi/bu).
) ENGINE=InnoDB COMMENT='Physical locations in a self-referencing hierarchy';

-- -----------------------------------------------------------------------------
-- 4. ASSETS
-- status      = operational availability (can it be handed out?)
-- `condition` = physical state (how worn/damaged is it?)
-- Maintenance progress lives in MAINTENANCE; the two are deliberately separate.
-- -----------------------------------------------------------------------------
CREATE TABLE assets (
  asset_id       INT            NOT NULL AUTO_INCREMENT,
  asset_tag      VARCHAR(40)    NOT NULL COMMENT 'Barcode / label printed on the asset, e.g. PT-0001',
  category_id    INT            NOT NULL,
  location_id    INT            NOT NULL COMMENT 'Current home location',
  latitude       DECIMAL(10,8)  DEFAULT -15.3875 COMMENT 'Latest reported GPS latitude (WGS84)',
  longitude      DECIMAL(10,8)  DEFAULT 28.3228 COMMENT 'Latest reported GPS longitude (WGS84)',
  last_gps_update TIMESTAMP     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Time the asset GPS position was last updated',
  name           VARCHAR(150)   NOT NULL,
  status         ENUM('available','rented','maintenance','retired','lost') NOT NULL DEFAULT 'available'
                 COMMENT '[FIX] ENUM. Only available/rented assets may enter new rentals',
  `condition`    ENUM('new','good','fair','poor','damaged') NOT NULL DEFAULT 'good' COMMENT '[FIX] ENUM',
  purchase_date  DATE           NULL,
  daily_rate     DECIMAL(10,2)  NOT NULL DEFAULT 0.00 COMMENT 'Standard charge per rental day',
  created_at     DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '[ADD-O]',
  updated_at     DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '[ADD-O]',
  PRIMARY KEY (asset_id),
  UNIQUE KEY uq_assets_tag (asset_tag),
  KEY ix_assets_category (category_id),
  KEY ix_assets_location (location_id),
  KEY ix_assets_status (status),
  CONSTRAINT fk_assets_category FOREIGN KEY (category_id) REFERENCES asset_categories (category_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_assets_location FOREIGN KEY (location_id) REFERENCES locations (location_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_assets_daily_rate CHECK (daily_rate >= 0)
) ENGINE=InnoDB COMMENT='Every company-owned or managed asset';

-- -----------------------------------------------------------------------------
-- 6. CUSTOMERS  (email / phone are NOT unique on purpose: families and
-- companies share them; duplicates are handled by the application, not a constraint)
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
  customer_id  INT           NOT NULL AUTO_INCREMENT,
  name         VARCHAR(150)  NOT NULL,
  phone        VARCHAR(30)   NULL,
  email        VARCHAR(190)  NULL,
  id_number    VARCHAR(255)  NULL COMMENT 'Sensitive. Store application-encrypted (or tokenised) value, never raw. Wide column allows ciphertext',
  is_active    BOOLEAN       NOT NULL DEFAULT TRUE COMMENT '[ADD-R] soft-delete flag; customers with history are never deleted',
  created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '[ADD-O]',
  PRIMARY KEY (customer_id),
  KEY ix_customers_name (name),
  KEY ix_customers_email (email),
  KEY ix_customers_phone (phone),
  CONSTRAINT ck_customers_email_shape CHECK (email IS NULL OR email LIKE '%_@_%._%'),
  CONSTRAINT ck_customers_contact CHECK (phone IS NOT NULL OR email IS NOT NULL)
) ENGINE=InnoDB COMMENT='People and companies that rent assets';

-- -----------------------------------------------------------------------------
-- 7. BOOKINGS  (internal reservation requests; no money involved)
-- Overlap of approved bookings is blocked by trigger (MySQL has no exclusion
-- constraints) - see asset_rental_views_procedures.sql.
-- Time ranges are half-open [start_time, end_time).
-- -----------------------------------------------------------------------------
CREATE TABLE bookings (
  booking_id    INT           NOT NULL AUTO_INCREMENT,
  asset_id      INT           NOT NULL,
  requested_by  INT           NOT NULL,
  approved_by   INT           NULL COMMENT 'Set when a manager approves OR rejects the request',
  start_time    DATETIME      NOT NULL,
  end_time      DATETIME      NOT NULL,
  purpose       TEXT          NULL,
  status        ENUM('pending','approved','rejected','cancelled','fulfilled') NOT NULL DEFAULT 'pending'
                COMMENT '[FIX] ENUM. pending -> approved|rejected|cancelled; approved -> fulfilled|cancelled',
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '[ADD-R] when the request was made',
  decided_at    DATETIME      NULL COMMENT '[ADD-R] when approved or rejected',
  PRIMARY KEY (booking_id),
  UNIQUE KEY uq_bookings_id_asset (booking_id, asset_id) COMMENT 'Target of the composite FK from CHECKOUT',
  KEY ix_bookings_asset_period (asset_id, status, start_time, end_time),
  KEY ix_bookings_status_start (status, start_time),
  KEY ix_bookings_requested_by (requested_by),
  KEY ix_bookings_approved_by (approved_by),
  CONSTRAINT fk_bookings_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_bookings_requested_by FOREIGN KEY (requested_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_bookings_approved_by FOREIGN KEY (approved_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_bookings_time_range CHECK (end_time > start_time),
  CONSTRAINT ck_bookings_decision_has_approver
    CHECK (status NOT IN ('approved','rejected','fulfilled') OR approved_by IS NOT NULL),
  CONSTRAINT ck_bookings_separation_of_duties CHECK (approved_by IS NULL OR approved_by <> requested_by)
) ENGINE=InnoDB COMMENT='Requests to reserve an asset for a period';

-- -----------------------------------------------------------------------------
-- 11. RENTALS (defined before CHECKOUT/PAYMENTS). One asset per rental (original
-- design). Multi-asset contracts: see RENTAL_ITEMS proposal in the documentation.
-- Dates are inclusive: start_date..end_date, days = DATEDIFF(end,start)+1.
-- -----------------------------------------------------------------------------
CREATE TABLE rentals (
  rental_id     INT            NOT NULL AUTO_INCREMENT,
  asset_id      INT            NOT NULL,
  customer_id   INT            NOT NULL,
  handled_by    INT            NOT NULL COMMENT 'Staff member who created/owns the agreement',
  start_date    DATE           NOT NULL,
  end_date      DATE           NOT NULL COMMENT 'Last day of the rental (inclusive); extended by updating this value',
  total_charge  DECIMAL(10,2)  NOT NULL COMMENT 'Agreed rental charge = daily_rate x days - discounts (before adjustments)',
  deposit       DECIMAL(10,2)  NOT NULL DEFAULT 0.00 COMMENT 'Refundable security deposit; NOT part of the balance due',
  contract_ref  VARCHAR(40)    NULL COMMENT 'Printed contract number; unique when present',
  status        ENUM('pending','reserved','active','completed','cancelled') NOT NULL DEFAULT 'pending'
                COMMENT '[FIX] ENUM. Overdue is derived (active AND end_date < today), not stored',
  created_at    DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '[ADD-O]',
  PRIMARY KEY (rental_id),
  UNIQUE KEY uq_rentals_contract_ref (contract_ref),
  UNIQUE KEY uq_rentals_id_asset (rental_id, asset_id) COMMENT 'Target of the composite FK from CHECKOUT',
  KEY ix_rentals_customer (customer_id),
  KEY ix_rentals_asset_period (asset_id, start_date, end_date),
  KEY ix_rentals_status (status),
  KEY ix_rentals_handled_by (handled_by),
  CONSTRAINT fk_rentals_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_rentals_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_rentals_handled_by FOREIGN KEY (handled_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_rentals_dates CHECK (end_date >= start_date),
  CONSTRAINT ck_rentals_charge CHECK (total_charge >= 0),
  CONSTRAINT ck_rentals_deposit CHECK (deposit >= 0)
) ENGINE=InnoDB COMMENT='Formal rental agreements (one asset per agreement)';

-- -----------------------------------------------------------------------------
-- 8. MAINTENANCE
-- performed_by = ASSIGNED technician (kept as originally named).
-- completed_by = who actually finished the job (added, may differ).
-- -----------------------------------------------------------------------------
CREATE TABLE maintenance (
  maintenance_id  INT            NOT NULL AUTO_INCREMENT,
  asset_id        INT            NOT NULL,
  performed_by    INT            NOT NULL COMMENT 'Assigned technician / responsible user',
  type            ENUM('preventive','repair','inspection','servicing') NOT NULL COMMENT '[FIX] ENUM',
  scheduled_date  DATE           NOT NULL,
  completed_date  DATE           NULL,
  cost            DECIMAL(10,2)  NOT NULL DEFAULT 0.00,
  status          ENUM('scheduled','in_progress','completed','cancelled') NOT NULL DEFAULT 'scheduled'
                  COMMENT '[FIX] ENUM. in_progress keeps the asset in maintenance status',
  completed_by    INT            NULL COMMENT '[ADD-R] user who actually completed the work',
  notes           TEXT           NULL COMMENT '[ADD-O] findings / parts used',
  PRIMARY KEY (maintenance_id),
  KEY ix_maintenance_asset_sched (asset_id, scheduled_date),
  KEY ix_maintenance_performed_by (performed_by),
  KEY ix_maintenance_completed_by (completed_by),
  KEY ix_maintenance_status_sched (status, scheduled_date),
  CONSTRAINT fk_maintenance_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_maintenance_performed_by FOREIGN KEY (performed_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_maintenance_completed_by FOREIGN KEY (completed_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_maintenance_cost CHECK (cost >= 0),
  CONSTRAINT ck_maintenance_completion
    CHECK ((status = 'completed' AND completed_date IS NOT NULL AND completed_by IS NOT NULL)
        OR (status <> 'completed' AND completed_date IS NULL))
) ENGINE=InnoDB COMMENT='Preventive maintenance, repairs, inspections and servicing';

-- -----------------------------------------------------------------------------
-- 9. ASSET_HISTORY  (append-only audit trail; UPDATE/DELETE blocked by triggers)
-- -----------------------------------------------------------------------------
CREATE TABLE asset_history (
  history_id   INT          NOT NULL AUTO_INCREMENT,
  asset_id     INT          NOT NULL,
  user_id      INT          NOT NULL COMMENT 'Who performed the action',
  event_type   VARCHAR(50)  NOT NULL
               COMMENT 'registered, updated, booking_approved, booking_cancelled, checked_out, returned, condition_changed, maintenance_started, maintenance_completed, location_changed, retired',
  details      TEXT         NULL,
  event_time   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  old_value    JSON         NULL COMMENT '[ADD-R] state before the change, e.g. {"status":"available"}',
  new_value    JSON         NULL COMMENT '[ADD-R] state after the change',
  PRIMARY KEY (history_id),
  KEY ix_history_asset_time (asset_id, event_time),
  KEY ix_history_user (user_id),
  KEY ix_history_event_type (event_type),
  CONSTRAINT fk_history_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_history_user FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_history_event_type CHECK (CHAR_LENGTH(TRIM(event_type)) > 0)
) ENGINE=InnoDB COMMENT='Immutable audit trail of asset events';

-- -----------------------------------------------------------------------------
-- 10. LOCATION_LOG  (coordinate observations for mobile assets)
-- -----------------------------------------------------------------------------
CREATE TABLE location_log (
  log_id       INT            NOT NULL AUTO_INCREMENT,
  asset_id     INT            NOT NULL,
  latitude     DECIMAL(9,6)   NOT NULL COMMENT 'WGS84 degrees, 6 d.p. is roughly 0.11 m',
  longitude    DECIMAL(9,6)   NOT NULL COMMENT 'WGS84 degrees',
  recorded_at  DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  source       ENUM('gps','manual','scan','import') NOT NULL DEFAULT 'manual'
               COMMENT '[ADD-R] how the position was obtained',
  recorded_by  INT            NULL COMMENT '[ADD-R] user for manual/scan entries; NULL for device (GPS) feeds',
  PRIMARY KEY (log_id),
  KEY ix_location_log_asset_time (asset_id, recorded_at),
  KEY ix_location_log_recorded_by (recorded_by),
  CONSTRAINT fk_location_log_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_location_log_user FOREIGN KEY (recorded_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_location_log_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT ck_location_log_lon CHECK (longitude BETWEEN -180 AND 180)
) ENGINE=InnoDB COMMENT='Position observations for mobile assets';

-- -----------------------------------------------------------------------------
-- 12. CHECKOUT  (physical handover and return)
-- * Composite FKs (booking_id,asset_id) and (rental_id,asset_id) force the
--   checkout asset to equal the booking/rental asset.
-- * Both booking_id and rental_id are nullable (MATCH SIMPLE skips the FK when
--   a part is NULL); CHECK requires at least one of them.
-- * active_asset_id + UNIQUE index = at most ONE open checkout per asset,
--   enforced declaratively (NULLs are ignored by UNIQUE).
-- -----------------------------------------------------------------------------
CREATE TABLE checkout (
  checkout_id     INT       NOT NULL AUTO_INCREMENT,
  asset_id        INT       NOT NULL,
  booking_id      INT       NULL,
  rental_id       INT       NULL,
  out_time        DATETIME  NOT NULL,
  in_time         DATETIME  NULL COMMENT 'NULL = asset is still out',
  condition_out   ENUM('new','good','fair','poor','damaged') NOT NULL COMMENT '[FIX] required, ENUM',
  condition_in    ENUM('new','good','fair','poor','damaged') NULL,
  released_by     INT       NOT NULL COMMENT '[ADD-R] staff member who handed the asset over',
  received_by     INT       NULL COMMENT '[ADD-R] staff member who inspected the return',
  notes           TEXT      NULL COMMENT '[ADD-O] damage / missing-item notes',
  active_asset_id INT GENERATED ALWAYS AS (IF(in_time IS NULL, asset_id, NULL)) STORED
                  COMMENT '[ADD-M] helper: asset_id while checkout is open, else NULL',
  PRIMARY KEY (checkout_id),
  UNIQUE KEY uq_checkout_one_open_per_asset (active_asset_id),
  KEY ix_checkout_asset_out (asset_id, out_time),
  KEY ix_checkout_booking_asset (booking_id, asset_id),
  KEY ix_checkout_rental_asset (rental_id, asset_id),
  KEY ix_checkout_released_by (released_by),
  KEY ix_checkout_received_by (received_by),
  CONSTRAINT fk_checkout_asset FOREIGN KEY (asset_id) REFERENCES assets (asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_checkout_booking FOREIGN KEY (booking_id, asset_id) REFERENCES bookings (booking_id, asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_checkout_rental FOREIGN KEY (rental_id, asset_id) REFERENCES rentals (rental_id, asset_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_checkout_released_by FOREIGN KEY (released_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_checkout_received_by FOREIGN KEY (received_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_checkout_has_source CHECK (booking_id IS NOT NULL OR rental_id IS NOT NULL),
  CONSTRAINT ck_checkout_times CHECK (in_time IS NULL OR in_time >= out_time),
  CONSTRAINT ck_checkout_return_pair CHECK ((in_time IS NULL AND condition_in IS NULL)
                                         OR (in_time IS NOT NULL AND condition_in IS NOT NULL))
) ENGINE=InnoDB COMMENT='Physical handover and return of assets';

-- -----------------------------------------------------------------------------
-- 13. PAYMENTS  (a ledger: payments, refunds and deposits are separate types;
-- amount is ALWAYS positive, txn_type gives it direction)
-- -----------------------------------------------------------------------------
CREATE TABLE payments (
  payment_id          INT            NOT NULL AUTO_INCREMENT,
  rental_id           INT            NOT NULL,
  amount              DECIMAL(10,2)  NOT NULL COMMENT 'Always > 0; direction comes from txn_type',
  paid_on             DATE           NOT NULL,
  method              ENUM('cash','card','bank_transfer','mobile_money','cheque','other') NOT NULL COMMENT '[FIX] ENUM',
  txn_type            ENUM('payment','refund','deposit','deposit_refund') NOT NULL DEFAULT 'payment'
                      COMMENT '[ADD-M] refunds must not look like ordinary payments. Only payment/refund affect the balance due',
  status              ENUM('completed','pending','failed','reversed') NOT NULL DEFAULT 'completed'
                      COMMENT '[ADD-M] only completed rows count towards the balance',
  recorded_by         INT            NOT NULL COMMENT '[ADD-R] cashier who captured the transaction',
  reference_no        VARCHAR(60)    NULL COMMENT '[ADD-R] receipt / bank / card-terminal reference for reconciliation',
  related_payment_id  INT            NULL COMMENT '[ADD-O] refund or reversal points at the original payment',
  PRIMARY KEY (payment_id),
  KEY ix_payments_rental_paid (rental_id, paid_on),
  KEY ix_payments_paid_on (paid_on),
  KEY ix_payments_recorded_by (recorded_by),
  KEY ix_payments_related (related_payment_id),
  CONSTRAINT fk_payments_rental FOREIGN KEY (rental_id) REFERENCES rentals (rental_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_payments_recorded_by FOREIGN KEY (recorded_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_payments_related FOREIGN KEY (related_payment_id) REFERENCES payments (payment_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_payments_amount CHECK (amount > 0)
) ENGINE=InnoDB COMMENT='Financial ledger entries for rentals';
