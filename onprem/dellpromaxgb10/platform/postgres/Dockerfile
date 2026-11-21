# meritum-postgres: PostgreSQL 18 + pgvector + Polish full-text search.
# Installing hunspell-pl makes Debian's postgresql-common convert the Hunspell
# dictionary to UTF-8 as tsearch_data/pl_pl.{dict,affix}; setup.sh builds the
# `public.polish` text search configuration on top of it.
FROM pgvector/pgvector:0.8.7-pg18-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends hunspell-pl \
 && rm -rf /var/lib/apt/lists/* \
 && test -s "$(pg_config --sharedir)/tsearch_data/pl_pl.dict"
COPY polish.stop /usr/share/postgresql/18/tsearch_data/polish.stop
