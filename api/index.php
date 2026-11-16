<?php
require_once __DIR__ . '/config.php';

// Cookie-based sessions for same-origin frontend requests. HTTPS should be enabled in production.
if (session_status() !== PHP_SESSION_ACTIVE) {
    session_set_cookie_params(['httponly'=>true,'samesite'=>'Lax','secure'=>!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']!=='off']);
    session_start();
}
header('Cache-Control: no-store');
$method = $_SERVER['REQUEST_METHOD'];
$resource = strtolower($_GET['resource'] ?? '');
$id = isset($_GET['id']) ? (int)$_GET['id'] : 0;
$input = in_array($method, ['POST','PUT','PATCH'], true) ? body() : [];
$pdo = db();

// Health check: GET api/index.php
if ($resource === '' && $method === 'GET') respond(['success'=>true,'message'=>'Croco Plant EAM API is running.','version'=>'1.0']);

// ---------------- PUBLIC RENTAL CATALOGUE ----------------
if ($resource === 'catalog') {
    if ($method !== 'GET') respond(['success'=>false,'message'=>'Unsupported catalogue HTTP method.'],405);
    $startDate = $_GET['start_date'] ?? '';
    $endDate = $_GET['end_date'] ?? '';
    if (!is_string($startDate)||!is_string($endDate)) respond(['success'=>false,'message'=>'Dates must use YYYY-MM-DD format.'],422);
    $startDate=trim($startDate); $endDate=trim($endDate);
    if (($startDate === '') !== ($endDate === '')) respond(['success'=>false,'message'=>'Provide both start_date and end_date.'],422);
    if ($startDate !== '') {
        foreach ([$startDate,$endDate] as $date) {
            $parsed = DateTimeImmutable::createFromFormat('!Y-m-d',$date);
            if (!$parsed || $parsed->format('Y-m-d') !== $date) respond(['success'=>false,'message'=>'Dates must use YYYY-MM-DD format.'],422);
        }
        $days=(int)(new DateTimeImmutable($startDate))->diff(new DateTimeImmutable($endDate))->format('%a')+1;
        if ($endDate < $startDate||$startDate<(new DateTimeImmutable('today'))->format('Y-m-d')||$days>365) respond(['success'=>false,'message'=>'Choose dates within the next 365 days, with the end date on or after the start date.'],422);
    }

    $where = ['c.rentable=1',$startDate===''?"a.status='available'":"a.status IN ('available','rented')",'COALESCE(d.is_public,1)=1'];
    $args = [];
    if (!empty($_GET['category_id'])) {
        if (!positiveInt($_GET['category_id'])) respond(['success'=>false,'message'=>'category_id must be a positive integer.'],422);
        $where[]='a.category_id=?'; $args[]=(int)$_GET['category_id'];
    }
    if (!empty($_GET['location_id'])) {
        if (!positiveInt($_GET['location_id'])) respond(['success'=>false,'message'=>'location_id must be a positive integer.'],422);
        $where[]='a.location_id=?'; $args[]=(int)$_GET['location_id'];
    }
    if (!empty($_GET['search'])) {
        if (!is_string($_GET['search'])) respond(['success'=>false,'message'=>'Search text must be text.'],422);
        $search = trim($_GET['search']);
        if (strlen($search) > 100) respond(['success'=>false,'message'=>'Search text is too long.'],422);
        $where[]='(a.name LIKE ? OR c.category_name LIKE ? OR l.name LIKE ?)';
        $term='%'.$search.'%'; array_push($args,$term,$term,$term);
    }
    $availability = $startDate===''?"a.status='available'":'1';
    if ($startDate !== '') {
        $availability = "NOT EXISTS (SELECT 1 FROM bookings b WHERE b.asset_id=a.asset_id AND b.status IN ('approved','fulfilled') AND b.start_time<DATE_ADD(?,INTERVAL 1 DAY) AND b.end_time>?)".
            " AND NOT EXISTS (SELECT 1 FROM rentals r WHERE r.asset_id=a.asset_id AND r.status IN ('reserved','active') AND r.start_date<=? AND r.end_date>=?)";
        $args = [$endDate,$startDate,$endDate,$startDate,...$args];
    }
    $sql = "SELECT a.asset_id,a.name,a.daily_rate,a.`condition`,c.category_id,c.category_name,l.location_id,l.name AS location_name,".
        "d.description,d.image_url,d.specifications,d.rental_terms,CASE WHEN $availability THEN 1 ELSE 0 END AS available ".
        "FROM assets a JOIN asset_categories c ON c.category_id=a.category_id JOIN locations l ON l.location_id=a.location_id ".
        "LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id WHERE ".implode(' AND ',$where).
        ' ORDER BY c.category_name,a.name';
    $q=$pdo->prepare($sql); $q->execute($args); $assets=$q->fetchAll();
    foreach ($assets as &$asset) {
        $asset['available']=(bool)$asset['available'];
        $asset['daily_rate']=(float)$asset['daily_rate'];
        $asset['specifications']=$asset['specifications']===null?[]:(json_decode($asset['specifications'],true)?:[]);
    }
    unset($asset);
    $categories=$pdo->query("SELECT DISTINCT c.category_id,c.category_name FROM asset_categories c JOIN assets a ON a.category_id=c.category_id LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id WHERE c.rentable=1 AND a.status IN ('available','rented') AND COALESCE(d.is_public,1)=1 ORDER BY c.category_name")->fetchAll();
    $locations=$pdo->query("SELECT DISTINCT l.location_id,l.name AS location_name FROM locations l JOIN assets a ON a.location_id=l.location_id JOIN asset_categories c ON c.category_id=a.category_id LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id WHERE c.rentable=1 AND a.status IN ('available','rented') AND COALESCE(d.is_public,1)=1 ORDER BY l.name")->fetchAll();
    respond(['success'=>true,'data'=>$assets,'categories'=>$categories,'locations'=>$locations]);
}

// ---------------- PUBLIC RENTAL REQUESTS ----------------
if ($resource === 'rental-requests') {
    if ($method === 'POST') {
        requireFields($input,['name','email','phone','start_date','end_date','items']);
        foreach (['name','email','phone','start_date','end_date'] as $field) {
            if (!is_string($input[$field])) respond(['success'=>false,'message'=>"{$field} must be text."],422);
        }
        $name=trim($input['name']); $email=strtolower(trim($input['email'])); $phone=trim($input['phone']);
        if (strlen($name)<2||strlen($name)>150) respond(['success'=>false,'message'=>'Name must be between 2 and 150 characters.'],422);
        if (!filter_var($email,FILTER_VALIDATE_EMAIL)||strlen($email)>190) respond(['success'=>false,'message'=>'Enter a valid email address.'],422);
        if (strlen($phone)<5||strlen($phone)>30) respond(['success'=>false,'message'=>'Enter a valid phone number.'],422);
        $startDate=trim($input['start_date']); $endDate=trim($input['end_date']);
        foreach ([$startDate,$endDate] as $date) {
            $parsed=DateTimeImmutable::createFromFormat('!Y-m-d',$date);
            if (!$parsed||$parsed->format('Y-m-d')!==$date) respond(['success'=>false,'message'=>'Dates must use YYYY-MM-DD format.'],422);
        }
        $start=new DateTimeImmutable($startDate); $end=new DateTimeImmutable($endDate);
        $days=(int)$start->diff($end)->format('%a')+1;
        if ($end<$start||$startDate<(new DateTimeImmutable('today'))->format('Y-m-d')||$days>365) respond(['success'=>false,'message'=>'Choose a valid rental period of up to 365 days, starting today or later.'],422);
        if (!is_array($input['items'])||count($input['items'])<1||count($input['items'])>10) respond(['success'=>false,'message'=>'Select between 1 and 10 catalogue items.'],422);
        $assetIds=[];
        foreach ($input['items'] as $item) {
            if (!is_array($item)||!isset($item['asset_id'])||!positiveInt($item['asset_id'])) respond(['success'=>false,'message'=>'Each selected item must have a valid asset_id.'],422);
            $assetIds[]=(int)$item['asset_id'];
        }
        if (count(array_unique($assetIds))!==count($assetIds)) respond(['success'=>false,'message'=>'Each asset can only be selected once.'],422);
        sort($assetIds,SORT_NUMERIC);
        if (isset($input['requirements'])&&!is_string($input['requirements'])) respond(['success'=>false,'message'=>'requirements must be text.'],422);
        $requirements=trim($input['requirements']??'');
        if (strlen($requirements)>2000) respond(['success'=>false,'message'=>'Additional requirements must be 2000 characters or fewer.'],422);

        $pdo->beginTransaction();
        try {
            $selected=[];
            $assetQuery=$pdo->prepare("SELECT a.asset_id,a.daily_rate FROM assets a JOIN asset_categories c ON c.category_id=a.category_id LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id WHERE a.asset_id=? AND a.status IN ('available','rented') AND c.rentable=1 AND COALESCE(d.is_public,1)=1 FOR UPDATE");
            $bookingCheck=$pdo->prepare("SELECT COUNT(*) FROM bookings WHERE asset_id=? AND status IN ('approved','fulfilled') AND start_time<DATE_ADD(?,INTERVAL 1 DAY) AND end_time>?");
            $rentalCheck=$pdo->prepare("SELECT COUNT(*) FROM rentals WHERE asset_id=? AND status IN ('reserved','active') AND start_date<=? AND end_date>=?");
            foreach ($assetIds as $assetId) {
                $assetQuery->execute([$assetId]); $asset=$assetQuery->fetch();
                if (!$asset) throw new DomainException('One or more selected items are no longer available for rental.');
                $bookingCheck->execute([$assetId,$endDate,$startDate]);
                $rentalCheck->execute([$assetId,$endDate,$startDate]);
                if ((int)$bookingCheck->fetchColumn()||(int)$rentalCheck->fetchColumn()) throw new DomainException('One or more selected items are already booked for those dates. Please review availability and try again.');
                $selected[]=$asset;
            }
            $q=$pdo->prepare('INSERT INTO customers(name,phone,email) VALUES(?,?,?)');
            $q->execute([$name,$phone,$email]); $customerId=(int)$pdo->lastInsertId();
            $q=$pdo->prepare("INSERT INTO public_rental_requests(customer_id,start_date,end_date,requirements) VALUES(?,?,?,?)");
            $q->execute([$customerId,$startDate,$endDate,$requirements===''?null:$requirements]); $requestId=(int)$pdo->lastInsertId();
            $itemInsert=$pdo->prepare('INSERT INTO public_rental_request_items(request_id,asset_id,daily_rate) VALUES(?,?,?)');
            foreach ($selected as $asset) $itemInsert->execute([$requestId,(int)$asset['asset_id'],(float)$asset['daily_rate']]);
            $pdo->commit();
        } catch (DomainException $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            respond(['success'=>false,'message'=>$e->getMessage()],409);
        } catch (Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            throw $e;
        }
        respond(['success'=>true,'message'=>'Your rental request has been sent to Croco Plant for review.','request_id'=>$requestId],201);
    }
    if ($method === 'GET') {
        needPermission('bookings','read');
        $where=[]; $args=[];
        if (!empty($_GET['status'])) {
            $statuses=['pending','contacted','approved','rejected','cancelled'];
            if (!in_array($_GET['status'],$statuses,true)) respond(['success'=>false,'message'=>'Invalid rental request status.'],422);
            $where[]='rr.status=?'; $args[]=$_GET['status'];
        }
        $sql='SELECT rr.request_id,rr.start_date,rr.end_date,rr.requirements,rr.status,rr.created_at,c.name AS customer_name,c.email,c.phone,u.full_name AS reviewed_by_name FROM public_rental_requests rr JOIN customers c ON c.customer_id=rr.customer_id LEFT JOIN users u ON u.user_id=rr.reviewed_by';
        if ($where) $sql.=' WHERE '.implode(' AND ',$where);
        $sql.=' ORDER BY rr.created_at DESC';
        $q=$pdo->prepare($sql); $q->execute($args); $requests=$q->fetchAll();
        if ($requests) {
            $ids=array_column($requests,'request_id');
            $placeholders=implode(',',array_fill(0,count($ids),'?'));
            $itemsQuery=$pdo->prepare("SELECT i.request_id,a.asset_id,a.name AS asset_name,a.daily_rate,i.daily_rate AS requested_daily_rate,c.category_name FROM public_rental_request_items i JOIN assets a ON a.asset_id=i.asset_id JOIN asset_categories c ON c.category_id=a.category_id WHERE i.request_id IN ($placeholders) ORDER BY a.name");
            $itemsQuery->execute($ids); $itemsByRequest=[];
            foreach ($itemsQuery->fetchAll() as $item) $itemsByRequest[$item['request_id']][]=$item;
            foreach ($requests as &$request) $request['items']=$itemsByRequest[$request['request_id']]??[];
            unset($request);
        }
        respond(['success'=>true,'data'=>$requests]);
    }
    if ($method === 'PATCH' && $id>0) {
        $user=needPermission('bookings','approve'); requireFields($input,['status']);
        $newStatus=$input['status'];
        if (!in_array($newStatus,['contacted','approved','rejected','cancelled'],true)) respond(['success'=>false,'message'=>'Invalid rental request status.'],422);
        $pdo->beginTransaction();
        try {
            $q=$pdo->prepare('SELECT * FROM public_rental_requests WHERE request_id=? FOR UPDATE'); $q->execute([$id]); $request=$q->fetch();
            if (!$request) throw new OutOfBoundsException('Rental request not found.');
            if (!in_array($request['status'],['pending','contacted'],true)) throw new DomainException('This rental request has already been decided.');
            if ($newStatus==='approved') {
                if ($request['start_date']<(new DateTimeImmutable('today'))->format('Y-m-d')) throw new DomainException('The requested start date has passed; contact the customer before approving.');
                $itemQuery=$pdo->prepare('SELECT i.request_item_id,i.asset_id,a.status,c.rentable FROM public_rental_request_items i JOIN assets a ON a.asset_id=i.asset_id JOIN asset_categories c ON c.category_id=a.category_id WHERE i.request_id=? ORDER BY i.asset_id FOR UPDATE');
                $itemQuery->execute([$id]); $items=$itemQuery->fetchAll();
                if (!$items) throw new DomainException('This request has no items to approve.');
                $bookingCheck=$pdo->prepare("SELECT COUNT(*) FROM bookings WHERE asset_id=? AND status IN ('approved','fulfilled') AND start_time<DATE_ADD(?,INTERVAL 1 DAY) AND end_time>?");
                $rentalCheck=$pdo->prepare("SELECT COUNT(*) FROM rentals WHERE asset_id=? AND status IN ('reserved','active') AND start_date<=? AND end_date>=?");
                $insertBooking=$pdo->prepare("INSERT INTO bookings(asset_id,requested_by,approved_by,public_request_item_id,start_time,end_time,purpose,status,decided_at) VALUES(?,NULL,?,?,?,? ,?,'approved',UTC_TIMESTAMP())");
                $startTime=$request['start_date'].' 00:00:00';
                $endTime=(new DateTimeImmutable($request['end_date']))->modify('+1 day')->format('Y-m-d').' 00:00:00';
                foreach ($items as $item) {
                    if (!in_array($item['status'],['available','rented'],true)||!(int)$item['rentable']) throw new DomainException('An item in this request is no longer available to rent.');
                    $bookingCheck->execute([(int)$item['asset_id'],$request['end_date'],$request['start_date']]);
                    $rentalCheck->execute([(int)$item['asset_id'],$request['end_date'],$request['start_date']]);
                    if ((int)$bookingCheck->fetchColumn()||(int)$rentalCheck->fetchColumn()) throw new DomainException('An item in this request has since been booked for those dates.');
                    $purpose='Public rental request #'.$id;
                    if (!empty($request['requirements'])) $purpose.=': '.$request['requirements'];
                    $insertBooking->execute([(int)$item['asset_id'],$user['user_id'],(int)$item['request_item_id'],$startTime,$endTime,$purpose]);
                }
            }
            $q=$pdo->prepare('UPDATE public_rental_requests SET status=?,reviewed_by=?,reviewed_at=UTC_TIMESTAMP() WHERE request_id=?');
            $q->execute([$newStatus,$user['user_id'],$id]); $pdo->commit();
        } catch (OutOfBoundsException $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            respond(['success'=>false,'message'=>$e->getMessage()],404);
        } catch (DomainException $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            respond(['success'=>false,'message'=>$e->getMessage()],409);
        } catch (Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            throw $e;
        }
        respond(['success'=>true,'message'=>$newStatus==='approved'?'Rental request approved and added to bookings.':'Rental request updated.']);
    }
    respond(['success'=>false,'message'=>'Unsupported rental request endpoint or HTTP method.'],404);
}

// ---------------- AUTH / USER MANAGEMENT ----------------
if ($resource === 'auth') {
    $action = strtolower($_GET['action'] ?? '');
    if ($action === 'forgot-password' && $method === 'POST') {
        requireFields($input, ['email']);
        if (!is_string($input['email'])) respond(['success'=>false,'message'=>'Enter a valid email address.'],422);
        $email = strtolower(trim($input['email']));
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) respond(['success'=>false,'message'=>'Enter a valid email address.'],422);

        $q = $pdo->prepare("SELECT user_id,full_name,email FROM users WHERE email=? AND status='active' LIMIT 1");
        $q->execute([$email]);
        $user = $q->fetch();
        if ($user) {
            $pdo->exec('DELETE FROM user_password_resets WHERE expires_at <= UTC_TIMESTAMP()');
            $q = $pdo->prepare('SELECT created_at FROM user_password_resets WHERE user_id=? LIMIT 1');
            $q->execute([(int)$user['user_id']]);
            $existing = $q->fetch();
            $canSend = !$existing || strtotime($existing['created_at'].' UTC') <= time() - 60;

            if ($canSend) {
                $token = bin2hex(random_bytes(32));
                $tokenHash = hash('sha256', $token);
                $q = $pdo->prepare(
                    'INSERT INTO user_password_resets(user_id,token_hash,expires_at,created_at) VALUES(?,?,DATE_ADD(UTC_TIMESTAMP(), INTERVAL 1 HOUR),UTC_TIMESTAMP()) '.
                    'ON DUPLICATE KEY UPDATE token_hash=VALUES(token_hash),expires_at=VALUES(expires_at),created_at=UTC_TIMESTAMP()'
                );
                $q->execute([(int)$user['user_id'],$tokenHash]);

                $resetUrl = rtrim(APP_URL, '/').'/password_reset.html?reset_token='.rawurlencode($token);
                $subject = 'Reset your Croco Plant password';
                $message = "Hello {$user['full_name']},\n\n".
                    "Use the link below to reset your Croco Plant password. This link expires in one hour and can only be used once.\n\n".
                    "{$resetUrl}\n\n".
                    "If you did not request a password reset, you can ignore this email.";
                if (!mail($user['email'], $subject, $message, 'From: '.MAIL_FROM)) {
                    error_log('Password reset email could not be sent for user_id '.$user['user_id'].'. Check PHP mail configuration.');
                    $q = $pdo->prepare('DELETE FROM user_password_resets WHERE user_id=?');
                    $q->execute([(int)$user['user_id']]);
                }
            }
        }

        respond(['success'=>true,'message'=>'If an active account matches that email, a password reset link will be sent shortly.']);
    }
    if ($action === 'reset-password' && $method === 'POST') {
        requireFields($input, ['token','password']);
        if (!is_string($input['token']) || !preg_match('/\A[a-f0-9]{64}\z/', $input['token'])) {
            respond(['success'=>false,'message'=>'This password reset link is invalid or has expired.'],422);
        }
        if (!is_string($input['password']) || strlen($input['password']) < 12) {
            respond(['success'=>false,'message'=>'Password must contain at least 12 characters.'],422);
        }

        $pdo->beginTransaction();
        $q = $pdo->prepare(
            "SELECT r.user_id FROM user_password_resets r JOIN users u ON u.user_id=r.user_id ".
            "WHERE r.token_hash=? AND r.expires_at>UTC_TIMESTAMP() AND u.status='active' FOR UPDATE"
        );
        $q->execute([hash('sha256', $input['token'])]);
        $reset = $q->fetch();
        if (!$reset) {
            $pdo->rollBack();
            respond(['success'=>false,'message'=>'This password reset link is invalid or has expired.'],422);
        }

        $q = $pdo->prepare('UPDATE users SET password_hash=? WHERE user_id=?');
        $q->execute([password_hash($input['password'], PASSWORD_DEFAULT),(int)$reset['user_id']]);
        $q = $pdo->prepare('DELETE FROM user_password_resets WHERE user_id=?');
        $q->execute([(int)$reset['user_id']]);
        $pdo->commit();
        respond(['success'=>true,'message'=>'Your password has been reset. You can now sign in.']);
    }
    if ($action === 'login' && $method === 'POST') {
        requireFields($input, ['email','password']);
        $q=$pdo->prepare("SELECT u.user_id,u.role_id,u.full_name,u.email,u.password_hash,u.department,u.status,r.role_name,r.permissions FROM users u JOIN roles r ON r.role_id=u.role_id WHERE u.email=? LIMIT 1");
        $q->execute([strtolower(trim($input['email']))]); $u=$q->fetch();
        if (!$u || $u['status']!=='active' || !password_verify($input['password'],$u['password_hash'])) respond(['success'=>false,'message'=>'Invalid email or password.'],401);
        session_regenerate_id(true); $_SESSION['user_id']=(int)$u['user_id'];
        unset($u['password_hash']); $u['permissions']=json_decode($u['permissions'],true)?:[];
        respond(['success'=>true,'message'=>'Login successful.','user'=>$u]);
    }
    if ($action === 'logout' && $method === 'POST') {
        $_SESSION=[]; if (ini_get('session.use_cookies')) { $p=session_get_cookie_params(); setcookie(session_name(),'',time()-42000,$p['path'],$p['domain'],$p['secure'],$p['httponly']); }
        session_destroy(); respond(['success'=>true,'message'=>'Logged out.']);
    }
    if ($action === 'me' && $method === 'GET') { $u=needLogin(); unset($u['password_hash']); respond(['success'=>true,'user'=>$u]); }
    if ($action === 'users' && $method === 'GET') {
        needPermission('users','read');
        $rows=$pdo->query('SELECT u.user_id,u.full_name,u.email,u.department,u.status,u.created_at,r.role_name,r.role_id FROM users u JOIN roles r ON r.role_id=u.role_id ORDER BY u.user_id DESC')->fetchAll();
        respond(['success'=>true,'data'=>$rows]);
    }
    if ($action === 'users' && $method === 'POST') {
        needPermission('users','create'); requireFields($input,['full_name','email','password','role_id']);
        if (!filter_var($input['email'],FILTER_VALIDATE_EMAIL)) respond(['success'=>false,'message'=>'Enter a valid email address.'],422);
        if (strlen($input['password']) < 10) respond(['success'=>false,'message'=>'Password must contain at least 10 characters.'],422);
        if (!positiveInt($input['role_id'])) respond(['success'=>false,'message'=>'role_id must be a positive integer.'],422);
        $q=$pdo->prepare('INSERT INTO users(role_id,full_name,email,password_hash,department,status) VALUES(?,?,?,?,?,?)');
        $q->execute([(int)$input['role_id'],trim($input['full_name']),strtolower(trim($input['email'])),password_hash($input['password'],PASSWORD_DEFAULT),$input['department']??null,'active']);
        respond(['success'=>true,'message'=>'User account created.','user_id'=>(int)$pdo->lastInsertId()],201);
    }
    if ($action === 'users' && $method === 'PATCH' && $id>0) {
        needPermission('users','update'); requireFields($input,['status']);
        if (!in_array($input['status'],['active','inactive','suspended'],true)) respond(['success'=>false,'message'=>'Invalid user status.'],422);
        $q=$pdo->prepare('UPDATE users SET status=? WHERE user_id=?'); $q->execute([$input['status'],$id]);
        respond(['success'=>true,'message'=>'User status updated.']);
    }
    respond(['success'=>false,'message'=>'Unknown auth action or unsupported HTTP method.'],404);
}

// ---------------- ASSET MANAGEMENT ----------------
if ($resource === 'assets') {
    if ($method==='GET' && $id>0) {
        needPermission('assets','read'); $q=$pdo->prepare("SELECT a.*,c.category_name,c.rentable,c.mobile,l.name AS location_name,ll.latitude AS current_latitude,ll.longitude AS current_longitude,ll.recorded_at AS last_gps_ping,COALESCE(ll.source,'configured') AS gps_source,d.description,d.image_url,d.specifications,d.rental_terms,d.is_public FROM assets a JOIN asset_categories c ON c.category_id=a.category_id JOIN locations l ON l.location_id=a.location_id LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id LEFT JOIN location_log ll ON ll.log_id=(SELECT latest.log_id FROM location_log latest WHERE latest.asset_id=a.asset_id ORDER BY latest.recorded_at DESC,latest.log_id DESC LIMIT 1) WHERE a.asset_id=?"); $q->execute([$id]); $row=$q->fetch(); if(!$row) respond(['success'=>false,'message'=>'Asset not found.'],404); if($row['specifications']!==null)$row['specifications']=json_decode($row['specifications'],true)?:[]; respond(['success'=>true,'data'=>$row]);
    }
    if ($method==='GET') {
        needPermission('assets','read'); $where=[];$args=[];
        foreach (['status','category_id','location_id'] as $f) if(isset($_GET[$f]) && $_GET[$f]!=='') { $where[]="a.$f=?"; $args[]=$_GET[$f]; }
        if (!empty($_GET['search'])) { $where[]='(a.name LIKE ? OR a.asset_tag LIKE ?)'; $args[]='%'.$_GET['search'].'%';$args[]='%'.$_GET['search'].'%'; }
        $sql="SELECT a.*,c.category_name,c.rentable,l.name AS location_name,d.description,d.image_url,d.specifications,d.rental_terms,d.is_public,ll.latitude AS current_latitude,ll.longitude AS current_longitude,ll.recorded_at AS last_gps_ping,COALESCE(ll.source,'configured') AS gps_source FROM assets a JOIN asset_categories c ON c.category_id=a.category_id JOIN locations l ON l.location_id=a.location_id LEFT JOIN asset_catalogue_details d ON d.asset_id=a.asset_id LEFT JOIN location_log ll ON ll.log_id=(SELECT latest.log_id FROM location_log latest WHERE latest.asset_id=a.asset_id ORDER BY latest.recorded_at DESC,latest.log_id DESC LIMIT 1)".($where?' WHERE '.implode(' AND ',$where):'').' ORDER BY a.asset_id DESC';
        $q=$pdo->prepare($sql);$q->execute($args);respond(['success'=>true,'data'=>$q->fetchAll()]);
    }
    if ($method==='POST') {
        $u=needPermission('assets','create'); requireFields($input,['asset_tag','category_id','location_id','name']);
        if (!positiveInt($input['category_id'])||!positiveInt($input['location_id'])) respond(['success'=>false,'message'=>'category_id and location_id must be positive integers.'],422);
        $status=$input['status']??'available';$condition=$input['condition']??'good';
        if(!in_array($status,['available','rented','maintenance','retired','lost'],true)||!in_array($condition,['new','good','fair','poor','damaged'],true)) respond(['success'=>false,'message'=>'Invalid asset status or condition.'],422);
        $rate=(float)($input['daily_rate']??0);if($rate<0)respond(['success'=>false,'message'=>'daily_rate cannot be negative.'],422);
        $q=$pdo->prepare('INSERT INTO assets(asset_tag,category_id,location_id,name,status,`condition`,purchase_date,daily_rate) VALUES(?,?,?,?,?,?,?,?)');
        $q->execute([trim($input['asset_tag']),(int)$input['category_id'],(int)$input['location_id'],trim($input['name']),$status,$condition,$input['purchase_date']??null,$rate]);$newId=(int)$pdo->lastInsertId();history($newId,$u['user_id'],'registered','Asset created.');respond(['success'=>true,'message'=>'Asset created.','asset_id'=>$newId],201);
    }
    if (($method==='PUT'||$method==='PATCH')&&$id>0) {
        $u=needPermission('assets','update');$q=$pdo->prepare('SELECT * FROM assets WHERE asset_id=?');$q->execute([$id]);$old=$q->fetch();if(!$old)respond(['success'=>false,'message'=>'Asset not found.'],404);
        $allowed=['asset_tag','category_id','location_id','name','status','condition','purchase_date','daily_rate','latitude','longitude'];$sets=[];$args=[];
        foreach($allowed as $f) if(array_key_exists($f,$input)) { $col=$f==='condition'?'`condition`':$f;$sets[]="$col=?";$args[]=$input[$f]; }
        $catalogueFields=['description','image_url','specifications','rental_terms','is_public'];
        $catalogueUpdates=array_intersect_key($input,array_flip($catalogueFields));
        if(!$sets&&!$catalogueUpdates)respond(['success'=>false,'message'=>'No editable fields supplied.'],422);
        foreach (['description'=>2000,'image_url'=>500,'rental_terms'=>2000] as $field=>$maxLength) {
            if (array_key_exists($field,$catalogueUpdates) && $catalogueUpdates[$field]!==null && (!is_string($catalogueUpdates[$field])||strlen(trim($catalogueUpdates[$field]))>$maxLength)) respond(['success'=>false,'message'=>"{$field} must be text no longer than {$maxLength} characters."],422);
            if (isset($catalogueUpdates[$field])&&is_string($catalogueUpdates[$field])) $catalogueUpdates[$field]=trim($catalogueUpdates[$field]);
        }
        if (isset($catalogueUpdates['image_url'])&&$catalogueUpdates['image_url']!=='') {
            $imageUrl=$catalogueUpdates['image_url'];
            $isHttps=preg_match('/\Ahttps:\/\/[^\s]+\z/i',$imageUrl)===1;
            $isRelative=!str_starts_with($imageUrl,'/')&&!str_starts_with($imageUrl,'#')&&!str_starts_with($imageUrl,'?')&&!str_contains($imageUrl,'\\')&&!preg_match('/(?:^|\/)\.\.(?:\/|$)/',$imageUrl)&&!preg_match('/[\x00-\x1F]/',$imageUrl)&&!preg_match('/\A[a-z][a-z0-9+.-]*:/i',$imageUrl);
            if(!$isHttps&&!$isRelative)respond(['success'=>false,'message'=>'image_url must be a secure HTTPS URL or a project-relative image path.'],422);
        }
        if (isset($catalogueUpdates['is_public'])&&!is_bool($catalogueUpdates['is_public'])&&!in_array($catalogueUpdates['is_public'],[0,1],true)) respond(['success'=>false,'message'=>'is_public must be true or false.'],422);
        if (array_key_exists('specifications',$catalogueUpdates)&&$catalogueUpdates['specifications']!==null) {
            if (!is_array($catalogueUpdates['specifications'])||strlen(json_encode($catalogueUpdates['specifications']))>4000) respond(['success'=>false,'message'=>'specifications must be a JSON object or array of up to 4000 characters.'],422);
            $catalogueUpdates['specifications']=json_encode($catalogueUpdates['specifications'],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
        }
        if(isset($input['status'])&&!in_array($input['status'],['available','rented','maintenance','retired','lost'],true))respond(['success'=>false,'message'=>'Invalid asset status.'],422);
        if(isset($input['condition'])&&!in_array($input['condition'],['new','good','fair','poor','damaged'],true))respond(['success'=>false,'message'=>'Invalid condition.'],422);
        if(isset($input['daily_rate'])&&(float)$input['daily_rate']<0)respond(['success'=>false,'message'=>'daily_rate cannot be negative.'],422);
        $hasLatitude=array_key_exists('latitude',$input);$hasLongitude=array_key_exists('longitude',$input);
        if($hasLatitude!==$hasLongitude)respond(['success'=>false,'message'=>'Latitude and longitude must be provided together.'],422);
        if($hasLatitude) {
            if(!is_numeric($input['latitude'])||!is_numeric($input['longitude']))respond(['success'=>false,'message'=>'Latitude and longitude must be numeric.'],422);
            $latitude=(float)$input['latitude'];$longitude=(float)$input['longitude'];
            if($latitude < -90||$latitude > 90||$longitude < -180||$longitude > 180)respond(['success'=>false,'message'=>'Coordinates are outside the valid latitude/longitude ranges.'],422);
            $sets[]='last_gps_update=CURRENT_TIMESTAMP';
        }
        $args[]=$id;
        $pdo->beginTransaction();
        try {
            if($sets)$pdo->prepare('UPDATE assets SET '.implode(',',$sets).' WHERE asset_id=?')->execute($args);
            if($catalogueUpdates){
                $q=$pdo->prepare('SELECT description,image_url,specifications,rental_terms,is_public FROM asset_catalogue_details WHERE asset_id=? FOR UPDATE');
                $q->execute([$id]);$details=$q->fetch()?:['description'=>null,'image_url'=>null,'specifications'=>null,'rental_terms'=>null,'is_public'=>1];
                foreach($catalogueUpdates as $field=>$value)$details[$field]=$value;
                $q=$pdo->prepare('INSERT INTO asset_catalogue_details(asset_id,description,image_url,specifications,rental_terms,is_public) VALUES(?,?,?,?,?,?) ON DUPLICATE KEY UPDATE description=VALUES(description),image_url=VALUES(image_url),specifications=VALUES(specifications),rental_terms=VALUES(rental_terms),is_public=VALUES(is_public)');
                $q->execute([$id,$details['description'],$details['image_url'],$details['specifications'],$details['rental_terms'],$details['is_public']]);
            }
            if($hasLatitude) {
                $q=$pdo->prepare("INSERT INTO location_log(asset_id,latitude,longitude,source,recorded_by) VALUES(?,?,?,'manual',?)");
                $q->execute([$id,$latitude,$longitude,$u['user_id']]);
            }
            $select=$pdo->prepare('SELECT * FROM assets WHERE asset_id=?');
            $select->execute([$id]);$new=$select->fetch();
            history($id,$u['user_id'],$hasLatitude?'location_updated':'updated',$hasLatitude?'GPS coordinates updated manually.':'Asset updated.',$old,$new);
            $pdo->commit();
        } catch(Throwable $e) {
            if($pdo->inTransaction())$pdo->rollBack();
            throw $e;
        }
        respond(['success'=>true,'message'=>$hasLatitude?'Asset GPS position updated.':'Asset updated.','data'=>$new]);
    }
    if($method==='DELETE'&&$id>0) { $u=needPermission('assets','retire');$q=$pdo->prepare("UPDATE assets SET status='retired' WHERE asset_id=? AND status<>'retired'");$q->execute([$id]);if(!$q->rowCount())respond(['success'=>false,'message'=>'Asset not found or already retired.'],404);history($id,$u['user_id'],'retired','Asset archived/retired.');respond(['success'=>true,'message'=>'Asset retired; historical records were preserved.']); }
    respond(['success'=>false,'message'=>'Unsupported assets endpoint or HTTP method.'],404);
}

// ---------------- BOOKINGS ----------------
if ($resource === 'bookings') {
    if($method==='GET') { needPermission('bookings','read');$sql="SELECT b.*,a.asset_tag,a.name AS asset_name,COALESCE(u.full_name,c.name,'Internal') AS requester,ap.full_name AS approver FROM bookings b JOIN assets a ON a.asset_id=b.asset_id LEFT JOIN users u ON u.user_id=b.requested_by LEFT JOIN public_rental_request_items pri ON pri.request_item_id=b.public_request_item_id LEFT JOIN public_rental_requests pr ON pr.request_id=pri.request_id LEFT JOIN customers c ON c.customer_id=pr.customer_id LEFT JOIN users ap ON ap.user_id=b.approved_by";$where=[];$args=[];if($id>0){$where[]='b.booking_id=?';$args[]=$id;}elseif(!empty($_GET['status'])){$where[]='b.status=?';$args[]=$_GET['status'];}if($where)$sql.=' WHERE '.implode(' AND ',$where);$sql.=' ORDER BY b.created_at DESC';$q=$pdo->prepare($sql);$q->execute($args);$rows=$q->fetchAll();if($id>0&&!$rows)respond(['success'=>false,'message'=>'Booking not found.'],404);respond(['success'=>true,'data'=>$id>0?$rows[0]:$rows]); }
    if($method==='POST') { $u=needPermission('bookings','create');requireFields($input,['asset_id','start_time','end_time']);if(!positiveInt($input['asset_id']))respond(['success'=>false,'message'=>'asset_id must be positive.'],422);if(strtotime($input['end_time'])<=strtotime($input['start_time']))respond(['success'=>false,'message'=>'end_time must be after start_time.'],422);
        $pdo->beginTransaction();try{$q=$pdo->prepare('SELECT * FROM assets WHERE asset_id=? FOR UPDATE');$q->execute([(int)$input['asset_id']]);$a=$q->fetch();if(!$a||$a['status']!=='available')throw new DomainException('Asset does not exist or is not available.');
        $q=$pdo->prepare("SELECT COUNT(*) FROM bookings WHERE asset_id=? AND status='approved' AND start_time < ? AND end_time > ?");$q->execute([(int)$input['asset_id'],$input['end_time'],$input['start_time']]);if((int)$q->fetchColumn()>0)throw new DomainException('This asset already has an overlapping approved booking.');
        $q=$pdo->prepare("SELECT COUNT(*) FROM maintenance WHERE asset_id=? AND status IN ('scheduled','in_progress') AND scheduled_date <= DATE(?)");$q->execute([(int)$input['asset_id'],$input['end_time']]);if((int)$q->fetchColumn()>0)throw new DomainException('Asset has maintenance scheduled during or before this booking.');
        $q=$pdo->prepare("INSERT INTO bookings(asset_id,requested_by,start_time,end_time,purpose,status) VALUES(?,?,?,?,?,'pending')");$q->execute([(int)$input['asset_id'],$u['user_id'],$input['start_time'],$input['end_time'],$input['purpose']??null]);$bid=(int)$pdo->lastInsertId();$pdo->commit();respond(['success'=>true,'message'=>'Booking request created.','booking_id'=>$bid],201);
        }catch(DomainException $e){if($pdo->inTransaction())$pdo->rollBack();respond(['success'=>false,'message'=>$e->getMessage()],409);}catch(Throwable $e){if($pdo->inTransaction())$pdo->rollBack();throw $e;}}
    if($method==='PATCH'&&$id>0) { $u=needLogin();requireFields($input,['status']);$q=$pdo->prepare('SELECT * FROM bookings WHERE booking_id=?');$q->execute([$id]);$b=$q->fetch();if(!$b)respond(['success'=>false,'message'=>'Booking not found.'],404);$new=$input['status'];
        if(in_array($new,['approved','rejected'],true)){if(!can($u,'bookings','approve'))respond(['success'=>false,'message'=>'You cannot approve or reject bookings.'],403);if((int)$b['requested_by']===(int)$u['user_id'])respond(['success'=>false,'message'=>'Users cannot approve their own booking.'],403);if($b['status']!=='pending')respond(['success'=>false,'message'=>'Only pending bookings can be decided.'],409);
            if($new==='approved'){$q=$pdo->prepare("SELECT COUNT(*) FROM bookings WHERE asset_id=? AND booking_id<>? AND status='approved' AND start_time < ? AND end_time > ?");$q->execute([$b['asset_id'],$id,$b['end_time'],$b['start_time']]);if((int)$q->fetchColumn())respond(['success'=>false,'message'=>'An overlapping approved booking exists.'],409);$q=$pdo->prepare("SELECT COUNT(*) FROM maintenance WHERE asset_id=? AND status IN ('scheduled','in_progress') AND scheduled_date <= DATE(?)");$q->execute([$b['asset_id'],$b['end_time']]);if((int)$q->fetchColumn())respond(['success'=>false,'message'=>'Asset maintenance conflicts with this booking.'],409);}
            $q=$pdo->prepare('UPDATE bookings SET status=?,approved_by=?,decided_at=NOW() WHERE booking_id=?');$q->execute([$new,$u['user_id'],$id]);respond(['success'=>true,'message'=>'Booking '.$new.'.']);}
        if($new==='cancelled'){if(!can($u,'bookings','cancel'))respond(['success'=>false,'message'=>'You cannot cancel bookings.'],403);if(!in_array($b['status'],['pending','approved'],true))respond(['success'=>false,'message'=>'This booking cannot be cancelled.'],409);$q=$pdo->prepare("UPDATE bookings SET status='cancelled' WHERE booking_id=?");$q->execute([$id]);respond(['success'=>true,'message'=>'Booking cancelled.']);}
        if($new==='fulfilled'){if(!can($u,'bookings','approve'))respond(['success'=>false,'message'=>'Permission denied.'],403);if($b['status']!=='approved')respond(['success'=>false,'message'=>'Only approved bookings can be fulfilled.'],409);$pdo->prepare("UPDATE bookings SET status='fulfilled' WHERE booking_id=?")->execute([$id]);respond(['success'=>true,'message'=>'Booking marked fulfilled.']);}
        respond(['success'=>false,'message'=>'Invalid booking status transition.'],422);}
    respond(['success'=>false,'message'=>'Unsupported bookings endpoint or HTTP method.'],404);
}

// ---------------- CUSTOMERS + RENTALS ----------------
if ($resource === 'customers') {
    if($method==='GET'){needPermission('customers','read');$q=$pdo->query('SELECT * FROM customers WHERE is_active=1 ORDER BY customer_id DESC');respond(['success'=>true,'data'=>$q->fetchAll()]);}
    if($method==='POST'){needPermission('customers','create');requireFields($input,['name']);if(empty($input['phone'])&&empty($input['email']))respond(['success'=>false,'message'=>'Provide a phone number or email.'],422);if(!empty($input['email'])&&!filter_var($input['email'],FILTER_VALIDATE_EMAIL))respond(['success'=>false,'message'=>'Invalid email address.'],422);$q=$pdo->prepare('INSERT INTO customers(name,phone,email,id_number) VALUES(?,?,?,?)');$q->execute([trim($input['name']),$input['phone']??null,isset($input['email'])?strtolower(trim($input['email'])):null,$input['id_number']??null]);respond(['success'=>true,'message'=>'Customer created.','customer_id'=>(int)$pdo->lastInsertId()],201);}
    if($method==='PATCH'&&$id>0){needPermission('customers','update');$fields=['name','phone','email','is_active'];$sets=[];$args=[];foreach($fields as $f)if(array_key_exists($f,$input)){$sets[]="$f=?";$args[]=$input[$f];}if(!$sets)respond(['success'=>false,'message'=>'No editable fields.'],422);$args[]=$id;$q=$pdo->prepare('UPDATE customers SET '.implode(',',$sets).' WHERE customer_id=?');$q->execute($args);respond(['success'=>true,'message'=>'Customer updated.']);}
    respond(['success'=>false,'message'=>'Unsupported customers endpoint.'],404);
}
if ($resource === 'rentals') {
    if($method==='GET'){needPermission('rentals','read');$sql='SELECT r.*,c.name AS customer_name,c.phone,c.email,a.asset_tag,a.name AS asset_name,u.full_name AS handled_by_name,COALESCE(p.paid_total,0) AS paid_total,(r.total_charge-COALESCE(p.paid_total,0)) AS balance_due FROM rentals r JOIN customers c ON c.customer_id=r.customer_id JOIN assets a ON a.asset_id=r.asset_id JOIN users u ON u.user_id=r.handled_by LEFT JOIN (SELECT rental_id,SUM(CASE WHEN txn_type="payment" THEN amount WHEN txn_type="refund" THEN -amount ELSE 0 END) paid_total FROM payments WHERE status="completed" GROUP BY rental_id) p ON p.rental_id=r.rental_id';$args=[];if($id>0){$sql.=' WHERE r.rental_id=?';$args[]=$id;}elseif(!empty($_GET['status'])){$sql.=' WHERE r.status=?';$args[]=$_GET['status'];}$sql.=' ORDER BY r.created_at DESC';$q=$pdo->prepare($sql);$q->execute($args);$rows=$q->fetchAll();if($id>0&&!$rows)respond(['success'=>false,'message'=>'Rental not found.'],404);respond(['success'=>true,'data'=>$id>0?$rows[0]:$rows]);}
    if($method==='POST'){ $u=needPermission('rentals','create');requireFields($input,['asset_id','customer_id','start_date','end_date']);if(!positiveInt($input['asset_id'])||!positiveInt($input['customer_id']))respond(['success'=>false,'message'=>'asset_id and customer_id must be positive integers.'],422);$s=strtotime($input['start_date']);$e=strtotime($input['end_date']);if(!$s||!$e||$e<$s)respond(['success'=>false,'message'=>'Invalid rental dates.'],422);$days=(int)((strtotime(date('Y-m-d',$e))-strtotime(date('Y-m-d',$s)))/86400)+1;
        $pdo->beginTransaction();try{$q=$pdo->prepare('SELECT a.*,c.rentable FROM assets a JOIN asset_categories c ON c.category_id=a.category_id WHERE a.asset_id=? FOR UPDATE');$q->execute([(int)$input['asset_id']]);$a=$q->fetch();if(!$a||!$a['rentable']||!in_array($a['status'],['available'],true))throw new DomainException('Asset does not exist, is not rentable, or is not available.');$q=$pdo->prepare("SELECT COUNT(*) FROM rentals WHERE asset_id=? AND status IN ('reserved','active') AND start_date<=? AND end_date>=?");$q->execute([(int)$input['asset_id'],$input['end_date'],$input['start_date']]);if((int)$q->fetchColumn())throw new DomainException('Rental dates overlap an existing reserved or active rental.');$q=$pdo->prepare("SELECT COUNT(*) FROM maintenance WHERE asset_id=? AND status IN ('scheduled','in_progress') AND scheduled_date BETWEEN ? AND ?");$q->execute([(int)$input['asset_id'],$input['start_date'],$input['end_date']]);if((int)$q->fetchColumn())throw new DomainException('Asset has maintenance during the requested rental.');$charge=isset($input['total_charge'])?(float)$input['total_charge']:((float)$a['daily_rate']*$days);if($charge<0)throw new DomainException('total_charge cannot be negative.');$deposit=(float)($input['deposit']??0);if($deposit<0)throw new DomainException('deposit cannot be negative.');$ref=$input['contract_ref']??null;$q=$pdo->prepare("INSERT INTO rentals(asset_id,customer_id,handled_by,start_date,end_date,total_charge,deposit,contract_ref,status) VALUES(?,?,?,?,?,?,?,?, 'reserved')");$q->execute([(int)$input['asset_id'],(int)$input['customer_id'],$u['user_id'],$input['start_date'],$input['end_date'],$charge,$deposit,$ref]);$rid=(int)$pdo->lastInsertId();$pdo->commit();respond(['success'=>true,'message'=>'Rental created.','rental_id'=>$rid,'days'=>$days,'total_charge'=>$charge,'deposit'=>$deposit],201);}catch(DomainException $e){if($pdo->inTransaction())$pdo->rollBack();respond(['success'=>false,'message'=>$e->getMessage()],409);}catch(Throwable $e){if($pdo->inTransaction())$pdo->rollBack();throw $e;}}
    if($method==='PATCH'&&$id>0){needPermission('rentals','update');requireFields($input,['status']);$allowed=['pending','reserved','active','completed','cancelled'];if(!in_array($input['status'],$allowed,true))respond(['success'=>false,'message'=>'Invalid rental status.'],422);$q=$pdo->prepare('SELECT * FROM rentals WHERE rental_id=?');$q->execute([$id]);$r=$q->fetch();if(!$r)respond(['success'=>false,'message'=>'Rental not found.'],404);
        if($input['status']==='active'){
            $q=$pdo->prepare("SELECT COUNT(*) FROM assets WHERE asset_id=? AND status IN ('maintenance','retired','lost')");
            $q->execute([$r['asset_id']]);
            if((int)$q->fetchColumn())respond(['success'=>false,'message'=>'Asset is unavailable for rental.'],409);
        }
        $pdo->prepare('UPDATE rentals SET status=? WHERE rental_id=?')->execute([$input['status'],$id]);respond(['success'=>true,'message'=>'Rental status updated.']);}
    respond(['success'=>false,'message'=>'Unsupported rentals endpoint.'],404);
}

// ---------------- PAYMENTS ----------------
if($resource==='payments'){
    if($method==='GET'){needPermission('payments','read');$sql='SELECT p.*,r.contract_ref,c.name AS customer_name FROM payments p JOIN rentals r ON r.rental_id=p.rental_id JOIN customers c ON c.customer_id=r.customer_id';$args=[];if($id>0){$sql.=' WHERE p.payment_id=?';$args[]=$id;}elseif(!empty($_GET['rental_id'])){$sql.=' WHERE p.rental_id=?';$args[]=(int)$_GET['rental_id'];}$sql.=' ORDER BY p.paid_on DESC,p.payment_id DESC';$q=$pdo->prepare($sql);$q->execute($args);respond(['success'=>true,'data'=>$q->fetchAll()]);}
    if($method==='POST'){ $u=needPermission('payments','create');requireFields($input,['rental_id','amount','paid_on','method']);if(!positiveInt($input['rental_id'])||(float)$input['amount']<=0)respond(['success'=>false,'message'=>'rental_id must be positive and amount must be greater than zero.'],422);if(!in_array($input['method'],['cash','card','bank_transfer','mobile_money','cheque','other'],true))respond(['success'=>false,'message'=>'Invalid payment method.'],422);$type=$input['txn_type']??'payment';if(!in_array($type,['payment','refund','deposit','deposit_refund'],true))respond(['success'=>false,'message'=>'Invalid transaction type.'],422);$status=$input['status']??'completed';if(!in_array($status,['completed','pending','failed','reversed'],true))respond(['success'=>false,'message'=>'Invalid payment status.'],422);if(in_array($type,['refund','deposit_refund'],true)&&!can($u,'payments','refund'))respond(['success'=>false,'message'=>'Refund permission required.'],403);$q=$pdo->prepare('INSERT INTO payments(rental_id,amount,paid_on,method,txn_type,status,recorded_by,reference_no,related_payment_id) VALUES(?,?,?,?,?,?,?,?,?)');$q->execute([(int)$input['rental_id'],(float)$input['amount'],$input['paid_on'],$input['method'],$type,$status,$u['user_id'],$input['reference_no']??null,$input['related_payment_id']??null]);respond(['success'=>true,'message'=>'Payment transaction recorded.','payment_id'=>(int)$pdo->lastInsertId()],201);}
    respond(['success'=>false,'message'=>'Unsupported payments endpoint.'],404);
}

// ---------------- MAINTENANCE ----------------
if($resource==='maintenance'){
    if($method==='GET'){needPermission('maintenance','read');$sql='SELECT m.*,a.asset_tag,a.name AS asset_name,u.full_name AS technician FROM maintenance m JOIN assets a ON a.asset_id=m.asset_id JOIN users u ON u.user_id=m.performed_by';$args=[];if($id>0){$sql.=' WHERE m.maintenance_id=?';$args[]=$id;}elseif(!empty($_GET['status'])){$sql.=' WHERE m.status=?';$args[]=$_GET['status'];} $sql.=' ORDER BY m.scheduled_date DESC';$q=$pdo->prepare($sql);$q->execute($args);respond(['success'=>true,'data'=>$q->fetchAll()]);}
    if($method==='POST'){$u=needPermission('maintenance','create');requireFields($input,['asset_id','type','scheduled_date']);$tech=(int)($input['performed_by']??$u['user_id']);if(!positiveInt($input['asset_id'])||!in_array($input['type'],['preventive','repair','inspection','servicing'],true))respond(['success'=>false,'message'=>'Invalid asset_id or maintenance type.'],422);$cost=(float)($input['cost']??0);if($cost<0)respond(['success'=>false,'message'=>'Cost cannot be negative.'],422);$pdo->beginTransaction();try{$q=$pdo->prepare('SELECT asset_id,status FROM assets WHERE asset_id=? FOR UPDATE');$q->execute([(int)$input['asset_id']]);$a=$q->fetch();if(!$a)throw new DomainException('Asset not found.');$q=$pdo->prepare("INSERT INTO maintenance(asset_id,performed_by,type,scheduled_date,cost,status,notes) VALUES(?,?,?,?,?,'scheduled',?)");$q->execute([(int)$input['asset_id'],$tech,$input['type'],$input['scheduled_date'],$cost,$input['notes']??null]);$mid=(int)$pdo->lastInsertId();$pdo->prepare("UPDATE assets SET status='maintenance' WHERE asset_id=? AND status<>'retired'")->execute([(int)$input['asset_id']]);history((int)$input['asset_id'],$u['user_id'],'maintenance_started','Maintenance scheduled.');$pdo->commit();respond(['success'=>true,'message'=>'Maintenance record created.','maintenance_id'=>$mid],201);}catch(DomainException $e){if($pdo->inTransaction())$pdo->rollBack();respond(['success'=>false,'message'=>$e->getMessage()],404);}catch(Throwable $e){if($pdo->inTransaction())$pdo->rollBack();throw $e;}}
    if($method==='PATCH'&&$id>0){$u=needPermission('maintenance','update');requireFields($input,['status']);$allowed=['scheduled','in_progress','completed','cancelled'];if(!in_array($input['status'],$allowed,true))respond(['success'=>false,'message'=>'Invalid maintenance status.'],422);$q=$pdo->prepare('SELECT * FROM maintenance WHERE maintenance_id=?');$q->execute([$id]);$m=$q->fetch();if(!$m)respond(['success'=>false,'message'=>'Maintenance record not found.'],404);if($input['status']==='completed'){$q=$pdo->prepare("UPDATE maintenance SET status='completed',completed_date=CURDATE(),completed_by=?,notes=COALESCE(?,notes),cost=COALESCE(?,cost) WHERE maintenance_id=?");$q->execute([$u['user_id'],$input['notes']??null,$input['cost']??null,$id]);}else{$q=$pdo->prepare('UPDATE maintenance SET status=?,notes=COALESCE(?,notes),cost=COALESCE(?,cost) WHERE maintenance_id=?');$q->execute([$input['status'],$input['notes']??null,$input['cost']??null,$id]);}
        $q=$pdo->prepare("SELECT COUNT(*) FROM maintenance WHERE asset_id=? AND status IN ('scheduled','in_progress')");$q->execute([$m['asset_id']]);$open=(int)$q->fetchColumn();if($open===0){$q=$pdo->prepare("UPDATE assets SET status='available' WHERE asset_id=? AND status='maintenance'");$q->execute([$m['asset_id']]);history((int)$m['asset_id'],$u['user_id'],'maintenance_completed','Maintenance completed; asset set available.');}respond(['success'=>true,'message'=>'Maintenance status updated.']);}
    respond(['success'=>false,'message'=>'Unsupported maintenance endpoint.'],404);
}

// ---------------- CHECK-IN / CHECK-OUT ----------------
if($resource==='checkout'){
    if($method==='GET'){needPermission('assets','read');$sql='SELECT co.*,a.asset_tag,a.name AS asset_name,u.full_name AS released_by_name,ru.full_name AS received_by_name FROM checkout co JOIN assets a ON a.asset_id=co.asset_id JOIN users u ON u.user_id=co.released_by LEFT JOIN users ru ON ru.user_id=co.received_by';$args=[];if($id>0){$sql.=' WHERE co.checkout_id=?';$args[]=$id;}elseif(isset($_GET['open'])&&$_GET['open']==='1')$sql.=' WHERE co.in_time IS NULL';$sql.=' ORDER BY co.out_time DESC';$q=$pdo->prepare($sql);$q->execute($args);respond(['success'=>true,'data'=>$q->fetchAll()]);}
    if($method==='POST'){$u=needPermission('assets','update');requireFields($input,['asset_id','condition_out']);if(!positiveInt($input['asset_id'])||!in_array($input['condition_out'],['new','good','fair','poor','damaged'],true))respond(['success'=>false,'message'=>'Invalid asset or condition.'],422);if(empty($input['booking_id'])&&empty($input['rental_id']))respond(['success'=>false,'message'=>'booking_id or rental_id is required.'],422);$asset=(int)$input['asset_id'];$pdo->beginTransaction();try{$q=$pdo->prepare("SELECT * FROM assets WHERE asset_id=? FOR UPDATE");$q->execute([$asset]);$a=$q->fetch();if(!$a||$a['status']!=='available')throw new DomainException('Asset is not available to check out.');$booking=empty($input['booking_id'])?null:(int)$input['booking_id'];$rental=empty($input['rental_id'])?null:(int)$input['rental_id'];if($booking){$q=$pdo->prepare("SELECT COUNT(*) FROM bookings WHERE booking_id=? AND asset_id=? AND status='approved'");$q->execute([$booking,$asset]);if(!(int)$q->fetchColumn())throw new DomainException('Booking must be approved and match this asset.');}if($rental){$q=$pdo->prepare("SELECT COUNT(*) FROM rentals WHERE rental_id=? AND asset_id=? AND status='reserved'");$q->execute([$rental,$asset]);if(!(int)$q->fetchColumn())throw new DomainException('Rental must be reserved and match this asset.');}$q=$pdo->prepare('INSERT INTO checkout(asset_id,booking_id,rental_id,out_time,condition_out,released_by,notes) VALUES(?,?,?,?,?,?,?)');$q->execute([$asset,$booking,$rental,date('Y-m-d H:i:s'),$input['condition_out'],$u['user_id'],$input['notes']??null]);if($booking)$pdo->prepare("UPDATE bookings SET status='fulfilled' WHERE booking_id=?")->execute([$booking]);if($rental)$pdo->prepare("UPDATE rentals SET status='active' WHERE rental_id=?")->execute([$rental]);$pdo->prepare("UPDATE assets SET status='rented' WHERE asset_id=?")->execute([$asset]);history($asset,$u['user_id'],'checked_out','Asset checked out.');$checkoutId=(int)$pdo->lastInsertId();$pdo->commit();respond(['success'=>true,'message'=>'Asset checked out.','checkout_id'=>$checkoutId],201);}catch(DomainException $e){if($pdo->inTransaction())$pdo->rollBack();respond(['success'=>false,'message'=>$e->getMessage()],409);}catch(Throwable $e){if($pdo->inTransaction())$pdo->rollBack();throw $e;}}
    if($method==='PATCH'&&$id>0){$u=needPermission('assets','update');requireFields($input,['condition_in']);if(!in_array($input['condition_in'],['new','good','fair','poor','damaged'],true))respond(['success'=>false,'message'=>'Invalid return condition.'],422);$pdo->beginTransaction();try{$q=$pdo->prepare('SELECT * FROM checkout WHERE checkout_id=? FOR UPDATE');$q->execute([$id]);$c=$q->fetch();if(!$c||$c['in_time']!==null)throw new DomainException('Checkout record not found or already returned.');$q=$pdo->prepare('UPDATE checkout SET in_time=NOW(),condition_in=?,received_by=?,notes=COALESCE(?,notes) WHERE checkout_id=?');$q->execute([$input['condition_in'],$u['user_id'],$input['notes']??null,$id]);$status=$input['condition_in']==='damaged'?'maintenance':'available';$pdo->prepare('UPDATE assets SET status=?,`condition`=? WHERE asset_id=?')->execute([$status,$input['condition_in'],$c['asset_id']]);if($c['rental_id'])$pdo->prepare("UPDATE rentals SET status='completed' WHERE rental_id=?")->execute([$c['rental_id']]);history((int)$c['asset_id'],$u['user_id'],'returned','Asset returned.');$pdo->commit();respond(['success'=>true,'message'=>'Asset returned and recorded.']);}catch(DomainException $e){if($pdo->inTransaction())$pdo->rollBack();respond(['success'=>false,'message'=>$e->getMessage()],409);}catch(Throwable $e){if($pdo->inTransaction())$pdo->rollBack();throw $e;}}
    respond(['success'=>false,'message'=>'Unsupported checkout endpoint.'],404);
}

// ---------------- DASHBOARD / REPORTS ----------------
if($resource==='dashboard'){
    $user=needLogin();
    $canReadAssets=can($user,'assets','read');
    $canReadBookings=can($user,'bookings','read');
    $canReadRentals=can($user,'rentals','read');
    $canReadMaintenance=can($user,'maintenance','read');
    $canReadPayments=can($user,'payments','read');
    $data=[];
    $visible=[];
    if($canReadAssets){
        $data['assets']=$pdo->query("SELECT COUNT(*) total, SUM(status='available') available, SUM(status='rented') rented, SUM(status='maintenance') maintenance, SUM(status='retired') retired, SUM(status='lost') lost FROM assets")->fetch();
        $visible[]='assets';
    }
    if($canReadBookings){
        $data['bookings']=$pdo->query("SELECT COUNT(*) total, SUM(status='pending') pending, SUM(status='approved') approved, SUM(status='rejected') rejected, SUM(status='cancelled') cancelled, SUM(status='fulfilled') fulfilled FROM bookings")->fetch();
        $data['recent_bookings']=$pdo->query('SELECT b.booking_id,b.start_time,b.end_time,b.status,a.name AS asset_name,u.full_name AS requester FROM bookings b JOIN assets a ON a.asset_id=b.asset_id JOIN users u ON u.user_id=b.requested_by ORDER BY b.created_at DESC LIMIT 5')->fetchAll();
        $visible[]='bookings';
    }
    if($canReadRentals){
        $data['rentals']=$pdo->query("SELECT COUNT(*) total, SUM(status='reserved') reserved, SUM(status='active') active, SUM(status='completed') completed, SUM(status='cancelled') cancelled, SUM(status='active' AND end_date<CURDATE()) overdue FROM rentals")->fetch();
        $data['recent_rentals']=$pdo->query('SELECT r.rental_id,r.contract_ref,r.start_date,r.end_date,r.total_charge,r.status,c.name AS customer_name,a.name AS asset_name FROM rentals r JOIN customers c ON c.customer_id=r.customer_id JOIN assets a ON a.asset_id=r.asset_id ORDER BY r.created_at DESC LIMIT 5')->fetchAll();
        $visible[]='rentals';
    }
    if($canReadMaintenance){
        $data['maintenance']=$pdo->query("SELECT COUNT(*) total, SUM(status='scheduled') scheduled, SUM(status='in_progress') in_progress, SUM(status='completed') completed, SUM(status='cancelled') cancelled, COALESCE(SUM(CASE WHEN status IN ('scheduled','in_progress') THEN cost ELSE 0 END),0) open_cost FROM maintenance")->fetch();
        $visible[]='maintenance';
    }
    if($canReadPayments){
        $data['payments']=$pdo->query("SELECT COALESCE(SUM(CASE WHEN txn_type='payment' AND status='completed' THEN amount WHEN txn_type='refund' AND status='completed' THEN -amount ELSE 0 END),0) received FROM payments")->fetch();
        $visible[]='payments';
    }
    $activityQueries=[];
    if($canReadBookings)$activityQueries[]="SELECT DATE(created_at) AS activity_date, COUNT(*) AS bookings, 0 AS rentals FROM bookings WHERE created_at >= DATE_SUB(CURDATE(), INTERVAL 6 DAY) GROUP BY DATE(created_at)";
    if($canReadRentals)$activityQueries[]="SELECT DATE(created_at) AS activity_date, 0 AS bookings, COUNT(*) AS rentals FROM rentals WHERE created_at >= DATE_SUB(CURDATE(), INTERVAL 6 DAY) GROUP BY DATE(created_at)";
    if($activityQueries){
        $data['weekly_activity']=$pdo->query(
            'SELECT activity_date, SUM(bookings) AS bookings, SUM(rentals) AS rentals FROM ('.
            implode(' UNION ALL ',$activityQueries).
            ') AS activity GROUP BY activity_date ORDER BY activity_date'
        )->fetchAll();
    }
    $data['visible']=$visible;
    respond(['success'=>true,'data'=>$data]);
}

respond(['success'=>false,'message'=>'Unknown API resource or route.'],404);