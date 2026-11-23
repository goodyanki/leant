#include <lean/lean.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

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

/* Persistent zero-alloc singletons for common hot-path request inputs. */
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

/* ---------- Crypto FFI Wrappers ---------- */

extern int32_t leant_rust_hmac_sha256(
    const uint8_t *key_ptr, size_t key_len,
    const uint8_t *data_ptr, size_t data_len,
    uint8_t *out32
);
extern uint8_t leant_rust_ct_eq(
    const uint8_t *a_ptr, size_t a_len,
    const uint8_t *b_ptr, size_t b_len
);
extern int32_t leant_rust_random_bytes(uint8_t *out_ptr, size_t len);

LEAN_EXPORT lean_obj_res leant_c_hmac_sha256(b_lean_obj_arg key_ba, b_lean_obj_arg data_ba) {
    lean_obj_res out = lean_alloc_sarray(1, 32, 32);
    int32_t rc = leant_rust_hmac_sha256(
        lean_sarray_cptr(key_ba), lean_sarray_size(key_ba),
        lean_sarray_cptr(data_ba), lean_sarray_size(data_ba),
        lean_sarray_cptr(out)
    );
    if (rc != 0) {
        memset(lean_sarray_cptr(out), 0, 32);
    }
    return out;
}

LEAN_EXPORT uint8_t leant_c_ct_eq(b_lean_obj_arg a_ba, b_lean_obj_arg b_ba) {
    return leant_rust_ct_eq(
        lean_sarray_cptr(a_ba), lean_sarray_size(a_ba),
        lean_sarray_cptr(b_ba), lean_sarray_size(b_ba)
    );
}

LEAN_EXPORT lean_obj_res leant_c_random_bytes(size_t len, lean_obj_arg world) {
    (void)world;
    lean_obj_res out = lean_alloc_sarray(1, len, len);
    int32_t rc = leant_rust_random_bytes(lean_sarray_cptr(out), len);
    if (rc != 0) {
        lean_dec(out);
        return lean_io_result_mk_error(
            lean_mk_io_user_error(lean_mk_string("CSPRNG failed"))
        );
    }
    return lean_io_result_mk_ok(out);
}

/* ---------- Argon2id FFI Wrappers ---------- */

extern int32_t leant_rust_argon2_hash(
    const uint8_t *pwd_ptr, size_t pwd_len,
    uint8_t *out_buf, size_t out_cap, size_t *out_len
);
extern uint8_t leant_rust_argon2_verify(
    const uint8_t *pwd_ptr, size_t pwd_len,
    const uint8_t *hash_ptr, size_t hash_len
);

LEAN_EXPORT lean_obj_res leant_c_argon2_hash(b_lean_obj_arg pwd_obj, lean_obj_arg world) {
    (void)world;
    char buf[256];
    size_t out_len = 0;
    int32_t rc = leant_rust_argon2_hash(
        (const uint8_t *)lean_string_cstr(pwd_obj),
        lean_string_size(pwd_obj) - 1,
        (uint8_t *)buf,
        sizeof(buf),
        &out_len
    );
    if (rc != 0) {
        return lean_io_result_mk_error(
            lean_mk_io_user_error(lean_mk_string("argon2 password hashing failed"))
        );
    }
    return lean_io_result_mk_ok(lean_mk_string_from_bytes(buf, out_len));
}

LEAN_EXPORT uint8_t leant_c_argon2_verify(b_lean_obj_arg pwd_obj, b_lean_obj_arg hash_obj) {
    return leant_rust_argon2_verify(
        (const uint8_t *)lean_string_cstr(pwd_obj),
        lean_string_size(pwd_obj) - 1,
        (const uint8_t *)lean_string_cstr(hash_obj),
        lean_string_size(hash_obj) - 1
    );
}

/* ---------- PostgreSQL FFI Wrappers ---------- */

typedef struct {
    uint8_t tag;
    uint8_t bool_val;
    int64_t int_val;
    const uint8_t *bytes_ptr;
    size_t bytes_len;
} PgParamC;

typedef struct {
    uint8_t tag;
    uint8_t bool_val;
    int64_t int_val;
    uint8_t *bytes_ptr;
    size_t bytes_len;
} PgCellC;

typedef struct {
    size_t num_rows;
    size_t num_cols;
    PgCellC *cells;
} PgResultSetC;

extern void *leant_rust_pg_connect(const char *conn_str, uint8_t *err_buf, size_t err_cap);
extern void leant_rust_pg_close(void *client_ptr);
extern int32_t leant_rust_pg_exec(
    void *client_ptr, const char *sql,
    const PgParamC *params_ptr, size_t params_len,
    uint8_t *err_buf, size_t err_cap
);
extern int32_t leant_rust_pg_query(
    void *client_ptr, const char *sql,
    const PgParamC *params_ptr, size_t params_len,
    PgResultSetC *out_rs,
    uint8_t *err_buf, size_t err_cap
);
extern void leant_rust_pg_free_result(PgResultSetC *rs);

static lean_external_class *g_pg_conn_class = NULL;

static void pg_conn_finalizer(void *ptr) {
    leant_rust_pg_close(ptr);
}

static void pg_conn_foreach(void *ptr, b_lean_obj_arg f) {
    (void)ptr;
    (void)f;
}

