-- Extensions for hybrid search: vector similarity (pgvector) and trigram matching.
CREATE EXTENSION IF NOT EXISTS vector SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
