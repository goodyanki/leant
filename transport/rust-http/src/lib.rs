use std::net::SocketAddr;
use std::os::raw::{c_char, c_void};
use std::slice;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Body;
use hyper::header::{HeaderName, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::net::TcpListener;
use tokio::sync::{Notify, Semaphore};

/// Opaque wrapper around Lean handler closure pointer (marked MT via lean_mark_mt).
#[derive(Clone, Copy)]
struct HandlerCtx(*mut c_void);
unsafe impl Send for HandlerCtx {}
unsafe impl Sync for HandlerCtx {}

#[repr(C)]
struct LeanRawResponse {
    status: u16,
    headers_ptr: *const u8,
    headers_len: usize,
    body_ptr: *const u8,
    body_len: usize,
    lean_obj: *mut c_void,
}

extern "C" {
    fn leant_bridge_thread_init();
    fn leant_bridge_thread_finalize();
    fn leant_bridge_handle(
        handler_ctx: *mut c_void,
        method_ptr: *const u8,
        method_len: usize,
        path_ptr: *const u8,
        path_len: usize,
        query_ptr: *const u8,
        query_len: usize,
        headers_ptr: *const u8,
        headers_len: usize,
        body_ptr: *const u8,
        body_len: usize,
        out: *mut LeanRawResponse,
    );
    fn leant_bridge_free_response(lean_obj: *mut c_void);
}

fn dispatch_to_lean(
    ctx: HandlerCtx,
    method: &[u8],
    path: &[u8],
    query: &[u8],
    headers_buf: &[u8],
    body_bytes: &[u8],
) -> Response<Full<Bytes>> {
    let mut resp = LeanRawResponse {
        status: 500,
        headers_ptr: std::ptr::null(),
        headers_len: 0,
        body_ptr: std::ptr::null(),
        body_len: 0,
        lean_obj: std::ptr::null_mut(),
    };

    unsafe {
        leant_bridge_handle(
            ctx.0,
            method.as_ptr(),
            method.len(),
            path.as_ptr(),
            path.len(),
            query.as_ptr(),
            query.len(),
            headers_buf.as_ptr(),
            headers_buf.len(),
            body_bytes.as_ptr(),
            body_bytes.len(),
            &mut resp as *mut LeanRawResponse,
        );
    }

    let (status, raw_headers, resp_body) = unsafe {
        let hdrs = if !resp.headers_ptr.is_null() && resp.headers_len > 0 {
            slice::from_raw_parts(resp.headers_ptr, resp.headers_len).to_vec()
        } else {
            Vec::new()
        };
        let body = if !resp.body_ptr.is_null() && resp.body_len > 0 {
            Bytes::copy_from_slice(slice::from_raw_parts(resp.body_ptr, resp.body_len))
        } else {
            Bytes::new()
        };
        if !resp.lean_obj.is_null() {
            leant_bridge_free_response(resp.lean_obj);
        }
        (resp.status, hdrs, body)
    };

    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = Response::builder().status(status_code);

    if let Ok(hdr_str) = std::str::from_utf8(&raw_headers) {
        for line in hdr_str.lines() {
            if let Some((k, v)) = line.split_once(':') {
                let k = k.trim();
                let v = v.trim();
                if let (Ok(hn), Ok(hv)) =
                    (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v))
                {
                    builder = builder.header(hn, hv);
                }
            }
        }
    }

    builder.body(Full::new(resp_body)).unwrap()
}

