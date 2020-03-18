CREATE KEYSPACE IF NOT EXISTS migrator
    WITH REPLICATION = {{ migrator_keyspace_replication }}
    AND DURABLE_WRITES = true;

CREATE TABLE IF NOT EXISTS migrator.schema_version (
    target_keyspace text,
    script_name text,
    checksum text,
    executed_by text,
    executed_on timestamp,
    execution_time int,
    status text,
    PRIMARY KEY (target_keyspace, script_name)
);
