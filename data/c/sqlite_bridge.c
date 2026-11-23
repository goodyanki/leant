#include <lean/lean.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static lean_external_class *g_sqlite_conn_class = NULL;

static void sqlite_conn_finalizer(void *ptr) {
    if (ptr != NULL) {
        sqlite3_close_v2((sqlite3 *)ptr);
    }
}

static void sqlite_conn_foreach(void *ptr, b_lean_obj_arg f) {
    (void)ptr;
    (void)f;
}

static lean_external_class *get_sqlite_conn_class(void) {
    if (g_sqlite_conn_class == NULL) {
        g_sqlite_conn_class = lean_register_external_class(
            sqlite_conn_finalizer,
            sqlite_conn_foreach
        );
    }
    return g_sqlite_conn_class;
}

static lean_obj_res mk_sqlite_error(const char *prefix, sqlite3 *db) {
    const char *msg = (db != NULL) ? sqlite3_errmsg(db) : "unknown sqlite error";
    size_t plen = strlen(prefix);
    size_t mlen = strlen(msg);
    char *buf = (char *)malloc(plen + mlen + 3);
    if (buf == NULL) {
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
    }
    memcpy(buf, prefix, plen);
    buf[plen] = ':';
    buf[plen + 1] = ' ';
    memcpy(buf + plen + 2, msg, mlen + 1);
    lean_obj_res err = lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(buf)));
    free(buf);
    return err;
}

/* Bind Array SqlValue to prepared sqlite3_stmt.
 * SqlValue constructor layout:
 *   | null              => scalar 0
 *   | int (v : Int)     => tag 1, obj[0] = Int
 *   | text (v : String) => tag 2, obj[0] = String
 *   | bool (v : Bool)   => tag 3, scalar uint8 at offset 0
 *   | blob (v : ByteArray) => tag 4, obj[0] = ByteArray
 */
static int bind_params(sqlite3_stmt *stmt, b_lean_obj_arg params) {
    size_t n = lean_array_size(params);
    for (size_t i = 0; i < n; i++) {
        lean_object *val = lean_array_get_core(params, i);
        int idx = (int)(i + 1);
        int rc = SQLITE_OK;

        if (lean_is_scalar(val)) {
            /* tag 0: SqlValue.null */
            rc = sqlite3_bind_null(stmt, idx);
        } else {
            unsigned tag = lean_obj_tag(val);
            switch (tag) {
                case 1: {
                    /* SqlValue.int */
                    lean_object *int_obj = lean_ctor_get(val, 0);
                    int64_t v = (int64_t)lean_int64_of_int(int_obj);
                    rc = sqlite3_bind_int64(stmt, idx, v);
                    break;
                }
                case 2: {
                    /* SqlValue.text */
                    lean_object *str_obj = lean_ctor_get(val, 0);
                    const char *s = lean_string_cstr(str_obj);
                    size_t len = lean_string_size(str_obj) - 1;
                    rc = sqlite3_bind_text64(stmt, idx, s, (sqlite3_uint64)len, SQLITE_TRANSIENT, SQLITE_UTF8);
                    break;
                }
                case 3: {
                    /* SqlValue.bool */
                    uint8_t b = lean_ctor_get_uint8(val, 0);
                    rc = sqlite3_bind_int(stmt, idx, b ? 1 : 0);
                    break;
                }
                case 4: {
                    /* SqlValue.blob */
                    lean_object *ba_obj = lean_ctor_get(val, 0);
                    const void *data = (const void *)lean_sarray_cptr(ba_obj);
                    size_t len = lean_sarray_size(ba_obj);
                    rc = sqlite3_bind_blob64(stmt, idx, data, (sqlite3_uint64)len, SQLITE_TRANSIENT);
                    break;
                }
                default:
                    rc = SQLITE_MISUSE;
                    break;
            }
        }
        if (rc != SQLITE_OK) {
            return rc;
        }
    }
    return SQLITE_OK;
}

