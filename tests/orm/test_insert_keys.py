"""Compare Leant's committed inserts with SQLAlchemy's inserted_primary_key contract.

The generated/manual key scenarios follow SQLAlchemy's dialect conformance suite:
https://github.com/sqlalchemy/sqlalchemy/blob/rel_2_0/lib/sqlalchemy/testing/suite/test_insert.py
"""
import os
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote, urlencode
from uuid import uuid4

import pytest
import sqlalchemy as sa
from hypothesis import example, given, settings, strategies as st


PROBE = Path(__file__).resolve().parents[2] / ".lake/build/bin/orm_insert_probe"


@contextmanager
def database(backend):
    if backend == "sqlite":
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "insert.sqlite")
            engine = sa.create_engine(sa.URL.create("sqlite", database=path))
            try:
                yield engine, path
            finally:
                engine.dispose()
        return

    url = sa.make_url(os.environ["LEANT_TEST_PG_URL"])
    admin = sa.create_engine(url.set(drivername="postgresql+psycopg"))
    schema = "insert_test_" + uuid4().hex
    options = (url.query.get("options", "") + f" -c search_path={schema}").strip()
    scoped = url.update_query_dict({"options": options})
    engine = sa.create_engine(scoped.set(drivername="postgresql+psycopg"))
    try:
        with admin.begin() as conn:
            conn.execute(sa.schema.CreateSchema(schema))
        try:
            # The Rust PostgreSQL driver percent-decodes URI options literally.
            address = scoped.set(query={}).render_as_string(hide_password=False)
            query = urlencode(scoped.query, doseq=True, quote_via=quote)
            yield engine, f"{address}?{query}"
        finally:
            engine.dispose()
            with admin.begin() as conn:
                conn.execute(sa.schema.DropSchema(schema, cascade=True))
    finally:
        admin.dispose()


def reference_inserts(engine, ops):
    metadata = sa.MetaData()
    tables = {}
    for kind in ("generated", "manual", "no_int_key"):
        columns = [sa.Column("marker", sa.Text, primary_key=kind == "no_int_key")]
        if kind != "no_int_key":
            columns.insert(0, sa.Column("item_key", sa.Integer, primary_key=True,
                                        autoincrement=kind == "generated"))
        tables[kind] = sa.Table("reference_" + kind, metadata, *columns)
    metadata.create_all(engine)

    keys = []
    with engine.connect() as conn:
        for index, op in enumerate(ops):
            values = {"marker": str(index)}
            if isinstance(op, int):
                kind = "manual"
                values["item_key"] = op
            else:
                kind = {"auto": "generated", "text": "no_int_key"}[op]
            with conn.begin():
                result = conn.execute(tables[kind].insert().values(values))
                if kind == "no_int_key":
                    # Leant's Int result is a SQLite rowid or zero on PostgreSQL.
                    key = result.lastrowid if engine.dialect.name == "sqlite" else 0
                else:
                    key = result.inserted_primary_key[0]
                keys.append(key)
    return keys, tables


@pytest.mark.parametrize("backend", ["sqlite", "postgres"])
@settings(max_examples=12, deadline=None, derandomize=True)
@example(ops=[42])
@example(ops=["auto", 42, "text", "auto"])
@example(ops=["text", 0, -1])
@given(ops=st.lists(st.one_of(st.integers(-10000, 10000), st.sampled_from(["auto", "text"])),
                    min_size=1, max_size=8, unique=True))
def test_insert_keys(backend, ops):
    with database(backend) as (engine, target):
        expected, tables = reference_inserts(engine, ops)
        run = subprocess.run(
            [PROBE, backend, *map(str, ops)],
            env={**os.environ, "LEANT_PROBE_DATABASE": target},
            capture_output=True, text=True, timeout=30,
        )
        assert run.returncode == 0, run.stderr
        assert [int(line) for line in run.stdout.splitlines()] == expected

        with engine.connect() as reader:
            for kind, reference in tables.items():
                actual = sa.Table("leant_" + kind, sa.MetaData(), autoload_with=reader)
                names = list(reference.columns.keys())
                def rows(table):
                    return reader.execute(sa.select(*(table.c[n] for n in names))
                                          .order_by(table.c.marker)).all()
                assert rows(actual) == rows(reference)
