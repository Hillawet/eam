-- =============================================================================
-- asset_rental_extensions.sql           Design-review extensions (NOT part of the 13 tables)
-- Run AFTER the schema, programmability and (optionally) sample-data scripts.
-- Each object states its priority from the design review:
--   [RECOMMENDED] strongly advised   [OPTIONAL] only if the business needs it
-- The 13 original tables are NOT altered by this file.
-- =============================================================================
USE asset_rental;
SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- E1 [OPTIONAL]  PERMISSIONS + ROLE_PERMISSIONS
-- Normalises ROLES.permissions so permissions can be joined, reported on and
-- protected by foreign keys. ROLES.permissions (JSON) stays the source the
-- procedures read today; if you adopt these tables, regenerate the JSON from them
-- (or drop the JSON column in a future migration) so there is ONE source of truth.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS permissions (
  permission_id  INT          NOT NULL AUTO_INCREMENT,
  resource       VARCHAR(40)  NOT NULL COMMENT 'e.g. assets, bookings, payments',
  action         VARCHAR(40)  NOT NULL COMMENT 'e.g. read, create, approve',
  PRIMARY KEY (permission_id),
  UNIQUE KEY uq_permissions_resource_action (resource, action)
) ENGINE=InnoDB COMMENT='Catalogue of grantable permissions';

CREATE TABLE IF NOT EXISTS role_permissions (
  role_id        INT NOT NULL,
  permission_id  INT NOT NULL,
  PRIMARY KEY (role_id, permission_id),
  KEY ix_role_permissions_permission (permission_id),
  CONSTRAINT fk_role_permissions_role FOREIGN KEY (role_id) REFERENCES roles (role_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions (permission_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB COMMENT='Many-to-many link between roles and permissions';

-- Populate both tables from the existing JSON (safe to re-run).
INSERT IGNORE INTO permissions (resource, action)
SELECT DISTINCT k.resource, a.action
FROM roles r
CROSS JOIN JSON_TABLE(JSON_KEYS(r.permissions), '$[*]' COLUMNS (resource VARCHAR(40) PATH '$')) AS k
CROSS JOIN JSON_TABLE(JSON_EXTRACT(r.permissions, CONCAT('$.', k.resource)), '$[*]' COLUMNS (action VARCHAR(40) PATH '$')) AS a;

INSERT IGNORE INTO role_permissions (role_id, permission_id)
SELECT DISTINCT r.role_id, p.permission_id
FROM roles r
CROSS JOIN JSON_TABLE(JSON_KEYS(r.permissions), '$[*]' COLUMNS (resource VARCHAR(40) PATH '$')) AS k
CROSS JOIN JSON_TABLE(JSON_EXTRACT(r.permissions, CONCAT('$.', k.resource)), '$[*]' COLUMNS (action VARCHAR(40) PATH '$')) AS a
JOIN permissions p ON p.resource = k.resource AND p.action = a.action;

-- -----------------------------------------------------------------------------
-- E2 [RECOMMENDED]  RENTAL_ADJUSTMENTS
-- Extensions, late fees, damage fees and discounts as their own ledger rows, so
-- RENTALS.total_charge stays the agreed base price and every change is traceable.
-- Sign convention: charges are positive, discounts negative.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rental_adjustments (
  adjustment_id  INT            NOT NULL AUTO_INCREMENT,
  rental_id      INT            NOT NULL,
  adj_type       ENUM('extension','late_fee','damage_fee','discount','other') NOT NULL,
  amount         DECIMAL(10,2)  NOT NULL COMMENT 'Positive = extra charge, negative = discount',
  description    VARCHAR(255)   NULL,
  created_by     INT            NOT NULL,
  created_at     DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (adjustment_id),
  KEY ix_rental_adjustments_rental (rental_id),
  KEY ix_rental_adjustments_created_by (created_by),
  CONSTRAINT fk_rental_adjustments_rental FOREIGN KEY (rental_id) REFERENCES rentals (rental_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_rental_adjustments_user FOREIGN KEY (created_by) REFERENCES users (user_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_rental_adjustments_sign CHECK (
        (adj_type = 'discount' AND amount < 0)
     OR (adj_type <> 'discount' AND amount > 0))
) ENGINE=InnoDB COMMENT='Charges and discounts applied after the rental was agreed';

-- Balance including adjustments. The core view v_rental_balance is left untouched.
CREATE OR REPLACE VIEW v_rental_balance_adj AS
SELECT b.rental_id, b.contract_ref, b.rental_status, b.total_charge,
       COALESCE(a.adjustments, 0)                           AS adjustments,
       b.total_charge + COALESCE(a.adjustments, 0)          AS amount_due,
       b.amount_paid, b.amount_refunded,
       b.total_charge + COALESCE(a.adjustments, 0) - (b.amount_paid - b.amount_refunded) AS outstanding_balance
FROM v_rental_balance b
LEFT JOIN (SELECT rental_id, SUM(amount) AS adjustments FROM rental_adjustments GROUP BY rental_id) a
       ON a.rental_id = b.rental_id;

-- Demonstration row: 10 days late on rental 3 (45.00/day). Remove if loading into production.
INSERT INTO rental_adjustments (rental_id, adj_type, amount, description, created_by)
SELECT 3, 'late_fee', 450.00, '10 days overdue at 45.00/day (as of 2026-10-15)', 3
WHERE EXISTS (SELECT 1 FROM rentals WHERE rental_id = 3)
  AND NOT EXISTS (SELECT 1 FROM rental_adjustments WHERE rental_id = 3 AND adj_type = 'late_fee');