static lean_external_class *get_pg_conn_class(void) {
    if (g_pg_conn_class == NULL) {
        g_pg_conn_class = lean_register_external_class(pg_conn_finalizer, pg_conn_foreach);
    }
    return g_pg_conn_class;
}

static PgParamC *marshal_pg_params(b_lean_obj_arg params_obj, size_t *out_len) {
    size_t n = lean_array_size(params_obj);
    *out_len = n;
    if (n == 0) return NULL;
    PgParamC *arr = (PgParamC *)calloc(n, sizeof(PgParamC));
    if (arr == NULL) return NULL;
    for (size_t i = 0; i < n; i++) {
        lean_object *v = lean_array_get_core(params_obj, i);
        if (lean_is_scalar(v)) {
            arr[i].tag = 0;
        } else {
            unsigned tag = lean_obj_tag(v);
            arr[i].tag = (uint8_t)tag;
            if (tag == 1) {
                arr[i].int_val = (int64_t)lean_int64_of_int(lean_ctor_get(v, 0));
            } else if (tag == 2) {
                lean_object *s = lean_ctor_get(v, 0);
                arr[i].bytes_ptr = (const uint8_t *)lean_string_cstr(s);
                arr[i].bytes_len = lean_string_size(s) - 1;
            } else if (tag == 3) {
                arr[i].bool_val = lean_ctor_get_uint8(v, 0);
            } else if (tag == 4) {
                lean_object *ba = lean_ctor_get(v, 0);
                arr[i].bytes_ptr = lean_sarray_cptr(ba);
                arr[i].bytes_len = lean_sarray_size(ba);
            }
        }
    }
    return arr;
}

LEAN_EXPORT lean_obj_res leant_c_pg_connect(b_lean_obj_arg conn_str_obj, lean_obj_arg world) {
    (void)world;
    char err_buf[512] = {0};
    void *client = leant_rust_pg_connect(lean_string_cstr(conn_str_obj), (uint8_t *)err_buf, sizeof(err_buf));
    if (client == NULL) {
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(err_buf[0] ? err_buf : "postgres connect failed")));
    }
    return lean_io_result_mk_ok(lean_alloc_external(get_pg_conn_class(), client));
}

LEAN_EXPORT lean_obj_res leant_c_pg_exec(
    b_lean_obj_arg conn_obj,
    b_lean_obj_arg sql_obj,
    b_lean_obj_arg params_obj,
    lean_obj_arg world
) {
    (void)world;
    void *client = lean_get_external_data(conn_obj);
    size_t n = 0;
    PgParamC *params = marshal_pg_params(params_obj, &n);
    char err_buf[512] = {0};
    int32_t rc = leant_rust_pg_exec(client, lean_string_cstr(sql_obj), params, n, (uint8_t *)err_buf, sizeof(err_buf));
    free(params);
    if (rc != 0) {
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(err_buf[0] ? err_buf : "postgres exec failed")));
    }
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res leant_c_pg_query(
    b_lean_obj_arg conn_obj,
    b_lean_obj_arg sql_obj,
    b_lean_obj_arg params_obj,
    lean_obj_arg world
) {
    (void)world;
    void *client = lean_get_external_data(conn_obj);
    size_t n = 0;
    PgParamC *params = marshal_pg_params(params_obj, &n);
    PgResultSetC rs = {0, 0, NULL};
    char err_buf[512] = {0};
    int32_t rc = leant_rust_pg_query(client, lean_string_cstr(sql_obj), params, n, &rs, (uint8_t *)err_buf, sizeof(err_buf));
    free(params);
    if (rc != 0) {
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(err_buf[0] ? err_buf : "postgres query failed")));
    }

    lean_obj_res rows = lean_mk_empty_array_with_capacity(lean_box(rs.num_rows));
    for (size_t r = 0; r < rs.num_rows; r++) {
        lean_obj_res row = lean_mk_empty_array_with_capacity(lean_box(rs.num_cols));
        for (size_t c = 0; c < rs.num_cols; c++) {
            PgCellC cell = rs.cells[r * rs.num_cols + c];
            lean_obj_res val;
            if (cell.tag == 1) {
                val = lean_alloc_ctor(1, 1, 0);
                lean_ctor_set(val, 0, lean_int64_to_int(cell.int_val));
            } else if (cell.tag == 2) {
                lean_obj_res s = (cell.bytes_ptr != NULL && cell.bytes_len > 0)
                    ? lean_mk_string_from_bytes((const char *)cell.bytes_ptr, cell.bytes_len)
                    : lean_mk_string("");
                val = lean_alloc_ctor(2, 1, 0);
                lean_ctor_set(val, 0, s);
            } else if (cell.tag == 3) {
                val = lean_alloc_ctor(3, 0, 1);
                lean_ctor_set_uint8(val, 0, cell.bool_val ? 1 : 0);
            } else if (cell.tag == 4) {
                lean_obj_res ba = lean_alloc_sarray(1, cell.bytes_len, cell.bytes_len);
                if (cell.bytes_len > 0 && cell.bytes_ptr != NULL) {
                    memcpy(lean_sarray_cptr(ba), cell.bytes_ptr, cell.bytes_len);
                }
                val = lean_alloc_ctor(4, 1, 0);
                lean_ctor_set(val, 0, ba);
            } else {
                val = lean_box(0);
            }
            row = lean_array_push(row, val);
        }
        rows = lean_array_push(rows, row);
    }
    leant_rust_pg_free_result(&rs);
    return lean_io_result_mk_ok(rows);
}