async fn handle_req_inner(
    ctx: HandlerCtx,
    max_body_bytes: usize,
    req: Request<hyper::body::Incoming>,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    // Hot path: if request has no body (e.g. GET /plaintext, GET /json),
    // skip body collection and method/path/query heap copies completely.
    if req.body().is_end_stream() {
        let method = req.method().as_str().as_bytes();
        let path = req.uri().path().as_bytes();
        let query = req.uri().query().unwrap_or("").as_bytes();

        let mut headers_buf = Vec::new();
        if !req.headers().is_empty() {
            headers_buf.reserve(req.headers().len() * 32);
            for (name, value) in req.headers().iter() {
                if let Ok(v) = value.to_str() {
                    headers_buf.extend_from_slice(name.as_str().as_bytes());
                    headers_buf.extend_from_slice(b": ");
                    headers_buf.extend_from_slice(v.as_bytes());
                    headers_buf.push(b'\n');
                }
            }
        }

        return Ok(dispatch_to_lean(ctx, method, path, query, &headers_buf, &[]));
    }

    let method = req.method().as_str().as_bytes().to_vec();
    let path = req.uri().path().as_bytes().to_vec();
    let query = req.uri().query().unwrap_or("").as_bytes().to_vec();

    let mut headers_buf = Vec::with_capacity(req.headers().len() * 32);
    for (name, value) in req.headers().iter() {
        if let Ok(v) = value.to_str() {
            headers_buf.extend_from_slice(name.as_str().as_bytes());
            headers_buf.extend_from_slice(b": ");
            headers_buf.extend_from_slice(v.as_bytes());
            headers_buf.push(b'\n');
        }
    }

    let body_bytes = match req.into_body().collect().await {
        Ok(collected) => {
            let b = collected.to_bytes();
            if max_body_bytes > 0 && b.len() > max_body_bytes {
                return Ok(Response::builder()
                    .status(StatusCode::PAYLOAD_TOO_LARGE)
                    .body(Full::new(Bytes::from_static(b"Payload Too Large")))
                    .unwrap());
            }
            b
        }
        Err(_) => Bytes::new(),
    };

    Ok(dispatch_to_lean(
        ctx,
        &method,
        &path,
        &query,
        &headers_buf,
        &body_bytes,
    ))
}

async fn handle_req(
    ctx: HandlerCtx,
    max_body_bytes: usize,
    request_timeout_ms: u32,
    req: Request<hyper::body::Incoming>,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    if request_timeout_ms > 0 {
        match tokio::time::timeout(
            Duration::from_millis(request_timeout_ms as u64),
            handle_req_inner(ctx, max_body_bytes, req),
        )
        .await
        {
            Ok(res) => res,
            Err(_) => Ok(Response::builder()
                .status(StatusCode::REQUEST_TIMEOUT)
                .header(hyper::header::CONTENT_TYPE, "application/json; charset=utf-8")
                .body(Full::new(Bytes::from_static(
                    b"{\"error\":\"Request Timeout\"}",
                )))
                .unwrap()),
        }
    } else {
        handle_req_inner(ctx, max_body_bytes, req).await
    }
}

