-- Polish full-text search: Hunspell dictionary (pl_pl, from hunspell-pl in the
-- image) with our stop words, then `simple` for words it does not know.
-- Use: to_tsvector('public.polish', text), websearch_to_tsquery('public.polish', q).
-- shortcut: the dictionary loads per connection (~200 ms on first use); add
-- shared_ispell if short-lived connections make that visible.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_ts_dict WHERE dictname = 'polish_hunspell' AND dictnamespace = 'public'::regnamespace) THEN
    CREATE TEXT SEARCH DICTIONARY public.polish_hunspell (
      TEMPLATE = ispell, DictFile = pl_pl, AffFile = pl_pl, StopWords = polish);
  END IF;
  IF NOT EXISTS (SELECT FROM pg_ts_config WHERE cfgname = 'polish' AND cfgnamespace = 'public'::regnamespace) THEN
    CREATE TEXT SEARCH CONFIGURATION public.polish (COPY = pg_catalog.simple);
    ALTER TEXT SEARCH CONFIGURATION public.polish
      ALTER MAPPING FOR asciiword, asciihword, hword_asciipart, word, hword, hword_part
      WITH public.polish_hunspell, simple;
  END IF;
END $$;