static lean_obj_res read_column_value(sqlite3_stmt *stmt, int col) {
    int col_type = sqlite3_column_type(stmt, col);
    switch (col_type) {
        case SQLITE_NULL:
            return lean_box(0); /* SqlValue.null */
        case SQLITE_INTEGER: {
            int64_t v = sqlite3_column_int64(stmt, col);
            lean_obj_res obj = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(obj, 0, lean_int64_to_int(v));
            return obj;
        }
        case SQLITE_TEXT: {
            const unsigned char *txt = sqlite3_column_text(stmt, col);
            int bytes = sqlite3_column_bytes(stmt, col);
            lean_obj_res s = (txt != NULL && bytes > 0)
                ? lean_mk_string_from_bytes((const char *)txt, (size_t)bytes)
                : lean_mk_string("");
            lean_obj_res obj = lean_alloc_ctor(2, 1, 0);
            lean_ctor_set(obj, 0, s);
            return obj;
        }
        case SQLITE_BLOB: {
            const void *blob = sqlite3_column_blob(stmt, col);
            int bytes = sqlite3_column_bytes(stmt, col);
            size_t len = (bytes > 0) ? (size_t)bytes : 0;
            lean_obj_res ba = lean_alloc_sarray(1, len, len);
            if (len > 0 && blob != NULL) {
                memcpy(lean_sarray_cptr(ba), blob, len);
            }
            lean_obj_res obj = lean_alloc_ctor(4, 1, 0);
            lean_ctor_set(obj, 0, ba);
            return obj;
        }
        case SQLITE_FLOAT: {
            /* Encode float as text to preserve precision without adding float SqlValue variant. */
            const unsigned char *txt = sqlite3_column_text(stmt, col);
            int bytes = sqlite3_column_bytes(stmt, col);
            lean_obj_res s = (txt != NULL && bytes > 0)
                ? lean_mk_string_from_bytes((const char *)txt, (size_t)bytes)
                : lean_mk_string("0");
            lean_obj_res obj = lean_alloc_ctor(2, 1, 0);
            lean_ctor_set(obj, 0, s);
            return obj;
        }
        default:
            return lean_box(0);
    }
}

LEAN_EXPORT lean_obj_res leant_sqlite_open(b_lean_obj_arg path_obj, lean_obj_arg world) {
    (void)world;
    const char *path = lean_string_cstr(path_obj);
    sqlite3 *db = NULL;
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    int rc = sqlite3_open_v2(path, &db, flags, NULL);
    if (rc != SQLITE_OK) {
        lean_obj_res err = mk_sqlite_error("sqlite open failed", db);
        if (db != NULL) sqlite3_close_v2(db);
        return err;
    }

    sqlite3_busy_timeout(db, 5000);
    sqlite3_exec(db, "PRAGMA foreign_keys = ON;", NULL, NULL, NULL);
    if (strcmp(path, ":memory:") != 0) {
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", NULL, NULL, NULL);
    }

    lean_obj_res ext = lean_alloc_external(get_sqlite_conn_class(), (void *)db);
    return lean_io_result_mk_ok(ext);
}

LEAN_EXPORT lean_obj_res leant_sqlite_exec(
    b_lean_obj_arg conn_obj,
    b_lean_obj_arg sql_obj,
    b_lean_obj_arg params_obj,
    lean_obj_arg world
) {
    (void)world;
    sqlite3 *db = (sqlite3 *)lean_get_external_data(conn_obj);
    const char *sql = lean_string_cstr(sql_obj);
    sqlite3_stmt *stmt = NULL;

    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return mk_sqlite_error("sqlite prepare failed", db);
    }

    rc = bind_params(stmt, params_obj);
    if (rc != SQLITE_OK) {
        sqlite3_finalize(stmt);
        return mk_sqlite_error("sqlite bind failed", db);
    }

    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        return mk_sqlite_error("sqlite exec failed", db);
    }

    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res leant_sqlite_query(
    b_lean_obj_arg conn_obj,
    b_lean_obj_arg sql_obj,
    b_lean_obj_arg params_obj,
    lean_obj_arg world
) {
    (void)world;
    sqlite3 *db = (sqlite3 *)lean_get_external_data(conn_obj);
    const char *sql = lean_string_cstr(sql_obj);
    sqlite3_stmt *stmt = NULL;

    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return mk_sqlite_error("sqlite prepare failed", db);
    }

    rc = bind_params(stmt, params_obj);
    if (rc != SQLITE_OK) {
        sqlite3_finalize(stmt);
        return mk_sqlite_error("sqlite bind failed", db);
    }

    int col_count = sqlite3_column_count(stmt);
    lean_obj_res rows = lean_mk_empty_array();

    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        lean_obj_res row = lean_mk_empty_array_with_capacity(lean_box((size_t)col_count));
        for (int c = 0; c < col_count; c++) {
            row = lean_array_push(row, read_column_value(stmt, c));
        }
        rows = lean_array_push(rows, row);
    }

    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        lean_dec(rows);
        return mk_sqlite_error("sqlite query failed", db);
    }

    return lean_io_result_mk_ok(rows);
}

LEAN_EXPORT lean_obj_res leant_sqlite_last_insert_rowid(
    b_lean_obj_arg conn_obj,
    lean_obj_arg world
) {
    (void)world;
    sqlite3 *db = (sqlite3 *)lean_get_external_data(conn_obj);
    int64_t rowid = sqlite3_last_insert_rowid(db);
    return lean_io_result_mk_ok(lean_int64_to_int(rowid));
}