async fn wait_for_shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm = signal(SignalKind::terminate()).expect("failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = sigterm.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// Starts the Tokio + Hyper HTTP/1.1 server with header/request timeouts,
/// connection cap, and graceful drain on SIGINT/SIGTERM.
#[no_mangle]
pub extern "C" fn leant_rust_serve(
    host_ptr: *const c_char,
    port: u16,
    max_connections: u32,
    max_body_bytes: usize,
    keep_alive: u8,
    header_timeout_ms: u32,
    request_timeout_ms: u32,
    shutdown_timeout_ms: u32,
    handler_ctx: *mut c_void,
) -> i32 {
    let host = if host_ptr.is_null() {
        "127.0.0.1"
    } else {
        unsafe {
            std::ffi::CStr::from_ptr(host_ptr)
                .to_str()
                .unwrap_or("127.0.0.1")
        }
    };
    let addr: SocketAddr = match format!("{}:{}", host, port).parse() {
        Ok(a) => a,
        Err(_) => return -1,
    };

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_start(|| unsafe {
            leant_bridge_thread_init();
        })
        .on_thread_stop(|| unsafe {
            leant_bridge_thread_finalize();
        })
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return -2,
    };

    let ctx = HandlerCtx(handler_ctx);
    let enable_keep_alive = keep_alive != 0;

    let result = rt.block_on(async move {
        let listener = match TcpListener::bind(addr).await {
            Ok(l) => l,
            Err(_) => return -3,
        };

        let conn_sem = if max_connections > 0 {
            Some(Arc::new(Semaphore::new(max_connections as usize)))
        } else {
            None
        };

        let active_conns = Arc::new(AtomicUsize::new(0));
        let drain_notify = Arc::new(Notify::new());

        let shutdown = wait_for_shutdown_signal();
        tokio::pin!(shutdown);

        loop {
            tokio::select! {
                _ = &mut shutdown => {
                    break;
                }
                accept_res = listener.accept() => {
                    let (stream, _) = match accept_res {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let _ = stream.set_nodelay(true);
                    let permit = match &conn_sem {
                        Some(sem) => match sem.clone().try_acquire_owned() {
                            Ok(p) => Some(p),
                            Err(_) => continue,
                        },
                        None => None,
                    };
                    let io = TokioIo::new(stream);
                    let active = active_conns.clone();
                    let notify = drain_notify.clone();
                    active.fetch_add(1, Ordering::AcqRel);

                    tokio::spawn(async move {
                        let _permit = permit;
                        let svc = service_fn(move |req| {
                            handle_req(ctx, max_body_bytes, request_timeout_ms, req)
                        });
                        let mut h1 = http1::Builder::new();
                        h1.keep_alive(enable_keep_alive);
                        if header_timeout_ms > 0 {
                            h1.timer(TokioTimer::new())
                              .header_read_timeout(Duration::from_millis(header_timeout_ms as u64));
                        }
                        let _ = h1.serve_connection(io, svc).await;
                        if active.fetch_sub(1, Ordering::AcqRel) == 1 {
                            notify.notify_waiters();
                        }
                    });
                }
            }
        }

        // Graceful drain: wait up to shutdown_timeout_ms for in-flight connections to finish.
        if active_conns.load(Ordering::Acquire) > 0 && shutdown_timeout_ms > 0 {
            let _ = tokio::time::timeout(
                Duration::from_millis(shutdown_timeout_ms as u64),
                async {
                    while active_conns.load(Ordering::Acquire) > 0 {
                        drain_notify.notified().await;
                    }
                },
            )
            .await;
        }

        0
    });

    result
}

/* ---------- Audited Pure-Rust Cryptographic Primitives ---------- */

use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

type HmacSha256 = Hmac<Sha256>;

/// Computes HMAC-SHA256(key, data) and writes the 32-byte MAC to `out32`.
/// Returns 0 on success, -1 on invalid arguments.
#[no_mangle]
pub extern "C" fn leant_rust_hmac_sha256(
    key_ptr: *const u8,
    key_len: usize,
    data_ptr: *const u8,
    data_len: usize,
    out32: *mut u8,
) -> i32 {
    if out32.is_null() {
        return -1;
    }
    let key = if key_len == 0 || key_ptr.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(key_ptr, key_len) }
    };
    let data = if data_len == 0 || data_ptr.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(data_ptr, data_len) }
    };
    let mut mac = match HmacSha256::new_from_slice(key) {
        Ok(m) => m,
        Err(_) => return -1,
    };
    mac.update(data);
    let result = mac.finalize().into_bytes();
    unsafe {
        std::ptr::copy_nonoverlapping(result.as_ptr(), out32, 32);
    }
    0
}

/// Constant-time equality comparison of two byte slices (returns 1 if equal, 0 otherwise).
#[no_mangle]
pub extern "C" fn leant_rust_ct_eq(
    a_ptr: *const u8,
    a_len: usize,
    b_ptr: *const u8,
    b_len: usize,
) -> u8 {
    if a_len != b_len {
        return 0;
    }
    if a_len == 0 {
        return 1;
    }
    if a_ptr.is_null() || b_ptr.is_null() {
        return 0;
    }
    let a = unsafe { slice::from_raw_parts(a_ptr, a_len) };
    let b = unsafe { slice::from_raw_parts(b_ptr, b_len) };
    if bool::from(a.ct_eq(b)) { 1 } else { 0 }
}

/// Fills `out_ptr[0..len]` with cryptographically secure random bytes from the OS CSPRNG.
/// Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn leant_rust_random_bytes(out_ptr: *mut u8, len: usize) -> i32 {
    if len == 0 {
        return 0;
    }
    if out_ptr.is_null() {
        return -1;
    }
    let buf = unsafe { slice::from_raw_parts_mut(out_ptr, len) };
    match getrandom::getrandom(buf) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/* ---------- Argon2id Password Hashing ---------- */

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

