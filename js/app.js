// EduFlow AI — staff web app (role-aware). Works against DemoAdapter or SupabaseAdapter.
(function () {
  const api = window.EduFlowData;
  const { can, DECISIONS } = window.EduFlowRoles;
  const root = document.getElementById("root");
  const state = { session: null, membership: null, view: "dashboard", school: null, cache: {} };

  // --------------------------------------------------------------- utilities
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const kes = (n) => "KES " + Math.round(Number(n || 0)).toLocaleString("en-KE");
  const ACR = { sms: "SMS", mpesa: "M-Pesa", ai: "AI", mpesa_c2b: "M-Pesa (automatic)", csv_import: "CSV import" };
  const label = (s) => esc(ACR[s] || String(s || "").replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase()));
  const badge = (s) => `<span class="badge-status st-${esc(s)}">${label(s)}</span>`;
  const when = (d) => {
    if (!d) return "—";
    const t = new Date(d), diff = (Date.now() - t) / 36e5;
    if (diff >= 0 && diff < 1) return Math.max(1, Math.round(diff * 60)) + " min ago";
    if (diff >= 0 && diff < 24) return Math.round(diff) + " h ago";
    return t.toLocaleDateString("en-KE", { day: "numeric", month: "short" }) + (Math.abs(diff) < 24 * 200 ? "" : " " + t.getFullYear());
  };
  const dateTime = (d) => d ? new Date(d).toLocaleString("en-KE", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "—";
  const role = () => state.membership && state.membership.role_key;
  const toast = (msg, kind = "success") => {
    const el = document.createElement("div");
    el.className = `toast align-items-center text-bg-${kind === "error" ? "danger" : kind === "info" ? "secondary" : "success"} border-0`;
    el.innerHTML = `<div class="d-flex"><div class="toast-body">${esc(msg)}</div><button class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button></div>`;
    document.getElementById("toasts").appendChild(el);
    new bootstrap.Toast(el, { delay: 3500 }).show();
  };
  const fail = (e) => { console.error(e); toast(e.userMessage || e.message || "Something went wrong", "error"); };
  const modalEl = document.getElementById("efModal");
  const modal = new bootstrap.Modal(modalEl);
  const openModal = (title, body, footer) => {
    document.getElementById("efModalTitle").innerHTML = title;
    document.getElementById("efModalBody").innerHTML = body;
    document.getElementById("efModalFooter").innerHTML = footer || `<button class="btn btn-light" data-bs-dismiss="modal">Close</button>`;
    modal.show();
  };
  // In-page dialogs (browser confirm/prompt are blocked in many hosted frames and look unprofessional)
  const dialogBox = (text, withInput) => new Promise((resolve) => {
    const d = document.createElement("dialog");
    d.className = "ef-dialog";
    d.innerHTML = `<form method="dialog"><p class="mb-3">${esc(text)}</p>${withInput ? '<input class="form-control mb-3" id="dlgIn" required>' : ""}
      <div class="d-flex justify-content-end gap-2"><button class="btn btn-light" value="no" type="button" id="dlgNo">Cancel</button><button class="btn btn-primary" value="yes" id="dlgYes">Confirm</button></div></form>`;
    document.body.appendChild(d);
    const done = (v) => { d.close(); d.remove(); resolve(v); };
    d.querySelector("#dlgNo").onclick = () => done(withInput ? null : false);
    d.querySelector("form").onsubmit = (ev) => { ev.preventDefault(); const inp = d.querySelector("#dlgIn"); if (inp && !inp.value.trim()) return inp.focus(); done(withInput ? inp.value.trim() : true); };
    d.addEventListener("cancel", (ev) => { ev.preventDefault(); done(withInput ? null : false); });
    d.showModal();
    const f = d.querySelector("#dlgIn") || d.querySelector("#dlgYes"); f.focus();
  });
  const confirmAction = (text) => dialogBox(text, false);
  const askText = (text) => dialogBox(text, true);
  const empty = (icon, text) => `<div class="empty"><div class="icon"><i class="bi bi-${icon}"></i></div><div>${esc(text)}</div></div>`;

  // ------------------------------------------------------------- navigation
  const NAV = [
    { id: "dashboard",     icon: "speedometer2",     text: "Dashboard",     roles: "*" },
    { id: "enquiries",     icon: "inbox",            text: "Enquiries",     group: "admissions" },
    { id: "applications",  icon: "file-earmark-person", text: "Applications", group: "admissions" },
    { id: "approvals",     icon: "check2-square",    text: "Approvals",     group: "office", countKey: "approvals" },
    { id: "announcements", icon: "megaphone",        text: "Announcements", group: "office" },
    { id: "fees",          icon: "cash-coin",        text: "Fees & payments", group: "finance" },
    { id: "reminders",     icon: "bell",             text: "Fee reminders", group: "finance", countKey: "reminders" },
    { id: "myclass",       icon: "people",           text: "My class",      roles: ["teacher"] },
    { id: "tasks",         icon: "list-check",       text: "Tasks",         roles: "*" },
    { id: "school-settings",      icon: "gear",             text: "School settings", group: "leaders" }
  ];
  const allowed = (n) => n.roles === "*" || (n.roles && n.roles.includes(role())) || (n.group && can(role(), n.group));

  // ---------------------------------------------------------------- shells
  async function boot() {
    if (api.mode === "demo") document.getElementById("demoBanner").classList.remove("d-none");
    state.session = await api.getSession();
    if (!state.session) return renderLogin();
    const ms = await api.myMemberships();
    if (!ms.length) return renderNoAccess();
    state.membership = ms[0];
    if (api.setContext) api.setContext({ school_id: state.membership.school_id, role: state.membership.role_key });
    state.memberships = ms;
    renderShell();
  }

  function renderLogin() {
    const brand = `<a class="brand-mark mb-4" href="index.html"><span class="dot"><i class="bi bi-mortarboard-fill"></i></span><span>EduFlow AI<small>by YomieVerse</small></span></a>`;
    if (api.mode === "demo") {
      const roles = [
        ["school_admin", "School Administrator", "Wanjiru Kamau", "Everything: admissions, approvals, settings"],
        ["admissions_officer", "Admissions Officer", "James Otieno", "Enquiries, applications, parent replies"],
        ["bursar", "Bursar", "Mary Achieng", "Balances, payments, fee reminders"],
        ["head_teacher", "Head Teacher", "Peter Kamau", "Overview, decisions, approvals"],
        ["teacher", "Teacher (Grade 4)", "Tr. Chebet Njoroge", "Own class and tasks only"]
      ];
      root.innerHTML = `<div class="container py-5" style="max-width:880px">${brand}
        <h1 class="page-title mb-1">Try EduFlow AI</h1>
        <p class="text-soft mb-4">Pick a role to see what that person sees. Each role only gets the screens and data its job needs.</p>
        <div class="row g-3">${roles.map((r) => `
          <div class="col-md-6"><button class="feature-card w-100 text-start" data-role="${r[0]}">
            <div class="fw-bold">${r[1]}</div><div class="small text-soft">${r[2]}</div><div class="small mt-2">${r[3]}</div></button></div>`).join("")}
        </div></div>`;
      root.querySelectorAll("[data-role]").forEach((b) => b.onclick = async () => { await api.signIn(b.dataset.role); boot(); });
      return;
    }
    root.innerHTML = `<div class="container py-5" style="max-width:420px">${brand}
      <div class="card p-4"><h1 class="h4 fw-bold mb-3">Sign in</h1>
      <form id="loginForm"><div class="mb-3"><label class="form-label">Email</label><input class="form-control" type="email" name="email" required autocomplete="username"></div>
      <div class="mb-3"><label class="form-label">Password</label><input class="form-control" type="password" name="password" required autocomplete="current-password"></div>
      <button class="btn btn-primary w-100" type="submit">Sign in</button></form>
      <p class="small text-soft mt-3 mb-0">Accounts are created by your school administrator.</p></div></div>`;
    document.getElementById("loginForm").onsubmit = async (ev) => {
      ev.preventDefault(); const f = new FormData(ev.target);
      try { await api.signIn(f.get("email"), f.get("password")); boot(); } catch (e) { fail(e); }
    };
  }

  function renderNoAccess() {
    root.innerHTML = `<div class="container py-5" style="max-width:520px">${empty("shield-lock", "Your account is not linked to a school yet. Ask your school administrator to add you.")}
      <div class="text-center"><button class="btn btn-light" id="out">Sign out</button></div></div>`;
    document.getElementById("out").onclick = async () => { await api.signOut(); boot(); };
  }

  function renderShell() {
    const r = role();
    root.innerHTML = `<div class="app-shell">
      <aside class="sidebar">
        <a class="brand-mark mb-3 px-2 side-extra" href="index.html"><span class="dot"><i class="bi bi-mortarboard-fill"></i></span><span>EduFlow AI<small>${esc(state.membership.school_name || "")}</small></span></a>
        <nav class="nav flex-column gap-1" id="nav">${NAV.filter(allowed).map((n) => `
          <a href="#${n.id}" class="nav-link" data-view="${n.id}"><span><i class="bi bi-${n.icon} me-2"></i>${n.text}</span><span class="count d-none" data-count="${n.countKey || ""}"></span></a>`).join("")}
        </nav>
        <div class="side-extra mt-4 px-2 small text-soft">
          <div class="fw-semibold text-body">${esc(state.session.user.name || state.session.user.email)}</div>
          <div>${label(r)}</div>
          <button class="btn btn-sm btn-link px-0" id="signOut">${api.mode === "demo" ? "Switch role" : "Sign out"}</button>
        </div>
      </aside>
      <main class="main" id="main"></main></div>`;
    document.getElementById("signOut").onclick = async () => { await api.signOut(); boot(); };
    window.onhashchange = () => go(location.hash.slice(1) || "dashboard");
    go(location.hash.slice(1) || "dashboard");
  }

  async function refreshCounts() {
    try {
      const d = await api.dashboard();
      const set = (k, v) => { const el = document.querySelector(`[data-count="${k}"]`); if (el) { el.textContent = v; el.classList.toggle("d-none", !v); } };
      set("approvals", (can(role(), "office") ? d.messages_awaiting_approval : 0) + (can(role(), "leaders") ? d.announcements_awaiting_approval : 0));
      set("reminders", can(role(), "finance") ? d.reminders_awaiting_approval : 0);
    } catch (e) { /* counts are best-effort */ }
  }

  function go(view) {
    const n = NAV.find((x) => x.id === view);
    if (!n || !allowed(n)) view = "dashboard";
    state.view = view;
    document.querySelectorAll("#nav .nav-link").forEach((a) => a.classList.toggle("active", a.dataset.view === view));
    const main = document.getElementById("main");
    main.innerHTML = `<div class="text-soft py-5 text-center">Loading…</div>`;
    VIEWS[view](main).catch((e) => { fail(e); main.innerHTML = empty("exclamation-triangle", e.userMessage || "Could not load this page."); });
    refreshCounts();
  }
  const header = (title, sub, actions) => `<div class="d-flex flex-wrap justify-content-between align-items-end gap-2 mb-4">
    <div><h1 class="page-title h3">${title}</h1>${sub ? `<div class="text-soft">${sub}</div>` : ""}</div><div class="d-flex gap-2">${actions || ""}</div></div>`;
  const kpi = (lbl, val, hint, alert) => `<div class="col-6 col-lg-3"><div class="kpi ${alert ? "alert-kpi" : ""}"><div class="label">${lbl}</div><div class="value">${val}</div><div class="hint">${hint || "&nbsp;"}</div></div></div>`;

  // ================================================================= VIEWS
  const VIEWS = {};

  VIEWS.dashboard = async (main) => {
    const r = role(), d = await api.dashboard();
    const greet = `Good ${new Date().getHours() < 12 ? "morning" : new Date().getHours() < 17 ? "afternoon" : "evening"}, ${esc((state.session.user.name || "").split(" ")[0] || "there")}`;
    let html = header(greet, `${esc(state.membership.school_name)} · ${new Date().toLocaleDateString("en-KE", { weekday: "long", day: "numeric", month: "long" })}`);

    if (r === "teacher") {
      const [{ cls, students }, tasks, events] = await Promise.all([api.listMyClassStudents(), api.listTasks(), api.listEvents()]);
      html += `<div class="row g-3 mb-4">${kpi("My class", esc(cls ? cls.name : "—"), `${students.length} learners`)}${kpi("My open tasks", tasks.filter((t) => t.status !== "done").length)}</div>
        <div class="row g-3"><div class="col-lg-6">${eventsCard(events)}</div><div class="col-lg-6">${tasksCard(tasks)}</div></div>
        <p class="small text-soft mt-3"><i class="bi bi-info-circle"></i> Attendance registers arrive in Phase 5. Teachers only see their own class; fees and admissions are hidden for this role.</p>`;
      main.innerHTML = html; return;
    }

    const cards = [];
    if (can(r, "admissions")) cards.push(kpi("New enquiries", d.open_enquiries, `${d.enquiries_7d} in the last 7 days`), kpi("Follow-ups overdue", d.overdue_follow_ups, "Reply promised within 24 h", d.overdue_follow_ups > 0),
                                         kpi("Applications in progress", d.pending_applications, `${d.incomplete_applications} missing documents`));
    if (can(r, "finance")) cards.push(kpi("Overdue fee balances", kes(d.overdue_fees), "Past due date, Term 3", d.overdue_fees > 0),
                                      kpi("Collected this term", kes(d.collected_fees), d.expected_fees ? `${Math.round(100 * d.collected_fees / d.expected_fees)}% of ${kes(d.expected_fees)}` : ""));
    if (can(r, "leaders")) cards.push(kpi("Enrolled learners", d.enrolled_students, "Active this term"));
    cards.push(kpi("Waiting for your approval", (can(r, "office") ? d.messages_awaiting_approval : 0) + (can(r, "leaders") ? d.announcements_awaiting_approval : 0) + (can(r, "fin_write") ? d.reminders_awaiting_approval : 0), "Nothing AI-written is sent without approval"));
    html += `<div class="row g-3 mb-4">${cards.join("")}</div>`;

    const [tasks, events] = await Promise.all([api.listTasks(), api.listEvents()]);
    let left = "";
    if (can(r, "admissions")) {
      const enq = (await api.listEnquiries()).filter((e) => ["new", "acknowledged"].includes(e.status)).slice(0, 6);
      left = `<div class="table-card mb-3"><div class="d-flex justify-content-between p-3 pb-2"><h2 class="h6 fw-bold m-0">Recent enquiries</h2><a href="#enquiries" class="small">View all</a></div>
        ${enq.length ? `<table class="table table-hover align-middle"><tbody>${enq.map((e) => `<tr class="row-click" data-enq="${e.id}">
          <td><div class="fw-semibold">${esc(e.parent_name)} ${e.needs_human ? '<span class="human-chip ms-1">Needs a person</span>' : ""}</div><div class="small text-soft">${esc(e.ai_summary || e.message || "")}</div></td>
          <td class="text-nowrap">${badge(e.urgency)}</td><td class="small text-soft text-nowrap">${when(e.created_at)}</td></tr>`).join("")}</tbody></table>` : empty("inbox", "No new enquiries.")}</div>`;
    } else if (can(r, "finance")) {
      const bal = (await api.listFeeBalances()).filter((b) => b.balance > 0).slice(0, 6);
      left = `<div class="table-card mb-3"><div class="d-flex justify-content-between p-3 pb-2"><h2 class="h6 fw-bold m-0">Largest outstanding balances</h2><a href="#fees" class="small">View all</a></div>
        <table class="table align-middle"><tbody>${bal.map((b) => `<tr><td><div class="fw-semibold">${esc(b.student)}</div><div class="small text-soft">${esc(b.grade)} · ${esc(b.admission_number)}</div></td>
        <td class="text-end fw-semibold">${kes(b.balance)}</td><td>${b.pending > 0 ? badge("pending") : ""}</td></tr>`).join("")}</tbody></table></div>`;
    }
    const auto = (d.automation || []).length && can(r, "leaders") ? `<div class="table-card"><div class="p-3 pb-2"><h2 class="h6 fw-bold m-0">Automation activity</h2></div>
        <table class="table align-middle small"><tbody>${d.automation.map((a) => `<tr><td>${badge(a.status)}</td><td>${esc(a.message)}<div class="text-soft">${esc(a.scenario)}</div></td><td class="text-soft text-nowrap">${when(a.created_at)}</td></tr>`).join("")}</tbody></table></div>` : "";
    html += `<div class="row g-3"><div class="col-lg-7">${left}${auto}</div><div class="col-lg-5">${eventsCard(events)}<div class="mt-3">${tasksCard(tasks.filter((t) => t.status !== "done").slice(0, 6))}</div></div></div>`;
    main.innerHTML = html;
    main.querySelectorAll("[data-enq]").forEach((tr) => tr.onclick = () => openEnquiry(tr.dataset.enq));
    bindTaskChecks(main);
  };

  const eventsCard = (events) => `<div class="table-card"><div class="p-3 pb-2"><h2 class="h6 fw-bold m-0">Upcoming events</h2></div>
    ${events.length ? `<table class="table align-middle small"><tbody>${events.slice(0, 5).map((e) => `<tr><td class="text-nowrap fw-semibold">${new Date(e.starts_at).toLocaleDateString("en-KE", { day: "numeric", month: "short" })}</td><td>${esc(e.title)}<div class="text-soft">${esc(e.location || "")}</div></td></tr>`).join("")}</tbody></table>` : empty("calendar", "No upcoming events.")}</div>`;
  const tasksCard = (tasks) => `<div class="table-card"><div class="d-flex justify-content-between p-3 pb-2"><h2 class="h6 fw-bold m-0">My tasks</h2><a href="#tasks" class="small">All tasks</a></div>
    ${tasks.length ? `<ul class="list-group list-group-flush">${tasks.map((t) => `<li class="list-group-item d-flex gap-2 align-items-start">
      <input class="form-check-input mt-1" type="checkbox" data-task="${t.id}" ${t.status === "done" ? "checked" : ""} aria-label="Mark done">
      <div class="flex-fill"><div class="${t.status === "done" ? "text-decoration-line-through text-soft" : ""}">${esc(t.title)}</div>
      <div class="small text-soft">Due ${when(t.due_at)} ${t.priority === "high" ? badge("high") : ""}</div></div></li>`).join("")}</ul>` : empty("check2-circle", "Nothing pending.")}</div>`;
  const bindTaskChecks = (el) => el.querySelectorAll("[data-task]").forEach((cb) => cb.onchange = async () => {
    try { await api.updateTask(cb.dataset.task, { status: cb.checked ? "done" : "open", completed_at: cb.checked ? new Date().toISOString() : null }); toast(cb.checked ? "Task done" : "Task reopened"); go(state.view); } catch (e) { fail(e); }
  });

  // ------------------------------------------------------------ enquiries
  VIEWS.enquiries = async (main) => {
    const rows = await api.listEnquiries();
    const filter = state.cache.enqFilter || "open";
    const shown = rows.filter((e) => filter === "all" ? true : filter === "open" ? ["new", "acknowledged", "in_progress"].includes(e.status) : e.status === filter);
    main.innerHTML = header("Admissions enquiries", "Every enquiry from the form, email, phone and walk-ins in one list. The AI sorts and summarises; you reply.") +
      `<div class="d-flex gap-2 mb-3 flex-wrap">${["open", "new", "converted", "closed", "all"].map((f) => `<button class="btn btn-sm ${f === filter ? "btn-primary" : "btn-light"}" data-f="${f}">${label(f)}</button>`).join("")}</div>
      <div class="table-card">${shown.length ? `<div class="table-responsive"><table class="table table-hover align-middle"><thead><tr><th>Ref</th><th>Parent & learner</th><th>Topic</th><th>Urgency</th><th>Status</th><th>Follow-up</th><th>Received</th></tr></thead><tbody>
      ${shown.map((e) => { const overdue = e.follow_up_due_at && Date.parse(e.follow_up_due_at) < Date.now() && ["new", "acknowledged", "in_progress"].includes(e.status);
        return `<tr class="row-click" data-enq="${e.id}"><td class="small text-nowrap">${esc(e.reference)}</td>
        <td><div class="fw-semibold">${esc(e.parent_name)} ${e.needs_human ? '<span class="human-chip ms-1">Needs a person</span>' : ""}</div><div class="small text-soft">${esc(e.learner_first_name || "")}${e.grade_sought ? " · " + esc(e.grade_sought) : ""}${e.intake ? " · " + esc(e.intake) : ""}</div></td>
        <td>${label(e.category)}</td><td>${badge(e.urgency)}</td><td>${badge(e.status)}</td>
        <td class="small ${overdue ? "text-danger fw-semibold" : "text-soft"}">${e.follow_up_due_at && e.status !== "converted" && e.status !== "closed" ? (overdue ? "Overdue" : "Due " + when(e.follow_up_due_at).replace(" ago", "")) : "—"}</td>
        <td class="small text-soft text-nowrap">${when(e.created_at)}</td></tr>`; }).join("")}</tbody></table></div>` : empty("inbox", "No enquiries in this view.")}</div>
      <p class="small text-soft mt-3">Public form link for parents: <code>enquiry.html?school=${esc(state.school_slug || "mwangaza-junior")}</code></p>`;
    main.querySelectorAll("[data-f]").forEach((b) => b.onclick = () => { state.cache.enqFilter = b.dataset.f; go("enquiries"); });
    main.querySelectorAll("[data-enq]").forEach((tr) => tr.onclick = () => openEnquiry(tr.dataset.enq));
  };

  async function openEnquiry(id) {
    const e = (await api.listEnquiries()).find((x) => x.id === id);
    if (!e) return;
    openModal(`${esc(e.parent_name)} <span class="small text-soft ms-2">${esc(e.reference)}</span>`, `
      ${e.needs_human ? `<div class="alert alert-danger py-2 small"><i class="bi bi-person-exclamation"></i> The AI marked this as sensitive or uncertain. Please reply personally; no AI draft is offered.</div>` : ""}
      <div class="row g-3 small mb-3">
        <div class="col-md-4"><div class="text-soft">Contact</div>${esc(e.parent_phone || "")}<br>${esc(e.parent_email || "")}</div>
        <div class="col-md-4"><div class="text-soft">Learner</div>${esc(e.learner_first_name || "—")}${e.learner_age ? ", age " + esc(e.learner_age) : ""}<br>${esc(e.grade_sought || "")} ${esc(e.intake || "")}</div>
        <div class="col-md-4"><div class="text-soft">Source · consent</div>${label(e.source)} · ${e.consent_given ? "Given" : "<span class='text-danger'>Missing</span>"}</div></div>
      <div class="mb-3"><div class="small text-soft mb-1">Parent's message</div><div class="draft-box">${esc(e.message || "")}</div></div>
      ${e.ai_summary ? `<div class="mb-3"><span class="ai-chip">AI summary</span> <span class="small">${esc(e.ai_summary)}</span> <span class="small text-soft">· ${label(e.category)} · ${label(e.urgency)} urgency</span></div>` : ""}
      <div class="row g-2 align-items-end"><div class="col-sm-6"><label class="form-label small">Status</label>
        <select class="form-select" id="enqStatus">${["new", "acknowledged", "in_progress", "converted", "closed", "spam"].map((s) => `<option value="${s}" ${s === e.status ? "selected" : ""}>${label(s)}</option>`).join("")}</select></div>
        <div class="col-sm-6"><label class="form-label small">Category (correct the AI if needed)</label>
        <select class="form-select" id="enqCat">${["fees", "availability", "transport", "tour_request", "curriculum", "admission_process", "boarding_meals", "other", "unclassified"].map((s) => `<option value="${s}" ${s === e.category ? "selected" : ""}>${label(s)}</option>`).join("")}</select></div></div>
      <div id="draftArea" class="mt-3"></div>`,
      `${!e.needs_human ? `<button class="btn btn-outline-primary me-auto" id="aiReply"><i class="bi bi-stars"></i> Draft reply with AI</button>` : `<button class="btn btn-outline-primary me-auto" id="ownReply"><i class="bi bi-pencil"></i> Write reply</button>`}
       <button class="btn btn-light" data-bs-dismiss="modal">Close</button><button class="btn btn-primary" id="saveEnq">Save</button>`);
    document.getElementById("saveEnq").onclick = async () => {
      try { await api.updateEnquiry(id, { status: document.getElementById("enqStatus").value, category: document.getElementById("enqCat").value }); modal.hide(); toast("Enquiry updated"); go(state.view); } catch (err) { fail(err); }
    };
    const showDraft = (text, note) => {
      document.getElementById("draftArea").innerHTML = `<label class="form-label small fw-semibold">Reply to ${esc(e.parent_email ? "email " + e.parent_email : "SMS " + (e.parent_phone || ""))}</label>
        <textarea class="form-control" id="replyText" rows="6">${esc(text)}</textarea>${note ? `<div class="small text-soft mt-1"><span class="ai-chip">AI</span> ${esc(note)}</div>` : ""}
        <button class="btn btn-primary btn-sm mt-2" id="queueReply">Send for approval</button>`;
      document.getElementById("queueReply").onclick = async () => {
        try {
          await api.createDraftMessage({ channel: e.parent_email ? "email" : "sms", recipient: e.parent_email || e.parent_phone, subject: `Your enquiry ${e.reference}`,
            body: document.getElementById("replyText").value, related_type: "enquiry", related_id: e.id, ai_generated: !!note, requires_approval: true });
          await api.updateEnquiry(id, { status: e.status === "new" ? "in_progress" : e.status });
          modal.hide(); toast("Reply added to Approvals"); go(state.view);
        } catch (err) { fail(err); }
      };
    };
    const ai = document.getElementById("aiReply");
    if (ai) ai.onclick = async () => { ai.disabled = true; ai.innerHTML = "Drafting…"; try { const r = await api.aiDraft("enquiry_reply", e); showDraft(r.draft, r.note || "AI draft. Check every fact before approving."); } catch (err) { fail(err); } ai.disabled = false; ai.innerHTML = '<i class="bi bi-stars"></i> Draft reply with AI'; };
    const own = document.getElementById("ownReply");
    if (own) own.onclick = () => showDraft(`Dear ${e.parent_name.split(" ")[0]},\n\n`, "");
  }

  // --------------------------------------------------------- applications
  const APP_FLOW = ["submitted", "incomplete", "complete", "under_review", "assessment", "offered", "waitlisted", "declined", "enrolled", "withdrawn"];
  VIEWS.applications = async (main) => {
    const rows = await api.listApplications();
    const counts = {}; rows.forEach((a) => counts[a.status] = (counts[a.status] || 0) + 1);
    main.innerHTML = header("Applications", "Track every application from submission to enrolment. Decisions are always made by authorised staff.") +
      `<div class="row g-3 mb-3">${["incomplete", "complete", "under_review", "assessment"].map((s) => kpi(label(s), counts[s] || 0)).join("")}</div>
      <div class="table-card">${rows.length ? `<div class="table-responsive"><table class="table table-hover align-middle"><thead><tr><th>Ref</th><th>Learner</th><th>Grade</th><th>Parent</th><th>Documents</th><th>Status</th><th>Received</th></tr></thead><tbody>
      ${rows.map((a) => `<tr class="row-click" data-app="${a.id}"><td class="small">${esc(a.reference)}</td><td class="fw-semibold">${esc(a.learner_first_name)} ${esc(a.learner_last_name)}</td>
        <td>${esc(a.grade_applied)}</td><td class="small">${esc(a.parent_name)}</td>
        <td class="small">${(a.missing_documents || []).length ? `<span class="text-danger">${a.missing_documents.length} missing</span>` : '<span class="text-success">Complete</span>'}</td>
        <td>${badge(a.status)}</td><td class="small text-soft">${when(a.created_at)}</td></tr>`).join("")}</tbody></table></div>` : empty("file-earmark", "No applications yet.")}</div>
      <p class="small text-soft mt-3">Public application link: <code>apply.html?school=mwangaza-junior</code></p>`;
    main.querySelectorAll("[data-app]").forEach((tr) => tr.onclick = () => openApplication(tr.dataset.app));
  };

  async function openApplication(id) {
    const a = (await api.listApplications()).find((x) => x.id === id);
    const docs = await api.getApplicationDocuments(id);
    const next = APP_FLOW.filter((s) => s !== a.status && !["submitted", "incomplete", "complete"].includes(s));
    openModal(`${esc(a.learner_first_name)} ${esc(a.learner_last_name)} <span class="small text-soft ms-2">${esc(a.reference)} · ${badge(a.status)}</span>`, `
      <div class="row g-3 small mb-3">
        <div class="col-md-4"><div class="text-soft">Grade · intake</div>${esc(a.grade_applied)} · ${esc(a.intake || "")}</div>
        <div class="col-md-4"><div class="text-soft">Parent</div>${esc(a.parent_name)}<br>${esc(a.parent_phone || "")} ${esc(a.parent_email || "")}</div>
        <div class="col-md-4"><div class="text-soft">Previous school</div>${esc(a.previous_school || "—")}</div></div>
      <h3 class="h6 fw-bold">Documents</h3>
      ${(a.missing_documents || []).length ? `<div class="alert alert-warning py-2 small">Missing: ${a.missing_documents.map(label).join(", ")}
        <button class="btn btn-sm btn-outline-dark ms-2" id="askDocs">Draft a request to the parent</button></div>` : ""}
      ${docs.length ? `<table class="table table-sm align-middle"><tbody>${docs.map((d) => `<tr><td>${label(d.document_type)}<div class="small text-soft">${esc(d.file_name || "")}</div></td>
        <td>${badge(d.verification_status === "verified" ? "complete" : d.verification_status === "rejected" ? "rejected" : "pending")}</td>
        <td class="text-end text-nowrap">${d.storage_path ? `<button class="btn btn-sm btn-light" data-view-doc="${esc(d.storage_path)}">View</button>` : ""}
        <button class="btn btn-sm btn-light" data-verify="${d.id}" data-s="verified">Verify</button><button class="btn btn-sm btn-light" data-verify="${d.id}" data-s="rejected">Reject</button></td></tr>`).join("")}</tbody></table>`
        : `<p class="small text-soft">No documents uploaded yet.</p>`}
      <h3 class="h6 fw-bold mt-3">Move this application</h3>
      <div class="row g-2"><div class="col-sm-5"><select class="form-select" id="appNext">${next.map((s) => `<option value="${s}">${label(s)}${DECISIONS.includes(s) ? " (decision)" : ""}</option>`).join("")}</select></div>
      <div class="col-sm-7"><input class="form-control" id="appNotes" placeholder="Notes (kept on record)"></div></div>
      ${a.decided_by ? `<p class="small text-soft mt-2">Last decision by ${esc(a.decided_by)} on ${dateTime(a.decided_at)}</p>` : ""}
      <p class="small text-soft mt-2 mb-0"><i class="bi bi-shield-check"></i> Offer, waitlist, decline and enrol are recorded with your name. Automations and AI cannot make these decisions.</p>`,
      `<button class="btn btn-light" data-bs-dismiss="modal">Close</button><button class="btn btn-primary" id="appMove">Update status</button>`);
    document.getElementById("appMove").onclick = async () => {
      const s = document.getElementById("appNext").value;
      if (DECISIONS.includes(s) && !(await confirmAction(`Confirm admission decision: ${label(s)} for ${a.learner_first_name} ${a.learner_last_name}? This is recorded in the audit log.`))) return;
      try { await api.setApplicationStatus(id, s, document.getElementById("appNotes").value); modal.hide(); toast("Application updated"); go("applications"); } catch (e) { fail(e); }
    };
    document.querySelectorAll("[data-verify]").forEach((b) => b.onclick = async () => { try { await api.verifyDocument(b.dataset.verify, b.dataset.s); toast("Document " + b.dataset.s); openApplication(id); } catch (e) { fail(e); } });
    document.querySelectorAll("[data-view-doc]").forEach((b) => b.onclick = async () => { try { const u = await api.documentUrl(b.dataset.viewDoc); if (u) window.open(u, "_blank", "noopener"); else toast("Demo documents have no file attached", "info"); } catch (e) { fail(e); } });
    const ask = document.getElementById("askDocs");
    if (ask) ask.onclick = async () => {
      const body = `Dear ${a.parent_name.split(" ")[0]}, thank you for applying to ${state.membership.school_name} for ${a.learner_first_name}. To complete the application we still need: ${a.missing_documents.map((x) => label(x).toLowerCase()).join(", ")}. You can upload them using the link in your confirmation message. Kind regards, Admissions Office.`;
      try { await api.createDraftMessage({ channel: a.parent_email ? "email" : "sms", recipient: a.parent_email || a.parent_phone, subject: `Application ${a.reference}: documents needed`, body, related_type: "application", related_id: a.id, ai_generated: false, requires_approval: true, template_key: "missing_documents" });
        modal.hide(); toast("Request added to Approvals"); } catch (e) { fail(e); }
    };
  }

  // ------------------------------------------------------------ approvals
  VIEWS.approvals = async (main) => {
    const msgs = await api.listMessages("draft");
    const anns = can(role(), "leaders") ? (await api.listAnnouncements()).filter((a) => a.status === "pending_approval") : [];
    main.innerHTML = header("Approvals", "Nothing written by the AI reaches a parent until someone here approves it. Edit freely before approving.") +
      `<h2 class="h6 fw-bold mb-2">Parent replies (${msgs.length})</h2>
      ${msgs.length ? msgs.map((m) => `<div class="card p-3 mb-3"><div class="d-flex justify-content-between flex-wrap gap-2 mb-2">
        <div><span class="fw-semibold">${esc(m.subject || label(m.related_type))}</span> ${m.ai_generated ? '<span class="ai-chip ms-1">AI draft</span>' : ""}<div class="small text-soft">${label(m.channel)} to ${esc(m.recipient || "")} · ${when(m.created_at)}</div></div></div>
        <textarea class="form-control mb-2" rows="4" data-body="${m.id}">${esc(m.body)}</textarea>
        <div class="d-flex gap-2 justify-content-end"><button class="btn btn-sm btn-light" data-reject="${m.id}">Reject</button><button class="btn btn-sm btn-primary" data-approve="${m.id}"><i class="bi bi-send"></i> Approve & send</button></div></div>`).join("")
        : `<div class="table-card mb-4">${empty("check2-all", "No replies waiting. You're up to date.")}</div>`}
      ${can(role(), "leaders") ? `<h2 class="h6 fw-bold mt-4 mb-2">Announcements (${anns.length})</h2>
      ${anns.length ? anns.map((a) => `<div class="card p-3 mb-3"><div class="fw-semibold">${esc(a.title)} ${a.ai_assisted ? '<span class="ai-chip ms-1">AI-assisted</span>' : ""}</div>
        <div class="small text-soft mb-2">${label(a.audience)}${a.grade ? " · " + esc(a.grade) : ""} · ${(a.channels || []).map(label).join(", ")}</div><div class="draft-box mb-2">${esc(a.body)}</div>
        <div class="d-flex gap-2 justify-content-end"><a class="btn btn-sm btn-light" href="#announcements">Edit</a><button class="btn btn-sm btn-primary" data-ann="${a.id}">Approve & send</button></div></div>`).join("")
        : `<div class="table-card">${empty("megaphone", "No announcements waiting.")}</div>`}` : ""}`;
    main.querySelectorAll("[data-approve]").forEach((b) => b.onclick = async () => {
      try { await api.approveMessage(b.dataset.approve, main.querySelector(`[data-body="${b.dataset.approve}"]`).value); toast("Approved. It will be sent within a few minutes."); go("approvals"); } catch (e) { fail(e); }
    });
    main.querySelectorAll("[data-reject]").forEach((b) => b.onclick = async () => { try { await api.rejectMessage(b.dataset.reject); toast("Draft rejected", "info"); go("approvals"); } catch (e) { fail(e); } });
    main.querySelectorAll("[data-ann]").forEach((b) => b.onclick = async () => {
      if (!(await confirmAction("Approve and send this announcement to every recipient in its audience?"))) return;
      try { const r = await api.saveAnnouncement({ id: b.dataset.ann, status: "approved" }); toast(`Approved. Sending to ${r.recipient_count || "the audience"}.`); go("approvals"); } catch (e) { fail(e); }
    });
  };

  // -------------------------------------------------------- announcements
  VIEWS.announcements = async (main) => {
    const [rows, classes] = await Promise.all([api.listAnnouncements(), api.listClasses()]);
    const grades = [...new Set(classes.map((c) => c.grade))];
    main.innerHTML = header("Announcements", "Write once, send to the whole school, a grade or a class.", `<button class="btn btn-primary" id="newAnn"><i class="bi bi-plus-lg"></i> New announcement</button>`) +
      `<div class="table-card">${rows.length ? `<table class="table table-hover align-middle"><thead><tr><th>Title</th><th>Audience</th><th>Channels</th><th>Status</th><th>Updated</th></tr></thead><tbody>
      ${rows.map((a) => `<tr class="row-click" data-ann="${a.id}"><td class="fw-semibold">${esc(a.title)} ${a.ai_assisted ? '<span class="ai-chip ms-1">AI</span>' : ""}</td><td>${label(a.audience)}${a.grade ? " · " + esc(a.grade) : ""}</td>
        <td class="small">${(a.channels || []).map(label).join(", ")}</td><td>${badge(a.status)}</td><td class="small text-soft">${when(a.sent_at || a.created_at)}</td></tr>`).join("")}</tbody></table>` : empty("megaphone", "No announcements yet.")}</div>`;
    const editor = (a) => {
      a = a || { audience: "whole_school", channels: ["sms"], status: "draft" };
      const locked = ["approved", "sent"].includes(a.status);
      openModal(a.id ? "Edit announcement" : "New announcement", `
        <div class="mb-2"><label class="form-label small">Title</label><input class="form-control" id="aTitle" value="${esc(a.title || "")}" ${locked ? "disabled" : ""}></div>
        <div class="row g-2 mb-2"><div class="col-sm-6"><label class="form-label small">Audience</label><select class="form-select" id="aAud" ${locked ? "disabled" : ""}>
          ${["whole_school", "grade", "staff"].map((x) => `<option value="${x}" ${x === a.audience ? "selected" : ""}>${label(x)}</option>`).join("")}</select></div>
          <div class="col-sm-6"><label class="form-label small">Grade</label><select class="form-select" id="aGrade" ${locked ? "disabled" : ""}><option value="">—</option>${grades.map((g) => `<option ${g === a.grade ? "selected" : ""}>${esc(g)}</option>`).join("")}</select></div></div>
        <div class="mb-2"><label class="form-label small">Channels</label><div>${["sms", "email"].map((c) => `<label class="form-check form-check-inline"><input class="form-check-input" type="checkbox" value="${c}" data-ch ${(a.channels || []).includes(c) ? "checked" : ""} ${locked ? "disabled" : ""}> ${label(c)}</label>`).join("")}</div></div>
        <div class="mb-2"><label class="form-label small d-flex justify-content-between">Message ${!locked ? `<button type="button" class="btn btn-link btn-sm p-0" id="aAi"><i class="bi bi-stars"></i> Help me write it</button>` : ""}</label>
          <textarea class="form-control" id="aBody" rows="7" ${locked ? "disabled" : ""}>${esc(a.body || "")}</textarea><div class="small text-soft mt-1" id="aCount"></div></div>`,
        locked ? `<button class="btn btn-light" data-bs-dismiss="modal">Close</button>` :
        `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-outline-primary" id="aSave">Save draft</button>
         ${can(role(), "leaders") ? `<button class="btn btn-primary" id="aApprove">Approve & send</button>` : `<button class="btn btn-primary" id="aSubmit">Submit for approval</button>`}`);
      const body = document.getElementById("aBody"), cnt = document.getElementById("aCount");
      const upd = () => { const l = body.value.length; cnt.textContent = `${l} characters · about ${Math.max(1, Math.ceil(l / 153))} SMS per parent`; };
      body.oninput = upd; upd();
      const collect = (status) => ({ id: a.id, title: document.getElementById("aTitle").value.trim(), body: body.value.trim(), audience: document.getElementById("aAud").value,
        grade: document.getElementById("aGrade").value || null, channels: [...document.querySelectorAll("[data-ch]:checked")].map((x) => x.value), status, ai_assisted: !!a.ai_assisted });
      const save = async (status, msg) => {
        const v = collect(status);
        if (!v.title || !v.body) return toast("Add a title and message", "error");
        if (v.audience === "grade" && !v.grade) return toast("Choose the grade", "error");
        if (!v.channels.length) return toast("Choose at least one channel", "error");
        if (status === "approved" && !(await confirmAction("Approve and send now?"))) return;
        try { await api.saveAnnouncement(v); modal.hide(); toast(msg); go("announcements"); } catch (e) { fail(e); }
      };
      if (!locked) {
        document.getElementById("aSave").onclick = () => save("draft", "Draft saved");
        const sub = document.getElementById("aSubmit"); if (sub) sub.onclick = () => save("pending_approval", "Sent to the administrator for approval");
        const ap = document.getElementById("aApprove"); if (ap) ap.onclick = () => save("approved", "Approved. Sending now.");
        document.getElementById("aAi").onclick = async () => {
          const topic = body.value.trim() || document.getElementById("aTitle").value.trim();
          if (!topic) return toast("Type a few words about the announcement first", "error");
          try { const r = await api.aiDraft("announcement", { topic, audience: document.getElementById("aAud").value }); body.value = r.draft; a.ai_assisted = true; upd(); toast("AI draft added. Check dates and times.", "info"); } catch (e) { fail(e); }
        };
      }
    };
    document.getElementById("newAnn").onclick = () => editor();
    main.querySelectorAll("[data-ann]").forEach((tr) => tr.onclick = () => editor(rows.find((x) => x.id === tr.dataset.ann)));
  };

  // ------------------------------------------------------------------ fees
  VIEWS.fees = async (main) => {
    const [bal, pays] = await Promise.all([api.listFeeBalances(), api.listPayments()]);
    const term = state.cache.feeSearch || "";
    const shown = bal.filter((b) => !term || `${b.student} ${b.admission_number} ${b.grade}`.toLowerCase().includes(term.toLowerCase()));
    const owing = bal.filter((b) => b.balance > 0);
    const pending = pays.filter((p) => p.status === "pending");
    const write = can(role(), "fin_write");
    main.innerHTML = header("Fees & payments", "Balances are calculated from confirmed payments only. Confirmed payments are never edited; they are reversed with a reason.",
        write ? `<button class="btn btn-primary" id="recPay"><i class="bi bi-plus-lg"></i> Record payment</button>` : "") +
      `<div class="row g-3 mb-4">${kpi("Expected (Term 3)", kes(bal.reduce((s, b) => s + b.amount_billed - b.discount, 0)))}${kpi("Collected", kes(bal.reduce((s, b) => s + b.paid, 0)))}
        ${kpi("Outstanding", kes(owing.reduce((s, b) => s + b.balance, 0)), `${owing.length} learners`, true)}${kpi("Payments to confirm", pending.length, "M-Pesa / imports awaiting the bursar")}</div>
      ${pending.length ? `<div class="table-card mb-4"><div class="p-3 pb-2"><h2 class="h6 fw-bold m-0">Payments awaiting confirmation</h2></div><table class="table align-middle"><tbody>
        ${pending.map((p) => `<tr><td class="fw-semibold">${esc(p.student)}</td><td>${kes(p.amount)}</td><td class="small">${label(p.method)} ${esc(p.reference || "")}</td><td class="small text-soft">${label(p.source)} · ${when(p.paid_at)}</td>
        <td class="text-end">${write ? `<button class="btn btn-sm btn-primary" data-confirm="${p.id}">Confirm</button>` : ""}</td></tr>`).join("")}</tbody></table></div>` : ""}
      <div class="d-flex justify-content-between align-items-center mb-2"><h2 class="h6 fw-bold m-0">Learner balances</h2><input class="form-control form-control-sm" style="max-width:240px" id="feeSearch" placeholder="Search name, adm. no., grade" value="${esc(term)}"></div>
      <div class="table-card mb-4"><div class="table-responsive"><table class="table align-middle"><thead><tr><th>Learner</th><th>Grade</th><th class="text-end">Billed</th><th class="text-end">Paid</th><th class="text-end">Balance</th><th></th></tr></thead><tbody>
        ${shown.map((b) => `<tr><td><div class="fw-semibold">${esc(b.student)}</div><div class="small text-soft">${esc(b.admission_number || "")}</div></td><td>${esc(b.grade || "")}</td>
          <td class="text-end">${kes(b.amount_billed - b.discount)}</td><td class="text-end">${kes(b.paid)}</td>
          <td class="text-end fw-semibold ${b.balance > 0 ? "text-danger" : "text-success"}">${kes(b.balance)}</td>
          <td class="small">${b.pending > 0 ? badge("pending") : ""} ${b.reminders_paused ? '<span class="badge-status st-closed">Plan agreed</span>' : ""}</td></tr>`).join("")}</tbody></table></div></div>
      <h2 class="h6 fw-bold mb-2">Recent payments</h2>
      <div class="table-card"><table class="table align-middle small"><thead><tr><th>Learner</th><th>Amount</th><th>Method</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
        ${pays.slice(0, 25).map((p) => `<tr><td>${esc(p.student)}</td><td>${kes(p.amount)}</td><td>${label(p.method)} ${esc(p.reference || "")}</td><td>${badge(p.status)}</td><td class="text-soft">${when(p.paid_at)}</td>
        <td class="text-end">${write && p.status === "confirmed" ? `<button class="btn btn-sm btn-light" data-reverse="${p.id}">Reverse</button>` : ""}</td></tr>`).join("")}</tbody></table></div>`;
    const s = document.getElementById("feeSearch");
    s.oninput = () => { state.cache.feeSearch = s.value; clearTimeout(state.t); state.t = setTimeout(() => { go("fees"); setTimeout(() => { const n = document.getElementById("feeSearch"); n.focus(); n.setSelectionRange(n.value.length, n.value.length); }, 30); }, 350); };
    main.querySelectorAll("[data-confirm]").forEach((b) => b.onclick = async () => { if (!(await confirmAction("Confirm this payment? It will reduce the learner's balance and can then only be reversed."))) return; try { await api.confirmPayment(b.dataset.confirm); toast("Payment confirmed"); go("fees"); } catch (e) { fail(e); } });
    main.querySelectorAll("[data-reverse]").forEach((b) => b.onclick = async () => { const reason = await askText("Reason for reversing this payment (kept on record):"); if (!reason) return; try { await api.reversePayment(b.dataset.reverse, reason); toast("Payment reversed"); go("fees"); } catch (e) { fail(e); } });
    const rp = document.getElementById("recPay");
    if (rp) rp.onclick = () => {
      openModal("Record a payment", `<div class="mb-2"><label class="form-label small">Learner</label><select class="form-select" id="pAcct">${bal.map((b) => `<option value="${b.fee_account_id}">${esc(b.student)} · ${esc(b.admission_number || "")} · balance ${kes(b.balance)}</option>`).join("")}</select></div>
        <div class="row g-2"><div class="col-sm-4"><label class="form-label small">Amount (KES)</label><input class="form-control" type="number" min="1" step="1" id="pAmt"></div>
        <div class="col-sm-4"><label class="form-label small">Method</label><select class="form-select" id="pMethod">${["mpesa", "bank", "cash", "cheque", "other"].map((m) => `<option value="${m}">${label(m)}</option>`).join("")}</select></div>
        <div class="col-sm-4"><label class="form-label small">Reference</label><input class="form-control" id="pRef" placeholder="M-Pesa code"></div></div>
        <p class="small text-soft mt-2 mb-0">Recorded as confirmed under your name. Duplicate references are refused.</p>`,
        `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="pSave">Record payment</button>`);
      document.getElementById("pSave").onclick = async () => {
        const amount = Number(document.getElementById("pAmt").value);
        try { await api.recordPayment({ fee_account_id: document.getElementById("pAcct").value, amount, method: document.getElementById("pMethod").value, reference: document.getElementById("pRef").value.trim().toUpperCase() || null, paid_at: new Date().toISOString() });
          modal.hide(); toast("Payment recorded"); go("fees"); } catch (e) { fail(e); }
      };
    };
  };

  // ------------------------------------------------------------- reminders
  VIEWS.reminders = async (main) => {
    const rows = await api.listReminders();
    const drafts = rows.filter((r) => r.status === "draft");
    const write = can(role(), "fin_write");
    main.innerHTML = header("Fee reminders", "Build a batch from your school's rules, check it, then approve. Balances come from the records, never from the AI.",
        write ? `<button class="btn btn-primary" id="mkBatch"><i class="bi bi-lightning"></i> Prepare this week's batch</button>` : "") +
      `<div class="alert alert-light border small"><i class="bi bi-shield-check text-success"></i> Skipped automatically: cleared accounts, accounts with a payment awaiting confirmation, agreed payment plans, and anyone reminded in the last ${esc(state.school && state.school.settings ? state.school.settings.reminder_interval_days : 7)} days.</div>
      <div class="table-card mb-4"><div class="d-flex justify-content-between align-items-center p-3 pb-2"><h2 class="h6 fw-bold m-0">Awaiting approval (${drafts.length})</h2>
        ${write && drafts.length ? `<div class="d-flex gap-2"><button class="btn btn-sm btn-light" id="rejSel">Remove selected</button><button class="btn btn-sm btn-primary" id="apprSel">Approve selected</button></div>` : ""}</div>
      ${drafts.length ? `<div class="table-responsive"><table class="table align-middle"><thead><tr><th><input type="checkbox" class="form-check-input" id="selAll" checked aria-label="Select all"></th><th>Parent · learner</th><th class="text-end">Balance</th><th>Channel</th><th>Message</th></tr></thead><tbody>
        ${drafts.map((r) => `<tr><td><input type="checkbox" class="form-check-input" data-sel="${r.id}" checked aria-label="Select"></td><td><div class="fw-semibold">${esc(r.guardian)}</div><div class="small text-soft">${esc(r.student)}</div></td>
        <td class="text-end fw-semibold">${kes(r.balance_at_draft)}</td><td>${label(r.channel)}</td><td class="small" style="max-width:420px">${esc(r.message_body)}</td></tr>`).join("")}</tbody></table></div>` : empty("bell", "No reminders waiting. Prepare a batch when you're ready.")}</div>
      <h2 class="h6 fw-bold mb-2">History</h2>
      <div class="table-card">${rows.filter((r) => r.status !== "draft").length ? `<table class="table align-middle small"><tbody>${rows.filter((r) => r.status !== "draft").map((r) => `<tr><td>${esc(r.guardian)}</td><td>${esc(r.student)}</td><td>${kes(r.balance_at_draft)}</td><td>${badge(r.status)}</td><td class="text-soft">${when(r.sent_at || r.created_at)}</td></tr>`).join("")}</tbody></table>` : empty("clock-history", "No reminders sent yet.")}</div>`;
    const mk = document.getElementById("mkBatch");
    if (mk) mk.onclick = async () => { try { const r = await api.createReminderBatch(); toast(r.drafts ? `${r.drafts} reminders drafted for review` : "No accounts need a reminder right now", r.drafts ? "success" : "info"); go("reminders"); } catch (e) { fail(e); } };
    const sel = () => [...main.querySelectorAll("[data-sel]:checked")].map((x) => x.dataset.sel);
    const all = document.getElementById("selAll"); if (all) all.onchange = () => main.querySelectorAll("[data-sel]").forEach((c) => c.checked = all.checked);
    const ap = document.getElementById("apprSel"); if (ap) ap.onclick = async () => { const ids = sel(); if (!ids.length) return; if (!(await confirmAction(`Send ${ids.length} fee reminders now?`))) return; try { await api.setReminderStatus(ids, "approved"); toast(`${ids.length} reminders approved and sending`); go("reminders"); } catch (e) { fail(e); } };
    const rj = document.getElementById("rejSel"); if (rj) rj.onclick = async () => { const ids = sel(); if (!ids.length) return; try { await api.setReminderStatus(ids, "rejected"); toast("Removed from batch", "info"); go("reminders"); } catch (e) { fail(e); } };
  };

  // --------------------------------------------------------------- my class
  VIEWS.myclass = async (main) => {
    const { cls, students } = await api.listMyClassStudents();
    main.innerHTML = header(esc(cls ? cls.name : "My class"), `${students.length} learners`) +
      `<div class="table-card"><table class="table align-middle"><thead><tr><th>Adm. no.</th><th>Learner</th></tr></thead><tbody>${students.map((s) => `<tr><td class="small">${esc(s.admission_number)}</td><td>${esc(s.first_name)} ${esc(s.last_name)}</td></tr>`).join("")}</tbody></table></div>
      <p class="small text-soft mt-3">Attendance registers and parent absence notices arrive in Phase 5.</p>`;
  };

  // ------------------------------------------------------------------ tasks
  VIEWS.tasks = async (main) => {
    const rows = await api.listTasks();
    main.innerHTML = header("Tasks", "Follow-ups created by the automations and by colleagues.") + `<div class="row g-3"><div class="col-lg-8">${tasksCard(rows)}</div></div>`;
    bindTaskChecks(main);
  };

  // --------------------------------------------------------------- settings
  VIEWS["school-settings"] = async (main) => {
    const s = await api.getSchool(); state.school = s; const st = s.settings || {};
    const editable = can(role(), "admin") || api.mode === "demo" && role() === "school_admin";
    main.innerHTML = header("School settings", "The rules your automations follow. Changing them here changes behaviour; no code needed.") +
      `<div class="card p-4" style="max-width:760px"><form id="setForm">
        <div class="row g-3">
          <div class="col-md-6"><label class="form-label small">School name</label><input class="form-control" value="${esc(s.name)}" disabled></div>
          <div class="col-md-6"><label class="form-label small">Public form link</label><input class="form-control" value="enquiry.html?school=${esc(s.slug)}" disabled></div>
          <div class="col-12"><label class="form-label small">Required admission documents (comma separated)</label><input class="form-control" name="required_documents" value="${esc((st.required_documents || []).join(", "))}"></div>
          <div class="col-md-4"><label class="form-label small">Days between fee reminders</label><input class="form-control" type="number" min="3" max="60" name="reminder_interval_days" value="${esc(st.reminder_interval_days)}"></div>
          <div class="col-md-4"><label class="form-label small">Grace days after due date</label><input class="form-control" type="number" min="0" max="60" name="reminder_grace_days" value="${esc(st.reminder_grace_days)}"></div>
          <div class="col-md-4"><label class="form-label small">Daily briefing hour</label><input class="form-control" type="number" min="5" max="10" name="briefing_hour" value="${esc(st.briefing_hour || 7)}"></div>
          <div class="col-md-6"><label class="form-label small">Delete unconverted enquiries after (months)</label><input class="form-control" type="number" min="1" max="36" name="enquiry_retention_months" value="${esc(st.enquiry_retention_months || 12)}"></div>
          <div class="col-md-6"><label class="form-label small">Default message language</label><select class="form-select" name="default_language"><option value="en" ${st.default_language === "en" ? "selected" : ""}>English</option><option value="sw" ${st.default_language === "sw" ? "selected" : ""}>Kiswahili</option></select></div>
        </div>
        ${editable ? `<button class="btn btn-primary mt-4" type="submit">Save settings</button>` : `<p class="small text-soft mt-3 mb-0">Only the school administrator can change settings.</p>`}
      </form></div>
      <div class="card p-4 mt-3" style="max-width:760px"><h2 class="h6 fw-bold">Integrations</h2>
        <ul class="small mb-0"><li>Email: Gmail / Google Workspace via Make, status shown in automation activity</li><li>SMS: Africa's Talking via Make (sender ID registration needed)</li>
        <li>WhatsApp Business Platform: Phase 5 (needs Meta verification and approved templates)</li><li>M-Pesa Daraja: Phase 5 (payments arrive as "pending" for the bursar to confirm)</li></ul></div>`;
    document.getElementById("setForm").onsubmit = async (ev) => {
      ev.preventDefault(); if (!editable) return;
      const f = new FormData(ev.target);
      const patch = { required_documents: f.get("required_documents").split(",").map((x) => x.trim().toLowerCase().replace(/\s+/g, "_")).filter(Boolean),
        reminder_interval_days: +f.get("reminder_interval_days"), reminder_grace_days: +f.get("reminder_grace_days"), briefing_hour: +f.get("briefing_hour"),
        enquiry_retention_months: +f.get("enquiry_retention_months"), default_language: f.get("default_language") };
      try { await api.updateSchoolSettings(s.id, patch); toast("Settings saved"); } catch (e) { fail(e); }
    };
  };

  boot().catch(fail);
})();
