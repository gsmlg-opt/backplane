defmodule Backplane.Repo.Migrations.ReconcileIndexedClientCredentials do
  use Ecto.Migration

  def up do
    clients = quote_name(prefix() || "public") <> ".clients"
    relation = String.replace(clients, "'", "''")

    # A historical local Memory migration used the published auth migration's
    # version. Ecto records versions only, so those databases skipped auth 00001.
    # Reconcile forward without changing receipts or invalidating issued digests.
    execute("""
    DO $reconcile$
    DECLARE
      clients_oid oid := '#{relation}'::regclass;
      digest_column pg_catalog.pg_attribute%ROWTYPE;
      hash_column pg_catalog.pg_attribute%ROWTYPE;
      has_digest boolean;
      has_hash boolean;
    BEGIN
      LOCK TABLE #{clients} IN ACCESS EXCLUSIVE MODE;

      SELECT * INTO digest_column FROM pg_catalog.pg_attribute
      WHERE attrelid = clients_oid AND attname = 'token_digest' AND NOT attisdropped;
      has_digest := FOUND;

      SELECT * INTO hash_column FROM pg_catalog.pg_attribute
      WHERE attrelid = clients_oid AND attname = 'token_hash' AND NOT attisdropped;
      has_hash := FOUND;

      IF has_hash AND NOT has_digest AND hash_column.atttypid = 'pg_catalog.text'::regtype THEN
        ALTER TABLE #{clients} ADD COLUMN token_digest bytea;
        ALTER TABLE #{clients} DROP COLUMN token_hash;
        CREATE UNIQUE INDEX clients_token_digest_index ON #{clients} (token_digest);
        ALTER TABLE #{clients} ADD CONSTRAINT clients_token_digest_length
          CHECK (token_digest IS NULL OR pg_catalog.octet_length(token_digest) = 32);

        SELECT * INTO digest_column FROM pg_catalog.pg_attribute
        WHERE attrelid = clients_oid AND attname = 'token_digest' AND NOT attisdropped;
      ELSIF NOT has_digest OR has_hash THEN
        RAISE EXCEPTION 'Client credential reconciliation: expected legacy hash-only or indexed digest-only clients';
      END IF;

      IF digest_column.atttypid <> 'pg_catalog.bytea'::regtype
         OR digest_column.attnotnull OR digest_column.atthasdef
         OR digest_column.attidentity <> '' OR digest_column.attgenerated <> '' THEN
        RAISE EXCEPTION 'Client credential reconciliation: token_digest must be nullable bytea without a default';
      END IF;

      IF EXISTS (SELECT 1 FROM #{clients}
                 WHERE token_digest IS NOT NULL AND pg_catalog.octet_length(token_digest) <> 32)
         OR EXISTS (SELECT 1 FROM #{clients} WHERE token_digest IS NOT NULL
                    GROUP BY token_digest HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'Client credential reconciliation: invalid or duplicate issued digests';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class idx ON idx.oid = i.indexrelid
        JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
        JOIN pg_catalog.pg_am am ON am.oid = idx.relam
        JOIN pg_catalog.pg_opclass op ON op.oid = i.indclass[0]
        WHERE i.indrelid = clients_oid AND idx.relnamespace = tbl.relnamespace
          AND idx.relname = 'clients_token_digest_index' AND am.amname = 'btree'
          AND i.indisunique AND i.indisvalid AND i.indisready AND i.indimmediate
          AND NOT i.indnullsnotdistinct AND i.indnkeyatts = 1 AND i.indnatts = 1
          AND i.indkey[0] = digest_column.attnum AND i.indexprs IS NULL AND i.indpred IS NULL
          AND op.opcname = 'bytea_ops' AND op.opcnamespace = 'pg_catalog'::regnamespace
      ) THEN
        RAISE EXCEPTION 'Client credential reconciliation: missing or unexpected unique digest index';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint c
        WHERE c.conrelid = clients_oid AND c.conname = 'clients_token_digest_length'
          AND c.contype = 'c' AND c.convalidated AND NOT c.connoinherit
          AND c.conkey = ARRAY[digest_column.attnum]::smallint[]
          AND pg_catalog.pg_get_expr(c.conbin, c.conrelid) =
              '((token_digest IS NULL) OR (octet_length(token_digest) = 32))'
      ) THEN
        RAISE EXCEPTION 'Client credential reconciliation: missing or unexpected validated digest length constraint';
      END IF;
    END
    $reconcile$;
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "Client credential invalidation is irreversible; use a digest-compatible release"
  end

  defp quote_name(name), do: ~s|"#{String.replace(name, "\"", "\"\"")}"|
end