/// Hashes `password` with Argon2id + OS CSPRNG salt into a PHC string (`$argon2id$...`).
/// Writes NUL-terminated UTF-8 into `out_buf` (up to `out_cap` bytes) and sets `*out_len`.
/// Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn leant_rust_argon2_hash(
    pwd_ptr: *const u8,
    pwd_len: usize,
    out_buf: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_buf.is_null() || out_len.is_null() || out_cap < 128 {
        return -1;
    }
    let pwd = if pwd_len == 0 || pwd_ptr.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(pwd_ptr, pwd_len) }
    };

    let mut raw_salt = [0u8; 16];
    if getrandom::getrandom(&mut raw_salt).is_err() {
        return -1;
    }
    let salt = match SaltString::encode_b64(&raw_salt) {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let argon2 = Argon2::default();
    let phc = match argon2.hash_password(pwd, &salt) {
        Ok(h) => h.to_string(),
        Err(_) => return -1,
    };

    let bytes = phc.as_bytes();
    if bytes.len() >= out_cap {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
        *out_buf.add(bytes.len()) = 0;
        *out_len = bytes.len();
    }
    0
}

/// Verifies `password` against a PHC-formatted Argon2 hash string in constant time.
/// Returns 1 if valid, 0 otherwise.
#[no_mangle]
pub extern "C" fn leant_rust_argon2_verify(
    pwd_ptr: *const u8,
    pwd_len: usize,
    hash_ptr: *const u8,
    hash_len: usize,
) -> u8 {
    if hash_ptr.is_null() || hash_len == 0 {
        return 0;
    }
    let pwd = if pwd_len == 0 || pwd_ptr.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(pwd_ptr, pwd_len) }
    };
    let hash_bytes = unsafe { slice::from_raw_parts(hash_ptr, hash_len) };
    let hash_str = match std::str::from_utf8(hash_bytes) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let parsed = match PasswordHash::new(hash_str) {
        Ok(p) => p,
        Err(_) => return 0,
    };
    if Argon2::default().verify_password(pwd, &parsed).is_ok() {
        1
    } else {
        0
    }
}

/* ---------- Pure-Rust PostgreSQL Wire-Protocol Client ---------- */

use postgres::types::{IsNull, ToSql, Type};
use postgres::{Client, NoTls};

#[derive(Debug)]
struct AnyNull;

static ANY_NULL: AnyNull = AnyNull;

impl ToSql for AnyNull {
    fn to_sql(
        &self,
        _ty: &Type,
        _out: &mut bytes::BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        Ok(IsNull::Yes)
    }

    fn accepts(_ty: &Type) -> bool {
        true
    }

    postgres::types::to_sql_checked!();
}

#[derive(Debug)]
struct FlexInt(i64);

impl ToSql for FlexInt {
    fn to_sql(
        &self,
        ty: &Type,
        out: &mut bytes::BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        match *ty {
            Type::INT2 => i16::try_from(self.0)?.to_sql(ty, out),
            Type::INT4 => i32::try_from(self.0)?.to_sql(ty, out),
            _ => self.0.to_sql(ty, out),
        }
    }

    fn accepts(ty: &Type) -> bool {
        matches!(*ty, Type::INT2 | Type::INT4 | Type::INT8)
    }

    postgres::types::to_sql_checked!();
}

#[repr(C)]
pub struct PgParamC {
    /// 0 = null, 1 = int64, 2 = text, 3 = bool, 4 = blob
    pub tag: u8,
    pub bool_val: u8,
    pub int_val: i64,
    pub bytes_ptr: *const u8,
    pub bytes_len: usize,
}

#[repr(C)]
pub struct PgCellC {
    pub tag: u8,
    pub bool_val: u8,
    pub int_val: i64,
    pub bytes_ptr: *mut u8,
    pub bytes_len: usize,
}

#[repr(C)]
pub struct PgResultSetC {
    pub num_rows: usize,
    pub num_cols: usize,
    pub cells: *mut PgCellC,
}

enum OwnedPgParam {
    Null,
    Int(FlexInt),
    Text(String),
    Bool(bool),
    Blob(Vec<u8>),
}

