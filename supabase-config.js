// ALAE_SHOP.1 - Supabase configuration
// IMPORTANT: replace ONLY SUPABASE_KEY with the Publishable/Anon key from:
// Supabase Dashboard -> Project Settings -> API.
// Never put the service_role/secret key here.

const SUPABASE_URL = "https://nkwfspnstcupkqpcawxe.supabase.co";
const SUPABASE_KEY = "sb_publishable_a3ujj6e0TQm_dLwAXxpGJA_pZy6W44y";
window.SUPABASE_KEY = SUPABASE_KEY;

if (!window.supabase) {
  throw new Error("Supabase library not loaded");
}

if (!SUPABASE_KEY || SUPABASE_KEY === "YOUR_SUPABASE_PUBLISHABLE_KEY") {
  console.error("ALAE_SHOP: Supabase Publishable/Anon key is missing.");
}

window.supabaseClient = window.supabase.createClient(
  SUPABASE_URL,
  SUPABASE_KEY,
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  }
);
