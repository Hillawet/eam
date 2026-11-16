<?php
const DB_HOST = '127.0.0.1';
const DB_NAME = 'asset_rental';
const DB_USER = 'root';
const DB_PASS = '';
const APP_URL = 'http://localhost/croco_backend';
const MAIL_FROM = 'no-reply@croco.com';

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('mysql:host='.DB_HOST.';dbname='.DB_NAME.';charset=utf8mb4', DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    }
    return $pdo;
}

function respond($data, int $status = 200): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function body(): array {
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) return [];
    $data = json_decode($raw, true);
    if (!is_array($data)) respond(['success'=>false,'message'=>'Request body must be valid JSON.'], 400);
    return $data;
}
function requireFields(array $data, array $fields): void {
    foreach ($fields as $field) {
        if (!isset($data[$field]) || (is_string($data[$field]) && trim($data[$field]) === ''))
            respond(['success'=>false,'message'=>"Missing required field: {$field}"], 422);
    }
}
function positiveInt($v): bool { return filter_var($v, FILTER_VALIDATE_INT) !== false && (int)$v > 0; }
function currentUser(): ?array {
    if (session_status() !== PHP_SESSION_ACTIVE) session_start();
    if (empty($_SESSION['user_id'])) return null;
    $q = db()->prepare('SELECT u.user_id,u.role_id,u.full_name,u.email,u.department,u.status,r.role_name,r.permissions FROM users u JOIN roles r ON r.role_id=u.role_id WHERE u.user_id=? AND u.status=\'active\'');
    $q->execute([$_SESSION['user_id']]);
    $u = $q->fetch();
    if (!$u) { session_destroy(); return null; }
    $u['permissions'] = json_decode($u['permissions'], true) ?: [];
    return $u;
}
function needLogin(): array {
    $u = currentUser();
    if (!$u) respond(['success'=>false,'message'=>'Authentication required. Please log in.'], 401);
    return $u;
}
function can(array $u, string $module, string $action): bool {
    // Administrators are still subject to explicit endpoint validation, but have full module access.
    if (strcasecmp($u['role_name'], 'Administrator') === 0) return true;
    return in_array($action, $u['permissions'][$module] ?? [], true);
}
function needPermission(string $module, string $action): array {
    $u = needLogin();
    if (!can($u, $module, $action)) respond(['success'=>false,'message'=>'You do not have permission to perform this action.'], 403);
    return $u;
}
function history(int $assetId, int $userId, string $event, ?string $details=null, $old=null, $new=null): void {
    $q = db()->prepare('INSERT INTO asset_history(asset_id,user_id,event_type,details,old_value,new_value) VALUES(?,?,?,?,?,?)');
    $q->execute([$assetId,$userId,$event,$details,$old===null?null:json_encode($old),$new===null?null:json_encode($new)]);
}
set_exception_handler(function(Throwable $e) {
    error_log((string)$e);
    if ($e instanceof PDOException) {
        $code = 500;
        if (str_contains($e->getMessage(), 'Duplicate entry')) $code = 409;
        if (str_contains($e->getMessage(), 'foreign key constraint')) $code = 422;
        respond(['success'=>false,'message'=>$code===409?'A record with that unique value already exists.':($code===422?'The record references an invalid or in-use related record.':'Database operation failed.')], $code);
    }
    respond(['success'=>false,'message'=>'Unexpected server error. Check the PHP error log.'], 500);
});