impl OwnedPgParam {
    fn as_to_sql(&self) -> &(dyn ToSql + Sync) {
        match self {
            OwnedPgParam::Null => &ANY_NULL,
            OwnedPgParam::Int(v) => v,
            OwnedPgParam::Text(s) => s,
            OwnedPgParam::Bool(b) => b,
            OwnedPgParam::Blob(b) => b,
        }
    }
}

fn copy_err(msg: &str, err_buf: *mut u8, err_cap: usize) {
    if err_buf.is_null() || err_cap == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(err_cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), err_buf, n);
        *err_buf.add(n) = 0;
    }
}

fn decode_c_params(params_ptr: *const PgParamC, params_len: usize) -> Vec<OwnedPgParam> {
    if params_ptr.is_null() || params_len == 0 {
        return Vec::new();
    }
    let slice_params = unsafe { slice::from_raw_parts(params_ptr, params_len) };
    let mut out = Vec::with_capacity(params_len);
    for p in slice_params {
        match p.tag {
            1 => out.push(OwnedPgParam::Int(FlexInt(p.int_val))),
            2 => {
                let s = if p.bytes_ptr.is_null() || p.bytes_len == 0 {
                    String::new()
                } else {
                    let b = unsafe { slice::from_raw_parts(p.bytes_ptr, p.bytes_len) };
                    String::from_utf8_lossy(b).into_owned()
                };
                out.push(OwnedPgParam::Text(s));
            }
            3 => out.push(OwnedPgParam::Bool(p.bool_val != 0)),
            4 => {
                let v = if p.bytes_ptr.is_null() || p.bytes_len == 0 {
                    Vec::new()
                } else {
                    unsafe { slice::from_raw_parts(p.bytes_ptr, p.bytes_len).to_vec() }
                };
                out.push(OwnedPgParam::Blob(v));
            }
            _ => out.push(OwnedPgParam::Null),
        }
    }
    out
}

