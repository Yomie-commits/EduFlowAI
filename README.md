# EduFlow AI

**Smarter School Operations. Better School Experiences.** A product by Naomi Mwangi.

EduFlow AI automates the front office of Kenyan private schools: admissions enquiries, applications and documents, parent communication and fee reminders. It runs alongside the school's existing management system rather than replacing it. AI sorts, summarises and drafts; staff approve everything, and the database enforces that.

## What's in this folder

| Path | What it is |
|---|---|
| `index.html`, `app.html`, `enquiry.html`, `apply.html`, `css/`, `js/` | The website (served by GitHub Pages): landing page, staff app, public enquiry form, application + document upload |
| `js/config.js` | The only file you edit to connect a real Supabase project |
| `supabase/migrations/001_schema.sql` | 28 tables + reference data (roles, permissions) |
| `supabase/migrations/002_security_rules.sql` | Row Level Security, human-approval rules, audit trail, public RPCs, reminder batch |
| `supabase/migrations/003_storage.sql` | Private document bucket and upload rules |
| `supabase/migrations/004_automation.sql` | Automation bridge: database triggers call Make; service-role-only functions Make calls back |
| `supabase/seed.sql` | **Fictional** demo data: Mwangaza Junior Academy + Baraka Little Stars Daycare |
| `tests/` | 77 automated tests: 49 security + 28 automation (`run_local.sh`) |
| `make/scenarios.md` | What is built in Make now, plus the full scenario design |
| `make/blueprints/` | Exported blueprints of the two live Make scenarios |
| `prompts/prompt-library.json` | Claude prompts with output schemas, fallbacks and test cases |

## 1. See the demo (no setup)
Live at **https://yomie-commits.github.io/EduFlowAI/** (GitHub Pages, served from the root of `main`). With `SUPABASE_URL` empty, the app runs in **demo mode** with fictional data and a banner that says so. Pick a role on the sign-in page to see what that person sees.

## 2. Live backend
Already done for the demo: Supabase project **eduflow-demo** (`https://ncgszlwawiagennffkjw.supabase.co`, EU Frankfurt) has migrations 001–004 and the fictional seed. `js/config.eduflow-demo.js` holds its public URL and publishable key; copy it over `config.js` to switch the website to live data. To set up another project, follow these steps:

### Setting up a new project (about 30 minutes)
1. Create a Supabase project (region: **EU Frankfurt**; there's no Kenyan region, so mention the transfer in the privacy notice).
2. SQL Editor → run `001_schema.sql`, `002_security_rules.sql`, `003_storage.sql` and `004_automation.sql` in that order. Then save the Make webhook URL: `insert into app.config (key, value) values ('make_webhook_url', '<your Make webhook URL>');`
3. Authentication → add the demo users listed at the top of `seed.sql` (or your real staff), then run `seed.sql` (demo only, **never** for a real school).
4. Settings → API → copy the **Project URL** and **anon public** key into `js/config.js`. (Never copy the service_role key into the website.)
5. Authentication → URL configuration → add your site URL (for example `https://yomie-commits.github.io/EduFlowAI/`).
6. Commit and push to `main`. GitHub Pages (Settings → Pages → Deploy from branch `main`, folder `/ (root)`) republishes the site on every push.

For a real school: insert one row in `schools`, invite staff through Supabase Auth, and add `school_memberships` rows with their roles. A super admin (Naomi Mwangi, the platform operator) is a `user_profiles` row with `is_super_admin = true`, set in the SQL editor only.

## 3. Turn on automations
The two MVP scenarios already exist in Make (folder **EduFlow AI**): *Live events* (S1 enquiries + S0 sending) and *Daily 06:45* (S6 briefing + S3 Monday reminders). Their blueprints are in `make/blueprints/`; `make/scenarios.md` explains how they work and lists the scenarios still to build.

## 4. Run the security tests
Needs PostgreSQL 15+ locally:
```bash
PGHOST=localhost PGUSER=postgres tests/run_local.sh
```
Expected: `PASS: 77   FAIL: 0`. Run this after every change to the SQL.

## Rules the database guarantees (not just the screens)
- A user only ever sees their own school's rows, and only the tables their role needs.
- AI-written messages cannot be sent until a named staff member approves them.
- Automations (Make) cannot make admission decisions, approve messages, or confirm, edit or delete payments.
- Confirmed payments are reversed with a reason, never edited. Payments and audit logs cannot be deleted.
- Fee reminders quote the balance from the records, skip pending payments and payment plans, and never repeat within the school's interval.
- Admission decisions, approvals, payment changes and role changes are written to `audit_logs`.

## Maintenance
- **Change who can do what:** edit `app.group_roles()` in `002_security_rules.sql`, then re-run the tests.
- **Change reminder rules:** School settings screen (interval, grace days). No code needed.
- **Change a prompt:** edit `prompts/prompt-library.json`, bump its `version`, paste into the Make scenario, and run its test cases.
- **Monthly:** check `automation_logs` for failures, Supabase usage, Make operations, SMS spend.
