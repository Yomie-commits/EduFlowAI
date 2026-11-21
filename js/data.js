// EduFlow AI — data layer.
// Two adapters with the SAME methods:
//   SupabaseAdapter: real backend. Security is enforced by RLS + triggers in the database.
//   DemoAdapter:     in-memory FICTIONAL data for demos and sales calls. Mirrors the
//                    database rules (approvals, no AI decisions) so the demo is honest.
(function () {
  const cfg = window.EDUFLOW_CONFIG || {};
  const DEMO = !cfg.SUPABASE_URL || new URLSearchParams(location.search).has("demo");

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

  // ====================================================================== DEMO
  function buildDemoData() {
    const S1 = "11111111-1111-4111-8111-111111111111", S2 = "22222222-2222-4222-8222-222222222222";
    const ff = ["Wanjiru","Achieng","Njeri","Atieno","Wambui","Chebet","Nafula","Mumbua","Akinyi","Wairimu","Jepkoech","Kerubo"];
    const fm = ["Kamau","Otieno","Mwangi","Kiprotich","Odhiambo","Mutua","Wekesa","Kariuki","Omondi","Njoroge","Kibet","Onyango"];
    const sn = ["Kamau","Ochieng","Mwangi","Kiptoo","Wafula","Mutiso","Njoroge","Owino","Karanja","Chege","Barasa","Nyambura","Kimani","Odera","Maina","Langat"];
    const grades = ["PP1","PP2","Grade 1","Grade 2","Grade 3","Grade 4","Grade 5","Grade 6"];
    const fees = [28000,28000,35000,35000,35000,42000,42000,42000];
    const d = { schools: [], classes: [], students: [], guardians: [], links: [], accounts: [], payments: [], enquiries: [], applications: [],
                documents: [], tasks: [], events: [], announcements: [], messages: [], reminders: [], automation: [] };
    const settings1 = { required_documents: ["birth_certificate","passport_photo","previous_report"], reminder_interval_days: 7, reminder_grace_days: 3,
                        enquiry_retention_months: 12, briefing_hour: 7, default_language: "en", fee_paybill: "000000 (demo)" };
    d.schools.push({ id: S1, name: "Mwangaza Junior Academy", slug: "mwangaza-junior", school_type: "primary", county: "Nairobi", status: "active",
                     phone: "+254700000101", email: "office@mwangaza.demo", curriculum: "CBC", settings: settings1 });
    d.schools.push({ id: S2, name: "Baraka Little Stars Daycare", slug: "baraka-daycare", school_type: "daycare", county: "Kiambu", status: "active",
                     settings: { required_documents: ["birth_certificate","immunisation_card"], reminder_interval_days: 14, reminder_grace_days: 5, default_language: "sw" } });
    let n = 0;
    grades.forEach((g, gi) => {
      const cls = { id: uid(), school_id: S1, name: `${g} Blue`, grade: g, teacher: `Tr. ${ff[gi]} ${sn[gi + 4]}`, mine: g === "Grade 4" };
      d.classes.push(cls);
      for (let i = 0; i < 6; i++) {
        n++;
        const st = { id: uid(), school_id: S1, admission_number: `MJA/${2020 + (n % 6)}/${String(n).padStart(3, "0")}`,
                     first_name: n % 2 === 0 ? ff[n % 12] : fm[n % 12], last_name: sn[(n * 7) % 16], grade: g, class_id: cls.id, status: "enrolled" };
        d.students.push(st);
        const gd = { id: uid(), school_id: S1, full_name: `${n % 3 === 0 ? "Mr." : "Mrs."} ${ff[(n + 3) % 12]} ${st.last_name}`,
                     phone: "+2547" + String(10000000 + n * 137).padStart(8, "0"), email: n % 4 === 0 ? `parent${n}@example.com` : null,
                     preferred_channel: n % 4 === 0 ? "email" : "sms", preferred_language: n % 5 === 0 ? "sw" : "en" };
        d.guardians.push(gd);
        d.links.push({ student_id: st.id, guardian_id: gd.id, is_fee_payer: true });
        const disc = n % 11 === 0 ? 5000 : 0;
        const acct = { id: uid(), school_id: S1, student_id: st.id, academic_year: 2026, term: 3, amount_billed: fees[gi], discount: disc,
                       due_date: "2026-09-08", reminders_paused: n === 17 };
        d.accounts.push(acct);
        const pay = (amount, method, reference, status, source, when) =>
          d.payments.push({ id: uid(), school_id: S1, fee_account_id: acct.id, student_id: st.id, amount, method, reference, status, source, paid_at: when });
        if (n % 4 === 0) pay(fees[gi] - disc, "mpesa", `DEMO${String(n).padStart(6, "0")}A`, "confirmed", "manual", "2026-09-02T10:00:00+03:00");
        else if (n % 4 === 1) pay(Math.round(fees[gi] / 2), "mpesa", `DEMO${String(n).padStart(6, "0")}B`, "confirmed", "manual", "2026-09-05T09:00:00+03:00");
        else if (n % 4 === 3) {
          pay(fees[gi] - 8000, "bank", `DEMOBANK${n}`, "confirmed", "manual", "2026-09-01T12:00:00+03:00");
          pay(3000, "mpesa", `DEMO${String(n).padStart(6, "0")}C`, "pending", "mpesa_c2b", daysAgo(1));
        }
      }
    });

    const E = (o) => d.enquiries.push(Object.assign({ id: uid(), school_id: S1, reference: ref("EQ"), source: "web_form", consent_given: true, needs_human: false, merge_count: 0 }, o));
    E({ parent_name: "Faith Mutiso", parent_phone: "+254711000201", learner_first_name: "Amani", learner_age: 5, grade_sought: "PP2", intake: "January 2027", message: "Do you have space in PP2 for January? What are the fees and is lunch included?", category: "fees", urgency: "normal", ai_summary: "Asks about PP2 space for January 2027 and whether lunch is included in fees.", status: "new", follow_up_due_at: hoursAgo(-22), created_at: hoursAgo(2) });
    E({ parent_name: "Brian Odera", parent_phone: "+254711000202", parent_email: "b.odera@example.com", learner_first_name: "Tumaini", learner_age: 8, grade_sought: "Grade 3", intake: "January 2027", message: "We are relocating from Kisumu in December. Can we book a school tour next week?", category: "tour_request", urgency: "high", ai_summary: "Family relocating from Kisumu; wants a school tour next week for Grade 3.", status: "new", follow_up_due_at: hoursAgo(-19), created_at: hoursAgo(5) });
    E({ source: "phone", parent_name: "Lucy Wafula", parent_phone: "+254711000203", learner_first_name: "Baraka", learner_age: 4, grade_sought: "PP1", intake: "January 2027", message: "Called reception asking about the school bus route to Kahawa West.", category: "transport", urgency: "normal", ai_summary: "Asks whether the school bus serves Kahawa West for a PP1 learner.", status: "acknowledged", follow_up_due_at: hoursAgo(1), created_at: daysAgo(1) });
    E({ parent_name: "Samuel Kiptoo", parent_phone: "+254711000204", learner_first_name: "Neema", learner_age: 10, grade_sought: "Grade 5", intake: "January 2027", message: "How does the CBC assessment work for a child joining Grade 5 from another school?", category: "curriculum", urgency: "normal", ai_summary: "Asks how CBC assessment works for a Grade 5 transfer learner.", status: "in_progress", follow_up_due_at: daysAgo(-1), created_at: daysAgo(2) });
    E({ parent_name: "Rose Njoroge", parent_email: "rose.n@example.com", learner_first_name: "Zawadi", learner_age: 6, grade_sought: "Grade 1", intake: "January 2027", message: "What documents do I need for admission?", category: "admission_process", urgency: "low", ai_summary: "Asks which documents are required for Grade 1 admission.", status: "converted", created_at: daysAgo(3) });
    E({ source: "walk_in", parent_name: "Daniel Maina", parent_phone: "+254711000206", learner_first_name: "Imani", learner_age: 7, grade_sought: "Grade 2", intake: "May 2027", message: "Visited the office. Interested in May intake; will bring report form.", category: "availability", urgency: "low", ai_summary: "Interested in May 2027 Grade 2 place; will bring the report form.", status: "in_progress", follow_up_due_at: daysAgo(2), created_at: daysAgo(4) });
    E({ parent_name: "Esther Langat", parent_phone: "+254711000207", learner_first_name: "Furaha", learner_age: 9, grade_sought: "Grade 4", intake: "January 2027", message: "My child has asthma. Do you have a school nurse on site?", category: "other", urgency: "high", needs_human: true, ai_summary: "Sensitive: parent asks about on-site nurse for a child's medical condition. Route to a human.", status: "new", follow_up_due_at: daysAgo(5), created_at: daysAgo(6) });
    E({ parent_name: "Kevin Barasa", parent_phone: "+254711000208", learner_first_name: "Jabari", learner_age: 5, grade_sought: "PP2", intake: "January 2027", message: "Is there a sibling discount? Our older child is in Grade 3 with you.", category: "fees", urgency: "normal", ai_summary: "Asks about sibling discount; older child already at the school.", status: "closed", created_at: daysAgo(8) });
    E({ source: "email", parent_name: "Mercy Chege", parent_email: "mercy.c@example.com", learner_first_name: "Hope", learner_age: 11, grade_sought: "Grade 6", intake: "January 2027", message: "Do you offer boarding or after-school care until 6pm?", category: "boarding_meals", urgency: "normal", ai_summary: "Asks about boarding or after-school care until 6 pm.", status: "acknowledged", follow_up_due_at: daysAgo(9), created_at: daysAgo(10) });
    E({ school_id: S2, parent_name: "Ann Kimani", parent_phone: "+254722000301", learner_first_name: "Malaika", learner_age: 2, grade_sought: "Toddlers", intake: "January 2027", message: "Je, mnapokea watoto wa miaka miwili?", category: "availability", urgency: "normal", ai_summary: "Asks (in Kiswahili) if the daycare takes 2-year-olds.", status: "new", created_at: daysAgo(1) });

    const A = (o, docs) => {
      const a = Object.assign({ id: uid(), school_id: S1, reference: ref("AP"), consent_given: true, intake: "January 2027", decided_by: null, decision_notes: null }, o);
      d.applications.push(a);
      (docs || []).forEach((t) => d.documents.push({ id: uid(), application_id: a.id, document_type: t, file_name: `${t}.pdf`, verification_status: a.learner_first_name === "Nia" ? "verified" : "pending" }));
      const req = settings1.required_documents;
      a.missing_documents = req.filter((r) => !(docs || []).includes(r));
      if (!a.status) a.status = a.missing_documents.length ? "incomplete" : "complete";
    };
    const all = ["birth_certificate","passport_photo","previous_report"];
    A({ learner_first_name: "Zawadi", learner_last_name: "Njoroge", grade_applied: "Grade 1", parent_name: "Rose Njoroge", parent_email: "rose.n@example.com", previous_school: "Little Lambs Kindergarten", created_at: daysAgo(2) }, []);
    A({ learner_first_name: "Kito", learner_last_name: "Owino", grade_applied: "Grade 3", parent_name: "Paul Owino", parent_phone: "+254711000301", previous_school: "Riverside Primary", created_at: daysAgo(5) }, ["birth_certificate"]);
    A({ learner_first_name: "Nia", learner_last_name: "Karanja", grade_applied: "Grade 5", parent_name: "Joyce Karanja", parent_phone: "+254711000302", previous_school: "Hillview Academy", status: "under_review", created_at: daysAgo(7) }, all);
    A({ learner_first_name: "Baraka", learner_last_name: "Wafula", grade_applied: "PP1", parent_name: "Lucy Wafula", parent_phone: "+254711000203", created_at: daysAgo(1) }, []);
    A({ learner_first_name: "Leo", learner_last_name: "Mutua", grade_applied: "Grade 4", parent_name: "Grace Mutua", parent_phone: "+254711000303", previous_school: "Sunrise School", status: "assessment", created_at: daysAgo(12) }, all);

    d.events.push({ id: uid(), school_id: S1, title: "Closing day, Term 3", starts_at: "2026-11-27T08:00:00+03:00", location: "School grounds", audience: "whole_school" });
    d.events.push({ id: uid(), school_id: S1, title: "Open day for January intake", starts_at: "2026-11-28T09:00:00+03:00", location: "Main hall", audience: "parents" });
    d.events.push({ id: uid(), school_id: S1, title: "Staff planning meeting", starts_at: "2026-12-02T10:00:00+03:00", location: "Staff room", audience: "staff" });
    d.events.push({ id: uid(), school_id: S1, title: "Term 1 2027 opening day", starts_at: "2027-01-06T07:30:00+03:00", location: "School grounds", audience: "whole_school" });

    d.announcements.push({ id: uid(), school_id: S1, title: "Closing day reminder", body: "Dear parents, learners close for the holiday on Friday 27 November at 12:30 pm. Please pick up your child on time. Report forms will be issued on the day. Thank you.", audience: "whole_school", channels: ["sms","email"], status: "pending_approval", ai_assisted: true, created_at: hoursAgo(3) });
    d.announcements.push({ id: uid(), school_id: S1, title: "Grade 4 science trip", body: "Dear Grade 4 parents, the class will visit the Nairobi National Museum on Wednesday. Please send a packed snack and a water bottle.", audience: "grade", grade: "Grade 4", channels: ["sms"], status: "draft", ai_assisted: false, created_at: daysAgo(1) });

    d.enquiries.filter((e) => e.school_id === S1 && ["new","acknowledged","in_progress"].includes(e.status)).forEach((e) =>
      d.tasks.push({ id: uid(), school_id: S1, title: `Follow up enquiry ${e.reference} (${e.parent_name})`, description: e.ai_summary, related_type: "enquiry",
                     related_id: e.id, priority: e.urgency === "high" ? "high" : "normal", status: "open", due_at: e.follow_up_due_at, assignee: "admissions_officer" }));
    d.tasks.push({ id: uid(), school_id: S1, title: "Review Term 3 fee reminder batch", description: "Check the weekly reminder drafts before Monday sending.", priority: "normal", status: "open", due_at: daysAgo(-2), assignee: "bursar" });
    d.tasks.push({ id: uid(), school_id: S1, title: "Prepare open day welcome pack", description: "Print 40 brochures and the 2027 fee structure.", priority: "normal", status: "in_progress", due_at: daysAgo(-6), assignee: "school_admin" });
    d.tasks.push({ id: uid(), school_id: S1, title: "Submit Grade 4 Term 3 attendance summary", description: "Due to the head teacher by Friday.", priority: "normal", status: "open", due_at: daysAgo(-1), assignee: "teacher" });

    d.enquiries.filter((e) => e.school_id === S1 && e.status === "new" && !e.needs_human).forEach((e) => {
      const first = e.parent_name.split(" ")[0];
      const body = e.category === "tour_request"
        ? `Dear ${first}, thank you for your interest in Mwangaza Junior Academy. We would be happy to show you around. Tours run on weekdays between 9 am and 3 pm, and on our open day on Saturday 28 November. Please reply with a day that suits you. Warm regards, Admissions Office.`
        : `Dear ${first}, thank you for contacting Mwangaza Junior Academy. We do have PP2 places for January 2027. Our admissions officer will share the 2027 fee structure with you today, including what is covered for lunch. Kind regards, Admissions Office.`;
      d.messages.push({ id: uid(), school_id: S1, direction: "outbound", channel: e.parent_email ? "email" : "sms", recipient: e.parent_email || e.parent_phone,
                        subject: `Your enquiry ${e.reference}`, body, related_type: "enquiry", related_id: e.id, ai_generated: true, requires_approval: true, status: "draft", created_at: hoursAgo(1) });
    });

    d.automation.push({ scenario: "S1_enquiry_intake", status: "success", message: "Enquiry stored, classified, acknowledged by SMS, task created", created_at: hoursAgo(2) });
    d.automation.push({ scenario: "S1_enquiry_intake", status: "partial", message: "SMS provider timeout; acknowledgement retried successfully", created_at: hoursAgo(5) });
    d.automation.push({ scenario: "S6_daily_briefing", status: "success", message: "Briefing emailed to 2 recipients", created_at: hoursAgo(9) });
    return d;
  }

  function DemoAdapter() {
    const d = buildDemoData();
    const S1 = d.schools[0].id;
    let role = null; try { role = sessionStorage.getItem("ef_demo_role"); } catch (e) {}
    const NAMES = { school_admin: "Wanjiru Kamau", head_teacher: "Peter Kamau", bursar: "Mary Achieng", admissions_officer: "James Otieno", teacher: "Tr. Chebet Njoroge" };
    const balanceOf = (a) => {
      const paid = d.payments.filter((p) => p.fee_account_id === a.id && p.status === "confirmed").reduce((s, p) => s + p.amount, 0);
      const pending = d.payments.filter((p) => p.fee_account_id === a.id && p.status === "pending").reduce((s, p) => s + p.amount, 0);
      return { paid, pending, balance: a.amount_billed - a.discount - paid };
    };
    const need = (group) => { if (!can(role, group)) err("Your role does not have access to this."); };
    const R = (v) => Promise.resolve(JSON.parse(JSON.stringify(v)));
    const studentName = (id) => { const s = d.students.find((x) => x.id === id); return s ? `${s.first_name} ${s.last_name}` : ""; };

    return {
      mode: "demo",
      async getSession() { return role ? { user: { email: `${role}@mwangaza.demo`, name: NAMES[role] } } : null; },
      async signIn(roleKey) { role = roleKey; try { sessionStorage.setItem("ef_demo_role", roleKey); } catch (e) {} return this.getSession(); },
      async signOut() { role = null; try { sessionStorage.removeItem("ef_demo_role"); } catch (e) {} },
      async myMemberships() { return role ? [{ school_id: S1, school_name: d.schools[0].name, role_key: role }] : []; },
      async getSchool() { return R(d.schools[0]); },
      async updateSchoolSettings(_s, patch) { need("leaders"); Object.assign(d.schools[0].settings, patch); return R(d.schools[0]); },

      async dashboard() {
        const s1 = (x) => x.school_id === S1;
        const balances = d.accounts.map((a) => Object.assign({}, a, balanceOf(a)));
        return R({
          enrolled_students: d.students.length,
          open_enquiries: d.enquiries.filter((e) => s1(e) && ["new","acknowledged"].includes(e.status)).length,
          enquiries_7d: d.enquiries.filter((e) => s1(e) && Date.parse(e.created_at) > Date.now() - 7 * 864e5).length,
          overdue_follow_ups: d.enquiries.filter((e) => s1(e) && ["new","acknowledged","in_progress"].includes(e.status) && e.follow_up_due_at && Date.parse(e.follow_up_due_at) < Date.now()).length,
          pending_applications: d.applications.filter((a) => s1(a) && ["submitted","incomplete","complete","under_review","assessment"].includes(a.status)).length,
          incomplete_applications: d.applications.filter((a) => s1(a) && a.status === "incomplete").length,
          overdue_fees: balances.filter((b) => b.balance > 0 && b.due_date < new Date().toISOString().slice(0, 10)).reduce((s, b) => s + b.balance, 0),
          expected_fees: balances.reduce((s, b) => s + b.amount_billed - b.discount, 0),
          collected_fees: balances.reduce((s, b) => s + b.paid, 0),
          messages_awaiting_approval: d.messages.filter((m) => m.status === "draft").length,
          reminders_awaiting_approval: d.reminders.filter((r) => r.status === "draft").length,
          announcements_awaiting_approval: d.announcements.filter((a) => a.status === "pending_approval").length,
          open_tasks: d.tasks.filter((t) => ["open","in_progress"].includes(t.status)).length,
          automation: d.automation
        });
      },

      async listEnquiries() { need("admissions"); return R(d.enquiries.filter((e) => e.school_id === S1).sort((a, b) => b.created_at.localeCompare(a.created_at))); },
      async updateEnquiry(id, patch) { need("admissions"); const e = d.enquiries.find((x) => x.id === id); Object.assign(e, patch); return R(e); },

      async listApplications() { need("admissions"); return R(d.applications.filter((a) => a.school_id === S1).sort((a, b) => b.created_at.localeCompare(a.created_at))); },
      async getApplicationDocuments(appId) { need("admissions"); return R(d.documents.filter((x) => x.application_id === appId)); },
      async setApplicationStatus(id, status, notes) {
        need("admissions");
        const a = d.applications.find((x) => x.id === id);
        if (DECISIONS.includes(status)) { a.decided_by = NAMES[role]; a.decided_at = iso(now()); }
        a.status = status; if (notes) a.decision_notes = notes; return R(a);
      },
      async verifyDocument(docId, status) { need("admissions"); const x = d.documents.find((y) => y.id === docId); x.verification_status = status; return R(x); },
      async documentUrl() { return null; },

      async listMessages(status) { need("office"); return R(d.messages.filter((m) => !status || m.status === status).sort((a, b) => b.created_at.localeCompare(a.created_at))); },
      async approveMessage(id, body) {
        need("office"); const m = d.messages.find((x) => x.id === id);
        if (body) m.body = body; m.status = "approved"; m.approved_by = NAMES[role]; m.approved_at = iso(now());
        // In production the dispatcher scenario (S0) sends it; here we simulate that after approval.
        setTimeout(() => { m.status = "sent"; m.sent_at = iso(now()); }, 1500);
        return R(m);
      },
      async rejectMessage(id) { need("office"); const m = d.messages.find((x) => x.id === id); m.status = "rejected"; return R(m); },
      async createDraftMessage(o) { need("office"); const m = Object.assign({ id: uid(), school_id: S1, direction: "outbound", status: "draft", requires_approval: true, created_at: iso(now()) }, o); d.messages.push(m); return R(m); },

      async listAnnouncements() { return R(d.announcements.slice().sort((a, b) => b.created_at.localeCompare(a.created_at))); },
      async saveAnnouncement(a) {
        need("office");
        if (a.status === "approved" && !can(role, "leaders")) err("Only the administrator or head teacher can approve announcements.");
        let x = a.id && d.announcements.find((y) => y.id === a.id);
        if (!x) { x = { id: uid(), school_id: S1, created_at: iso(now()) }; d.announcements.push(x); }
        Object.assign(x, a);
        if (a.status === "approved") { x.approved_by = NAMES[role]; x.approved_at = iso(now());
          x.recipient_count = x.audience === "whole_school" ? d.guardians.length : d.students.filter((s) => s.grade === x.grade).length;
          setTimeout(() => { x.status = "sent"; x.sent_at = iso(now()); }, 1500); }
        return R(x);
      },
      async listClasses() { return R(d.classes); },

      async listFeeBalances() {
        need("finance");
        return R(d.accounts.map((a) => {
          const st = d.students.find((s) => s.id === a.student_id);
          const link = d.links.find((l) => l.student_id === a.student_id);
          const g = d.guardians.find((x) => x.id === link.guardian_id);
          return Object.assign({ fee_account_id: a.id, student: `${st.first_name} ${st.last_name}`, admission_number: st.admission_number, grade: st.grade,
                                 guardian: g.full_name, guardian_phone: g.phone }, a, balanceOf(a));
        }).sort((x, y) => y.balance - x.balance));
      },
      async listPayments() { need("finance"); return R(d.payments.map((p) => Object.assign({ student: studentName(p.student_id) }, p)).sort((a, b) => (b.paid_at || "").localeCompare(a.paid_at || ""))); },
      async recordPayment(o) {
        need("fin_write");
        if (!(o.amount > 0)) err("Enter an amount greater than zero.");
        if (o.reference && d.payments.some((p) => p.method === o.method && p.reference === o.reference)) err("A payment with this reference already exists.");
        const a = d.accounts.find((x) => x.id === o.fee_account_id);
        d.payments.push(Object.assign({ id: uid(), school_id: S1, student_id: a.student_id, status: "confirmed", source: "manual", paid_at: iso(now()), confirmed_by: NAMES[role] }, o));
        return true;
      },
      async confirmPayment(id) { need("fin_write"); const p = d.payments.find((x) => x.id === id); p.status = "confirmed"; p.confirmed_by = NAMES[role]; return true; },
      async reversePayment(id, reason) { need("fin_write"); if (!reason) err("A reversal reason is required."); const p = d.payments.find((x) => x.id === id); p.status = "reversed"; p.reversal_reason = reason; return true; },

      async listReminders() {
        need("finance");
        return R(d.reminders.map((r) => {
          const a = d.accounts.find((x) => x.id === r.fee_account_id); const g = d.guardians.find((x) => x.id === r.guardian_id);
          return Object.assign({ student: studentName(a.student_id), guardian: g.full_name }, r);
        }));
      },
      async createReminderBatch() {
        need("fin_write");
        const s = d.schools[0].settings, today = new Date(), batch = uid(); let count = 0;
        d.accounts.forEach((a) => {
          const b = balanceOf(a); const due = new Date(a.due_date); due.setDate(due.getDate() + s.reminder_grace_days);
          if (b.balance <= 0 || b.pending > 0 || a.reminders_paused || due >= today) return;
          if (d.reminders.some((r) => r.fee_account_id === a.id && (["draft","approved"].includes(r.status) ||
              (r.status === "sent" && Date.parse(r.sent_at) > Date.now() - s.reminder_interval_days * 864e5)))) return;
          const st = d.students.find((x) => x.id === a.student_id); const g = d.guardians.find((x) => x.id === d.links.find((l) => l.student_id === st.id).guardian_id);
          const amt = b.balance.toLocaleString("en-KE");
          const body = g.preferred_language === "sw"
            ? `Habari ${g.full_name}. Huu ni ukumbusho wa kirafiki kutoka Mwangaza Junior Academy kwamba salio la karo ya muhula wa 3 kwa ${st.first_name} ni KES ${amt}. Kama tayari umelipa, tafadhali puuza ujumbe huu. Asante.`
            : `Dear ${g.full_name}, this is a friendly reminder from Mwangaza Junior Academy that the Term 3 fee balance for ${st.first_name} is KES ${amt}. If you have already paid, please ignore this message. Thank you.`;
          d.reminders.push({ id: uid(), school_id: S1, batch_id: batch, fee_account_id: a.id, guardian_id: g.id, balance_at_draft: b.balance,
                             channel: g.preferred_channel === "email" && g.email ? "email" : "sms", message_body: body, drafted_by: "template", status: "draft", created_at: iso(now()) });
          count++;
        });
        return { batch_id: batch, drafts: count };
      },
      async setReminderStatus(ids, status) {
        need(status === "approved" ? "fin_write" : "finance");
        ids.forEach((id) => { const r = d.reminders.find((x) => x.id === id); r.status = status;
          if (status === "approved") { r.approved_by = NAMES[role]; setTimeout(() => { r.status = "sent"; r.sent_at = iso(now()); }, 1500); } });
        return true;
      },

      async listTasks() {
        return R(d.tasks.filter((t) => can(role, "leaders") || t.assignee === role).sort((a, b) => (a.due_at || "").localeCompare(b.due_at || "")));
      },
      async updateTask(id, patch) { const t = d.tasks.find((x) => x.id === id); Object.assign(t, patch); return R(t); },
      async listEvents() { return R(d.events.slice().sort((a, b) => a.starts_at.localeCompare(b.starts_at))); },
      async listMyClassStudents() { const c = d.classes.find((x) => x.mine); return R({ cls: c, students: d.students.filter((s) => s.class_id === c.id) }); },

      async aiDraft(kind, input) {
        await new Promise((r) => setTimeout(r, 700));
        if (kind === "enquiry_reply") {
          const e = input;
          return { draft: `Dear ${e.parent_name.split(" ")[0]}, thank you for contacting Mwangaza Junior Academy about ${e.grade_sought || "admission"} for ${e.intake || "the next intake"}. ${e.category === "transport" ? "Our admissions officer will confirm whether our school bus serves your area and share the route details." : "Our admissions officer will share the details you asked for."} You are welcome to visit us on our open day on Saturday 28 November. Kind regards, Admissions Office.`, note: "Demo AI draft. Facts such as fees or bus routes are left for staff to confirm." };
        }
        if (kind === "announcement") return { draft: `Dear parents,\n\n${input.topic.trim()}.\n\nIf you have any questions, please contact the school office.\n\nThank you,\nMwangaza Junior Academy`, variations: [], note: "Demo AI draft. Check dates and times before approving." };
        return { draft: "", note: "" };
      },

      // Public forms (demo)
      async submitEnquiry(slug, f) {
        if (!f.consent) err("Consent is required to process your enquiry.");
        const phone = (f.parent_phone || "").replace(/\D/g, "");
        if (phone && !/^(0[17]\d{8}|254[17]\d{8})$/.test(phone)) err("Please enter a valid Kenyan phone number, e.g. 0712 345 678");
        const school = d.schools.find((s) => s.slug === slug) || d.schools[0];
        const e = { id: uid(), school_id: school.id, reference: ref("EQ"), source: "web_form", consent_given: true, status: "new", category: "unclassified", urgency: "normal",
                    created_at: iso(now()), follow_up_due_at: hoursAgo(-24), ...f };
        d.enquiries.push(e);
        return { reference: e.reference, duplicate: false, school: school.name };
      },
      async submitApplication(slug, f) {
        if (!f.consent) err("Consent is required to process your application.");
        const school = d.schools.find((s) => s.slug === slug) || d.schools[0];
        const a = { id: uid(), school_id: school.id, reference: ref("AP"), status: "incomplete", created_at: iso(now()), missing_documents: school.settings.required_documents.slice(), ...f };
        d.applications.push(a);
        return { reference: a.reference, application_id: a.id, upload_token: uid(), school_id: school.id, school: school.name, required_documents: school.settings.required_documents };
      },
      async uploadApplicationDocument(app, docType, file) {
        if (!["application/pdf","image/jpeg","image/png"].includes(file.type)) err("Only PDF, JPG or PNG files are accepted.");
        if (file.size > 5 * 1024 * 1024) err("Each file must be 5 MB or smaller.");
        const a = d.applications.find((x) => x.id === app.application_id);
        d.documents.push({ id: uid(), application_id: a.id, document_type: docType, file_name: file.name, verification_status: "pending" });
        a.missing_documents = a.missing_documents.filter((x) => x !== docType);
        if (!a.missing_documents.length) a.status = "complete";
        return { missing_documents: a.missing_documents };
      },
      async publicSchool(slug) { const s = d.schools.find((x) => x.slug === slug) || d.schools[0]; return { name: s.name, required_documents: s.settings.required_documents }; }
    };
  }

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
        const rows = await q(sb.from("school_memberships").select("school_id, role_key, status, schools(name)").eq("status", "active"));
        return rows.map((r) => ({ school_id: r.school_id, role_key: r.role_key, school_name: r.schools && r.schools.name }));
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
        if (!cfg.MAKE_AI_DRAFT_WEBHOOK) err("AI drafting is not configured yet. Ask YomieVerse to connect the AI draft scenario (S8).");
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

  window.EduFlowData = DEMO ? DemoAdapter() : SupabaseAdapter();
  window.EduFlowRoles = { can, DECISIONS, ROLE_GROUPS };
})();
