// EduFlow AI — frontend configuration
// The publishable key is designed to be public: Row Level Security in the database
// decides what each user can see. NEVER put the secret key, the AI provider key,
// SMS keys or M-Pesa credentials in any frontend file.
window.EDUFLOW_CONFIG = {
  SUPABASE_URL: "https://ncgszlwawiagennffkjw.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_DrrHdtn5nYUh9OCas-wL_A_3Gr_ePd7",

  // Make webhook that returns an AI draft for staff (scenario S8). Empty = AI draft buttons say "not configured".
  MAKE_AI_DRAFT_WEBHOOK: "",

  // Each school shares its own form links: enquiry.html?school=<slug> and apply.html?school=<slug>
  DEFAULT_SCHOOL_SLUG: "",

  BRAND: { product: "EduFlow AI", parent: "Naomi Mwangi", whatsapp: "+254792002230", email: "mwanginaomi42@gmail.com" }
};
