// Supabase client, initialised from environment variables.
// Table: guides (id TEXT, task TEXT, steps_json TEXT, created_at TIMESTAMP)

const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
  console.warn(
    'Warning: SUPABASE_URL / SUPABASE_KEY not set. ' +
      'Guide storage will not work until they are configured in .env'
  );
}

const supabase =
  SUPABASE_URL && SUPABASE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_KEY)
    : null;

module.exports = supabase;
