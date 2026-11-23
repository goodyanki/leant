#include <lean/lean.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

extern void lean_initialize_thread(void);
extern void lean_finalize_thread(void);

/* Exported by Rust (transport/rust-http/src/lib.rs) */
extern int32_t leant_rust_serve(
    const char *host,
    uint16_t port,
    uint32_t max_connections,
    size_t max_body_bytes,
    uint8_t keep_alive,
    uint32_t header_timeout_ms,
    uint32_t request_timeout_ms,
    uint32_t shutdown_timeout_ms,
    void *handler_ctx
);

/* Exported by Lean (Leant/Transport/RustHyper.lean) */
extern lean_obj_res leant_internal_dispatch(
    lean_obj_arg handler,
    lean_obj_arg method,
    lean_obj_arg path,
    lean_obj_arg query,
    lean_obj_arg headers_raw,
    lean_obj_arg body,
    lean_obj_arg world
);

typedef struct {
    uint16_t status;
    const uint8_t *headers_ptr;
    size_t headers_len;
    const uint8_t *body_ptr;
    size_t body_len;
    void *lean_obj;
} LeanRawResponse;

/* Persistent zero-alloc singletons for common hot-path request inputs (M2.8). */
static lean_object *g_empty_str = NULL;
static lean_object *g_empty_bytes = NULL;
static lean_object *g_method_get = NULL;
static lean_object *g_method_post = NULL;

static void init_persistent_singletons(void) {
    if (g_empty_str == NULL) {
        g_empty_str = lean_mk_string_from_bytes("", 0);
        lean_mark_persistent(g_empty_str);

        g_empty_bytes = lean_alloc_sarray(1, 0, 0);
        lean_mark_persistent(g_empty_bytes);

        g_method_get = lean_mk_string_from_bytes("GET", 3);
        lean_mark_persistent(g_method_get);

        g_method_post = lean_mk_string_from_bytes("POST", 4);
        lean_mark_persistent(g_method_post);
    }
}

void leant_bridge_thread_init(void) {
    lean_initialize_thread();
}

void leant_bridge_thread_finalize(void) {
    lean_finalize_thread();
}

void leant_bridge_handle(
    void *handler_ctx,
    const uint8_t *method_ptr,
    size_t method_len,
    const uint8_t *path_ptr,
    size_t path_len,
    const uint8_t *query_ptr,
    size_t query_len,
    const uint8_t *headers_ptr,
    size_t headers_len,
    const uint8_t *body_ptr,
    size_t body_len,
    LeanRawResponse *out
) {
    lean_object *handler = (lean_object *)handler_ctx;
    lean_inc(handler);

    lean_obj_res m;
    if (method_len == 3 && memcmp(method_ptr, "GET", 3) == 0) {
        m = g_method_get;
    } else if (method_len == 4 && memcmp(method_ptr, "POST", 4) == 0) {
        m = g_method_post;
    } else {
        m = lean_mk_string_from_bytes((const char *)method_ptr, method_len);
    }

    lean_obj_res p = lean_mk_string_from_bytes((const char *)path_ptr, path_len);
    lean_obj_res q = (query_len == 0)
        ? g_empty_str
        : lean_mk_string_from_bytes((const char *)query_ptr, query_len);
    lean_obj_res h = (headers_len == 0)
        ? g_empty_str
        : lean_mk_string_from_bytes((const char *)headers_ptr, headers_len);

    lean_obj_res b;
    if (body_len == 0) {
        b = g_empty_bytes;
    } else {
        b = lean_alloc_sarray(1, body_len, body_len);
        if (body_ptr != NULL) {
            memcpy(lean_sarray_cptr(b), body_ptr, body_len);
        }
    }

    lean_obj_res io_res = leant_internal_dispatch(handler, m, p, q, h, b, lean_io_mk_world());

    if (lean_io_result_is_ok(io_res)) {
        lean_object *resp = lean_io_result_get_value(io_res);
        lean_inc(resp);
        lean_dec_ref(io_res);

        lean_object *hdrs_obj = lean_ctor_get(resp, 0);
        lean_object *body_obj = lean_ctor_get(resp, 1);
        uint16_t status = lean_ctor_get_uint16(resp, sizeof(void *) * 2);

        out->status = status;
        out->headers_ptr = (const uint8_t *)lean_string_cstr(hdrs_obj);
        out->headers_len = lean_string_size(hdrs_obj) - 1;
        out->body_ptr = lean_sarray_cptr(body_obj);
        out->body_len = lean_sarray_size(body_obj);
        out->lean_obj = (void *)resp;
    } else {
        lean_dec_ref(io_res);
        out->status = 500;
        out->headers_ptr = (const uint8_t *)"Content-Type: text/plain; charset=utf-8\n";
        out->headers_len = 40;
        out->body_ptr = (const uint8_t *)"Internal Server Error";
        out->body_len = 21;
        out->lean_obj = NULL;
    }
}

void leant_bridge_free_response(void *lean_obj) {
    if (lean_obj != NULL) {
        lean_dec((lean_object *)lean_obj);
    }
}

LEAN_EXPORT lean_obj_res leant_c_serve(
    b_lean_obj_arg host_obj,
    uint16_t port,
    uint32_t max_connections,
    size_t max_body_bytes,
    uint8_t keep_alive,
    uint32_t header_timeout_ms,
    uint32_t request_timeout_ms,
    uint32_t shutdown_timeout_ms,
    lean_obj_arg handler,
    lean_obj_arg world
) {
    init_persistent_singletons();
    lean_mark_mt(handler);

    const char *host = lean_string_cstr(host_obj);
    int32_t rc = leant_rust_serve(
        host,
        port,
        max_connections,
        max_body_bytes,
        keep_alive,
        header_timeout_ms,
        request_timeout_ms,
        shutdown_timeout_ms,
        (void *)handler
    );

    lean_dec(handler);

    if (rc != 0) {
        return lean_io_result_mk_error(
            lean_mk_io_user_error(lean_mk_string("Failed to start Rust HTTP transport server"))
        );
    }
    return lean_io_result_mk_ok(lean_box(0));
}
