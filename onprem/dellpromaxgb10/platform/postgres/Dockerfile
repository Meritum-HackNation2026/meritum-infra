# meritum-postgres: PostgreSQL 18 + pgvector + Polish full-text search.
# Installing hunspell-pl makes Debian's postgresql-common convert the Hunspell
# dictionary to UTF-8 as tsearch_data/pl_pl.{dict,affix}. On a fresh data
# directory the init scripts create vector, pg_trgm and the `public.polish`
# text search configuration in POSTGRES_DB; setup.sh reapplies them idempotently.
FROM pgvector/pgvector:0.8.7-pg18-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends hunspell-pl \
 && rm -rf /var/lib/apt/lists/* \
 && test -s "$(pg_config --sharedir)/tsearch_data/pl_pl.dict"
COPY polish.stop /usr/share/postgresql/18/tsearch_data/polish.stop
COPY extensions.sql /docker-entrypoint-initdb.d/10-extensions.sql
COPY polish-fts.sql /docker-entrypoint-initdb.d/20-polish-fts.sql
