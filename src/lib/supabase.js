import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL?.trim();
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim();
let validUrl = false;
try {
  const parsed = new URL(url || '');
  validUrl = ['https:', 'http:'].includes(parsed.protocol) && Boolean(parsed.hostname);
} catch {
  validUrl = false;
}

export const supabaseConfigError = !url || !anonKey
  ? 'Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env.local, then restart the development server.'
  : !validUrl
    ? 'VITE_SUPABASE_URL is not a valid URL. Use the Project URL shown in Supabase settings (for example, https://your-project-ref.supabase.co).'
    : '';
export const isSupabaseConfigured = !supabaseConfigError;
export const supabase = isSupabaseConfigured
  ? createClient(url, anonKey, {
      auth: {
        // Take-home demo policy: each fresh page load requires a new sign-in.
        // Auth remains in memory for the current tab only.
        persistSession: false,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
      global: { headers: { 'X-Client-Info': 'cargolens-web' } },
    })
  : null;
