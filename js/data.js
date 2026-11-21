// EduFlow AI — data layer.
// SupabaseAdapter: the live backend. Security is enforced by RLS + triggers in the database.
(function () {
  const cfg = window.EDUFLOW_CONFIG || {};

  // ------------------------------------------------------------------ helpers
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now());
  const now = () => new Date();
  const iso = (d) => new Date(d).toISOString();
  const hoursAgo = (h) => iso(Date.now() - h * 3600e3);
  const daysAgo = (d) => hoursAgo(d * 24);
  let refSeq = 1200;
  const ref = (p) => `${p}-${String(now().getFullYear()).slice(2)}-${String(++refSeq).padStart(5, "0")}`;
  const DECISIONS = ["offered", "waitlisted", "declined", "enrolled"];
  const ROLE_GROUPS = {
    admissions: ["school_admin", "head_teacher", "admissions_officer"],
    finance: ["school_admin", "head_teacher", "bursar"],
    fin_write: ["school_admin", "bursar"],
    leaders: ["school_admin", "head_teacher"],
    office: ["school_admin", "head_teacher", "admissions_officer", "bursar"]
  };
  const can = (role, group) => (ROLE_GROUPS[group] || []).includes(role);
  const err = (m) => { const e = new Error(m); e.userMessage = m; throw e; };

  // ================================================================== SUPABASE
  function SupabaseAdapter() {
    const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
    let ctx = { school_id: null, role: null };
    const q = async (p) => { const { data, error } = await p; if (error) { error.userMessage = error.message; throw error; } return data; };

    return {
      mode: "live",
      setContext(c) { ctx = c; },
      async getSession() { const { data } = await sb.auth.getSession(); return data.session ? { user: { email: data.session.user.email } } : null; },
      async signIn(email, password) { await q(sb.auth.signInWithPassword({ email, password })); return this.getSession(); },
      async signOut() { await sb.auth.signOut(); },
      async myMemberships() {
        const rows = await q(sb.from("school_memberships").select("school_id, role_key, status, schools(name, slug)").eq("status", "active"));
        return rows.map((r) => ({ school_id: r.school_id, role_key: r.role_key, school_name: r.schools && r.schools.name, school_slug: r.schools && r.schools.slug }));
      },
      async getSchool() { return q(sb.from("schools").select("*").eq("id", ctx.school_id).single()); },
      async updateSchoolSettings(_s, patch) {
        const s = await this.getSchool();
        return q(sb.from("schools").update({ settings: Object.assign({}, s.settings, patch) }).eq("id", ctx.school_id).select().single());
      },
      async dashboard() {
        const v = await q(sb.from("v_school_dashboard").select("*").eq("school_id", ctx.school_id).single());
        if (can(ctx.role, "finance")) {
          const b = await q(sb.from("v_fee_balances").select("amount_billed, discount, amount_paid").eq("school_id", ctx.school_id));
          v.expected_fees = b.reduce((s, r) => s + Number(r.amount_billed) - Number(r.discount), 0);
          v.collected_fees = b.reduce((s, r) => s + Number(r.amount_paid), 0);
        }
        v.announcements_awaiting_approval = (await q(sb.from("announcements").select("id").eq("school_id", ctx.school_id).eq("status", "pending_approval"))).length;
        v.automation = can(ctx.role, "leaders") ? await q(sb.from("automation_logs").select("scenario,status,message,created_at").eq("school_id", ctx.school_id).order("created_at", { ascending: false }).limit(8)) : [];
        return v;
      },
      async listEnquiries() { return q(sb.from("admissions_enquiries").select("*").eq("school_id", ctx.school_id).order("created_at", { ascending: false }).limit(300)); },
      async updateEnquiry(id, patch) { return q(sb.from("admissions_enquiries").update(patch).eq("id", id).select().single()); },
      async listApplications() { return q(sb.from("applications").select("*").eq("school_id", ctx.school_id).order("created_at", { ascending: false }).limit(300)); },
      async getApplicationDocuments(appId) { return q(sb.from("application_documents").select("*").eq("application_id", appId)); },
      async setApplicationStatus(id, status, notes) {
        const patch = { status }; if (notes) patch.decision_notes = notes;
        return q(sb.from("applications").update(patch).eq("id", id).select().single());
      },
      async verifyDocument(docId, status) {
        const { data: u } = await sb.auth.getUser();
        return q(sb.from("application_documents").update({ verification_status: status, verified_by: u.user.id, verified_at: new Date().toISOString() }).eq("id", docId).select().single());
      },
      async documentUrl(path) { const r = await q(sb.storage.from("application-documents").createSignedUrl(path, 600)); return r.signedUrl; },
      async listMessages(status) {
        let p = sb.from("communication_logs").select("*").eq("school_id", ctx.school_id).eq("direction", "outbound").order("created_at", { ascending: false }).limit(200);
        if (status) p = p.eq("status", status);
        return q(p);
      },
      async approveMessage(id, body) { const patch = { status: "approved" }; if (body) patch.body = body; return q(sb.from("communication_logs").update(patch).eq("id", id).select().single()); },
      async rejectMessage(id) { return q(sb.from("communication_logs").update({ status: "rejected" }).eq("id", id).select().single()); },
      async createDraftMessage(o) { return q(sb.from("communication_logs").insert(Object.assign({ school_id: ctx.school_id, direction: "outbound", status: "draft" }, o)).select().single()); },
      async listAnnouncements() { return q(sb.from("announcements").select("*").eq("school_id", ctx.school_id).order("created_at", { ascending: false })); },
      async saveAnnouncement(a) {
        const row = Object.assign({ school_id: ctx.school_id }, a);
        return a.id ? q(sb.from("announcements").update(row).eq("id", a.id).select().single()) : q(sb.from("announcements").insert(row).select().single());
      },
      async listClasses() { return q(sb.from("classes").select("*").eq("school_id", ctx.school_id).order("name")); },
      async listFeeBalances() {
        const b = await q(sb.from("v_fee_balances").select("*").eq("school_id", ctx.school_id).order("balance", { ascending: false }));
        const st = await q(sb.from("students").select("id, first_name, last_name, admission_number, grade").eq("school_id", ctx.school_id));
        const map = Object.fromEntries(st.map((s) => [s.id, s]));
        return b.map((r) => Object.assign(r, { student: map[r.student_id] ? `${map[r.student_id].first_name} ${map[r.student_id].last_name}` : "",
          admission_number: map[r.student_id] && map[r.student_id].admission_number, grade: map[r.student_id] && map[r.student_id].grade,
          paid: Number(r.amount_paid), pending: Number(r.amount_pending), balance: Number(r.balance) }));
      },
      async listPayments() {
        const rows = await q(sb.from("payments").select("*, students(first_name,last_name)").eq("school_id", ctx.school_id).order("paid_at", { ascending: false }).limit(300));
        return rows.map((p) => Object.assign(p, { student: p.students ? `${p.students.first_name} ${p.students.last_name}` : "" }));
      },
      async recordPayment(o) {
        const acct = await q(sb.from("student_fee_accounts").select("student_id").eq("id", o.fee_account_id).single());
        return q(sb.from("payments").insert(Object.assign({ school_id: ctx.school_id, student_id: acct.student_id, status: "confirmed", source: "manual" }, o)));
      },
      async confirmPayment(id) { return q(sb.from("payments").update({ status: "confirmed" }).eq("id", id)); },
      async reversePayment(id, reason) { return q(sb.from("payments").update({ status: "reversed", reversal_reason: reason }).eq("id", id)); },
      async listReminders() {
        const rows = await q(sb.from("payment_reminders").select("*, parents_guardians(full_name), student_fee_accounts(students(first_name,last_name))")
          .eq("school_id", ctx.school_id).order("created_at", { ascending: false }).limit(300));
        return rows.map((r) => Object.assign(r, { guardian: r.parents_guardians && r.parents_guardians.full_name,
          student: r.student_fee_accounts && r.student_fee_accounts.students ? `${r.student_fee_accounts.students.first_name} ${r.student_fee_accounts.students.last_name}` : "" }));
      },
      async createReminderBatch() { return q(sb.rpc("create_reminder_batch", { p_school: ctx.school_id })); },
      async setReminderStatus(ids, status) { return q(sb.from("payment_reminders").update({ status }).in("id", ids)); },
      async listTasks() { return q(sb.from("staff_tasks").select("*").eq("school_id", ctx.school_id).in("status", ["open", "in_progress", "done"]).order("due_at")); },
      async updateTask(id, patch) { return q(sb.from("staff_tasks").update(patch).eq("id", id).select().single()); },
      async listEvents() { return q(sb.from("school_events").select("*").eq("school_id", ctx.school_id).gte("starts_at", new Date(Date.now() - 864e5).toISOString()).order("starts_at")); },
      async listMyClassStudents() {
        const students = await q(sb.from("students").select("*").eq("school_id", ctx.school_id).order("first_name"));
        const cls = students.length ? await q(sb.from("classes").select("*").eq("id", students[0].class_id).single()) : null;
        return { cls, students };
      },
      async aiDraft(kind, input) {
        if (!cfg.MAKE_AI_DRAFT_WEBHOOK) err("AI drafting is not configured yet. Ask Naomi Mwangi to connect the AI draft scenario (S8).");
        const { data } = await sb.auth.getSession();
        const res = await fetch(cfg.MAKE_AI_DRAFT_WEBHOOK, { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ kind, school_id: ctx.school_id, input, access_token: data.session.access_token }) });
        if (!res.ok) err("The AI draft service did not respond. Please write the message yourself or try again.");
        return res.json();
      },
      async submitEnquiry(slug, f) {
        return q(sb.rpc("submit_enquiry", { p_school_slug: slug, p_parent_name: f.parent_name, p_parent_phone: f.parent_phone || null, p_parent_email: f.parent_email || null,
          p_learner_first_name: f.learner_first_name || null, p_learner_age: f.learner_age ? Number(f.learner_age) : null, p_grade_sought: f.grade_sought || null,
          p_intake: f.intake || null, p_message: f.message || null, p_consent: !!f.consent }));
      },
      async submitApplication(slug, f) {
        return q(sb.rpc("submit_application", { p_school_slug: slug, p_enquiry_reference: f.enquiry_reference || null, p_learner_first_name: f.learner_first_name,
          p_learner_last_name: f.learner_last_name, p_date_of_birth: f.date_of_birth || null, p_gender: f.gender || null, p_grade_applied: f.grade_applied,
          p_intake: f.intake || null, p_previous_school: f.previous_school || null, p_parent_name: f.parent_name, p_parent_phone: f.parent_phone || null,
          p_parent_email: f.parent_email || null, p_consent: !!f.consent }));
      },
      async uploadApplicationDocument(app, docType, file) {
        if (!["application/pdf","image/jpeg","image/png"].includes(file.type)) err("Only PDF, JPG or PNG files are accepted.");
        if (file.size > 5 * 1024 * 1024) err("Each file must be 5 MB or smaller.");
        const safe = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80);
        const path = `${app.school_id}/${app.application_id}/${app.upload_token}/${docType}-${Date.now()}-${safe}`;
        await q(sb.storage.from("application-documents").upload(path, file, { contentType: file.type, upsert: false }));
        return q(sb.rpc("register_application_document", { p_application_id: app.application_id, p_upload_token: app.upload_token, p_document_type: docType,
          p_storage_path: path, p_file_name: file.name, p_mime_type: file.type, p_size_bytes: file.size }));
      },
      async publicSchool(slug) { return q(sb.rpc("get_public_school", { p_school_slug: slug })); }
    };
  }

  window.EduFlowData = (cfg.SUPABASE_URL && window.supabase) ? SupabaseAdapter() : null;
  window.EduFlowRoles = { can, DECISIONS, ROLE_GROUPS };
})();
