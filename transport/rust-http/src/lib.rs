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
    // Hot path (M2.8): if request has no body (e.g. GET /plaintext, GET /json),
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
/// connection cap, and graceful drain on SIGINT/SIGTERM (M2.3).
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
