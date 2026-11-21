// EduFlow AI — frontend configuration
// The anon key is designed to be public: Row Level Security in the database
// decides what each user can see. NEVER put the service_role key, the Claude
// API key, SMS keys or M-Pesa credentials in any frontend file.
window.EDUFLOW_CONFIG = {
  // Leave empty to run the clickable demo with fictional data.
  SUPABASE_URL: "",
  SUPABASE_ANON_KEY: "",

  // Make webhook that returns an AI draft for staff (Scenario S8 in the plan).
  // Leave empty and the "Draft with AI" buttons explain that AI is not configured.
  MAKE_AI_DRAFT_WEBHOOK: "",

  // Default school for the public forms when ?school= is not in the link
  DEFAULT_SCHOOL_SLUG: "mwangaza-junior",

  BRAND: { product: "EduFlow AI", parent: "YomieVerse", whatsapp: "+254792002230", email: "mwanginaomi42@gmail.com" }
};