#[no_mangle]
pub extern "C" fn leant_rust_pg_connect(
    conn_str_ptr: *const c_char,
    err_buf: *mut u8,
    err_cap: usize,
) -> *mut c_void {
    if conn_str_ptr.is_null() {
        copy_err("null connection string", err_buf, err_cap);
        return std::ptr::null_mut();
    }
    let conn_str = match unsafe { std::ffi::CStr::from_ptr(conn_str_ptr).to_str() } {
        Ok(s) => s,
        Err(_) => {
            copy_err("invalid UTF-8 connection string", err_buf, err_cap);
            return std::ptr::null_mut();
        }
    };
    match Client::connect(conn_str, NoTls) {
        Ok(client) => Box::into_raw(Box::new(client)) as *mut c_void,
        Err(e) => {
            copy_err(&e.to_string(), err_buf, err_cap);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn leant_rust_pg_close(client_ptr: *mut c_void) {
    if !client_ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(client_ptr as *mut Client);
        }
    }
}

#[no_mangle]
pub extern "C" fn leant_rust_pg_exec(
    client_ptr: *mut c_void,
    sql_ptr: *const c_char,
    params_ptr: *const PgParamC,
    params_len: usize,
    err_buf: *mut u8,
    err_cap: usize,
) -> i32 {
    if client_ptr.is_null() || sql_ptr.is_null() {
        copy_err("null pg client or sql", err_buf, err_cap);
        return -1;
    }
    let client = unsafe { &mut *(client_ptr as *mut Client) };
    let sql = match unsafe { std::ffi::CStr::from_ptr(sql_ptr).to_str() } {
        Ok(s) => s,
        Err(_) => {
            copy_err("invalid UTF-8 sql", err_buf, err_cap);
            return -1;
        }
    };
    let owned = decode_c_params(params_ptr, params_len);
    let refs: Vec<&(dyn ToSql + Sync)> = owned.iter().map(|p| p.as_to_sql()).collect();
    match client.execute(sql, &refs) {
        Ok(_) => 0,
        Err(e) => {
            copy_err(&e.to_string(), err_buf, err_cap);
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn leant_rust_pg_query(
    client_ptr: *mut c_void,
    sql_ptr: *const c_char,
    params_ptr: *const PgParamC,
    params_len: usize,
    out_rs: *mut PgResultSetC,
    err_buf: *mut u8,
    err_cap: usize,
) -> i32 {
    if client_ptr.is_null() || sql_ptr.is_null() || out_rs.is_null() {
        copy_err("null pg query argument", err_buf, err_cap);
        return -1;
    }
    let client = unsafe { &mut *(client_ptr as *mut Client) };
    let sql = match unsafe { std::ffi::CStr::from_ptr(sql_ptr).to_str() } {
        Ok(s) => s,
        Err(_) => {
            copy_err("invalid UTF-8 sql", err_buf, err_cap);
            return -1;
        }
    };
    let owned = decode_c_params(params_ptr, params_len);
    let refs: Vec<&(dyn ToSql + Sync)> = owned.iter().map(|p| p.as_to_sql()).collect();
    let rows = match client.query(sql, &refs) {
        Ok(r) => r,
        Err(e) => {
            copy_err(&e.to_string(), err_buf, err_cap);
            return -1;
        }
    };

    let num_rows = rows.len();
    let num_cols = if num_rows > 0 { rows[0].len() } else { 0 };
    let mut cells: Vec<PgCellC> = Vec::with_capacity(num_rows * num_cols);

    for row in &rows {
        for i in 0..num_cols {
            let col_type = row.columns()[i].type_().name();
            let cell = match col_type {
                "int2" => match row.try_get::<_, Option<i16>>(i) {
                    Ok(Some(v)) => PgCellC { tag: 1, bool_val: 0, int_val: v as i64, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
                "int4" => match row.try_get::<_, Option<i32>>(i) {
                    Ok(Some(v)) => PgCellC { tag: 1, bool_val: 0, int_val: v as i64, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
                "int8" => match row.try_get::<_, Option<i64>>(i) {
                    Ok(Some(v)) => PgCellC { tag: 1, bool_val: 0, int_val: v, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
                "bool" => match row.try_get::<_, Option<bool>>(i) {
                    Ok(Some(b)) => PgCellC { tag: 3, bool_val: if b { 1 } else { 0 }, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
                "bytea" => match row.try_get::<_, Option<Vec<u8>>>(i) {
                    Ok(Some(mut v)) => {
                        let len = v.len();
                        let ptr = v.as_mut_ptr();
                        std::mem::forget(v);
                        PgCellC { tag: 4, bool_val: 0, int_val: 0, bytes_ptr: ptr, bytes_len: len }
                    }
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
                _ => match row.try_get::<_, Option<String>>(i) {
                    Ok(Some(s)) => {
                        let mut v = s.into_bytes();
                        let len = v.len();
                        let ptr = v.as_mut_ptr();
                        std::mem::forget(v);
                        PgCellC { tag: 2, bool_val: 0, int_val: 0, bytes_ptr: ptr, bytes_len: len }
                    }
                    _ => PgCellC { tag: 0, bool_val: 0, int_val: 0, bytes_ptr: std::ptr::null_mut(), bytes_len: 0 },
                },
            };
            cells.push(cell);
        }
    }

    let boxed = cells.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut PgCellC;
    unsafe {
        (*out_rs).num_rows = num_rows;
        (*out_rs).num_cols = num_cols;
        (*out_rs).cells = ptr;
    }
    0
}

#[no_mangle]
pub extern "C" fn leant_rust_pg_free_result(rs: *mut PgResultSetC) {
    if rs.is_null() {
        return;
    }
    unsafe {
        let total = (*rs).num_rows * (*rs).num_cols;
        if !(*rs).cells.is_null() && total > 0 {
            let slice_cells = slice::from_raw_parts_mut((*rs).cells, total);
            for cell in slice_cells.iter() {
                if !cell.bytes_ptr.is_null() && (cell.tag == 2 || cell.tag == 4) {
                    let _ = Vec::from_raw_parts(cell.bytes_ptr, cell.bytes_len, cell.bytes_len);
                }
            }
            let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut((*rs).cells, total));
        }
        (*rs).cells = std::ptr::null_mut();
        (*rs).num_rows = 0;
        (*rs).num_cols = 0;
    }
}


