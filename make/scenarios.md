# EduFlow AI — Make automation architecture

## What is actually built (21 Nov 2026)

Your Make account is on the **Free plan (2 active scenarios, 1,000 operations a month)**, so the MVP automations are combined into **two scenarios** in the Make folder **EduFlow AI**. Most of the logic runs inside the database (migration `004_automation.sql`, 28 automated tests), and Make only moves data between Supabase, the AI and Gmail.

| Make scenario | Trigger | Covers | Blueprint |
|---|---|---|---|
| **EduFlow AI · Live events (enquiries + sending)** (id 8715386) | Webhook `EduFlow AI · Supabase events`, called by database triggers with `{event, id}` only | **S1** classify → acknowledge → task; **S0** send approved messages exactly once | `make/blueprints/live_events.json` |
| **EduFlow AI · Daily 06:45 (briefing + Monday fee reminders)** (id 8715389) | Every day 06:45 Nairobi time | **S6** totals-only morning briefing; **S3** Monday reminder drafts (bursar still approves) | `make/blueprints/daily.json` |

- **Database → Make:** triggers `make_enquiry_created` and `make_message_ready` call the webhook through `pg_net`. The URL is stored in `app.config` (`make_webhook_url`).
- **Make → database:** HTTP module with the Supabase **secret key** (connection "Supabase eduflow-demo (secret key)", header `apikey`) calling `automation_enquiry_context`, `automation_apply_classification`, `automation_claim_message`, `automation_mark_sent`, `automation_daily_run`, `automation_log`. Only the service role can execute them.
- **AI:** Make's built-in AI provider (model "medium") for now, so no Claude API key is needed yet. The prompt is `enquiry_classifier` v1.0. Invalid output → the enquiry goes to a person (fallback).
- **Email:** Gmail connection "Naomi Gmail (send)", mwanginaomi42@gmail.com.
- **SMS:** not connected. SMS messages are marked `failed` with "SMS provider not connected yet", never faked.
- **Demo safety:** the demo school has `settings.demo_redirect_email`, so **every** outgoing message (email or SMS) goes to the operator inbox with a `[DEMO … to <original recipient>]` subject. Remove that setting only for a real school.
- **Not yet built:** S2 (application letters), S5 (inbound email triage), S7 (retention), S8 (AI draft endpoint), S9 (health sweep). They need a paid Make plan (more active scenarios) or more routes in the live-events scenario.

---

## Original full design (all scenarios)

All scenarios live in one Make team folder, **EduFlow AI**. Supabase is the system of record, so Make never keeps its own copy of school data. The database enforces the safety rules, so even a mis-built scenario cannot approve a message, make an admission decision or confirm a payment.

## Shared building blocks (set up once)

| Item | What it is | Where |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` | Project URL + **service_role** key | Make → Keys / a custom "Supabase EduFlow" HTTP connection. Never in the website. |
| `ANTHROPIC_API_KEY` | Claude API key | Make keychain (HTTP "API key" auth) |
| `AT_USERNAME`, `AT_API_KEY`, `AT_SENDER_ID` | Africa's Talking SMS | Make keychain |
| Gmail connection | The school's or YomieVerse's Google Workspace mailbox | Make Gmail app |
| `WEBHOOK_SECRET` | Random 32-character string | Sent by Supabase as header `x-eduflow-secret`; first filter in every webhook scenario checks it |
| `AI_MODEL` | Current Claude Sonnet model id | Make scenario variable (one place to update) |
| Sub-scenario **LOG** | Writes one row to `automation_logs` | Called at the end of every scenario and from every error handler |

**Supabase REST pattern (HTTP › Make a request)**
- URL: `{{SUPABASE_URL}}/rest/v1/<table>?<filters>`; Headers: `apikey: {{key}}`, `Authorization: Bearer {{key}}`, `Content-Type: application/json`, `Prefer: return=representation`.
- RPC: `POST {{SUPABASE_URL}}/rest/v1/rpc/<function>` with a JSON body.

**Claude call pattern (HTTP › Make a request)**
`POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, body `{model, max_tokens, temperature, system, messages:[{role:"user", content: <user_template filled>}]}` → **JSON › Parse JSON** on `content[1].text` → filter "is valid + required keys present", else take the prompt's `fallback`. Then insert a row in `ai_interaction_logs`.

**Triggers from Supabase:** Database → Webhooks → "Create a new hook" → table + event → HTTP POST to the Make webhook URL with header `x-eduflow-secret`. The row is saved first, and Make reacts after, so nothing is lost if Make is down. The S9 sweep catches anything missed.

**Error handling defaults:** every HTTP module gets a **Break** error handler (3 retries, 2 minutes apart) for timeouts and 5xx errors. 4xx errors route to **LOG** with `status='failed'` and an in-app notification to the school admin. Store incomplete executions = ON.

**Operations budget (pilot, 1 school):** about 3,000–5,000 operations a month. That fits Make Core (10,000 operations a month). Check current Make pricing before buying.

---

## S0 — Send approved messages (dispatcher)
| | |
|---|---|
| **Trigger** | Supabase webhook on `communication_logs` UPDATE (and INSERT) → Make custom webhook. Also run hourly by S9 for anything stuck. |
| **Input** | `record` (new row), `old_record` |
| **Filter** | secret OK **AND** `record.direction = outbound` **AND** (`record.status = approved` **OR** (`record.status = queued` and `requires_approval = false`)) **AND** `attempt_count < 3` |
| **Modules** | 1 Webhook → 2 HTTP PATCH row: `status=queued`, `attempt_count+1`, `idempotency_key = 'msg:'+id` (an existing key = already being sent → stop) → 3 Router: **email** → Gmail *Send an email* (to `recipient`, subject, body) / **sms** → HTTP POST Africa's Talking `/version1/messaging` (`username`, `to`, `message`, `from`) → 4 HTTP PATCH `status=sent`, `sent_at`, `provider_message_id` → 5 LOG |
| **Data mapping** | `recipient` → To / `to`; `body` → message; `subject` → subject (email only) |
| **Error handling** | Provider error → PATCH `status=failed`, `error=<message>`; S9 retries up to 3 times, then notifies the admin |
| **Logging** | `automation_logs` (scenario `S0_dispatch`), provider id stored on the message |
| **Test** | Approve a draft in the app → the message arrives within 1 minute; approve twice quickly → only one SMS; break the SMS key → status `failed` + admin notification |

## S1 — Admissions enquiry intake
| | |
|---|---|
| **Trigger** | Parent submits `enquiry.html` → RPC `submit_enquiry` (validates, de-duplicates, stores) → Supabase webhook on `admissions_enquiries` INSERT → Make |
| **Input** | `record`: id, school_id, reference, parent_name, parent_phone, parent_email, learner_first_name, learner_age, grade_sought, intake, message, source |
| **Filter** | secret OK **AND** `record.status = new` **AND** `record.category = unclassified` (so re-runs don't re-classify) |
| **Modules** | 1 Webhook → 2 HTTP GET school (`schools?id=eq.{school_id}&select=name,settings`) → 3 Claude **enquiry_classifier** → 4 Parse JSON (+ fallback) → 5 HTTP PATCH enquiry: category, urgency, ai_summary, needs_human, status=`acknowledged` → 6 HTTP POST `communication_logs`: **fixed acknowledgement template** (not AI), `requires_approval=false`, `template_key=enquiry_ack`, `status=queued`, `idempotency_key='ack:'+enquiry_id` → S0 sends it → 7 HTTP POST `staff_tasks` "Follow up enquiry {reference}", due = `follow_up_due_at`, priority = urgency → 8 HTTP POST `notifications` to each admissions officer (from `school_memberships`) → 9 *(optional, off for the pilot)* Claude **enquiry_reply_drafter** → POST draft into `communication_logs` (`ai_generated=true`, status draft) **only if `needs_human=false`** → 10 Claude log + LOG |
| **Acknowledgement template** | EN: "Dear {first name}, thank you for your enquiry to {school}. Your reference is {ref}. Our admissions office will reply within one working day." SW: "Habari {jina}, asante kwa kuwasiliana na {shule}. Nambari yako ya kumbukumbu ni {ref}. Ofisi ya usajili itakujibu ndani ya siku moja ya kazi." |
| **Error handling** | AI failure → fallback (unclassified, needs_human=true); the acknowledgement and task are still created. Database 4xx → LOG failed + admin notification. |
| **Test** | Normal enquiry; Kiswahili enquiry; medical enquiry (must be `needs_human`, no AI draft); duplicate within 30 days (no second ack: RPC merges, no INSERT event); email-only parent; AI key removed (fallback path) |

## S2 — Application tracking
| | |
|---|---|
| **Trigger** | Supabase webhook on `applications` INSERT/UPDATE |
| **Input** | `record`, `old_record` |
| **Filter A (new)** | INSERT → send fixed "application received" template with reference + upload link `apply.html?...` (queued, no approval) and a task for admissions |
| **Filter B (documents)** | `status` changed to `incomplete` and it's been 48 h since submission → build a **missing-documents** message from `missing_documents` (template, not AI) as a **draft** for approval |
| **Filter C (decision)** | `status` changed to offered / waitlisted / declined → create a **draft** parent letter from the school's template for that outcome → staff approve in Approvals. (The decision itself can only be set by staff: the database refuses it from Make.) |
| **Modules** | Webhook → Router (A/B/C) → HTTP POST `communication_logs` / `staff_tasks` → LOG |
| **Error handling** | Standard; never retries a decision letter automatically |
| **Test** | Submit application with no files → after 48 h a draft request appears; upload all → status complete, no request; set "offered" in app → draft offer letter appears, not sent |

## S3 — Fee reminders
| | |
|---|---|
| **Trigger** | Schedule: Mondays 08:00 Africa/Nairobi |
| **Input** | Active schools (`schools?status=eq.active`) |
| **Modules** | 1 Schedule → 2 HTTP GET schools → 3 Iterator → 4 HTTP POST `rpc/create_reminder_batch` `{p_school}` (the database applies the school's rules: balance > 0, past due + grace days, no pending payment, not paused, not reminded within the interval, no existing draft) → 5 Filter `drafts > 0` → 6 HTTP POST `notifications` to bursar(s): "{n} fee reminders ready for approval" → 7 LOG |
| **AI** | None by default. The wording is a reviewed template in English/Kiswahili with the balance inserted by the database. (If a school wants friendlier wording, polish the *template text once* with Claude, never per message, so amounts are never touched by AI.) |
| **Sending** | Bursar approves in the app → the database stamps the approver → a webhook on `payment_reminders` UPDATE status=approved → S0-style send → PATCH `sent`, insert `communication_logs` copy |
| **Safeguards** | No duplicate drafts (tested); a reminder can't be sent without an approver (tested); the bursar can untick anyone who paid in cash this morning |
| **Test** | Run twice → second run 0 drafts; pending M-Pesa → skipped; paused account → skipped |

## S4 — Attendance notification (Phase 5)
| | |
|---|---|
| **Trigger** | Webhook on `attendance_records` UPDATE where `is_final` turns true (teacher finalises the register) |
| **Filter** | status = absent **AND** no absence notice already logged for that learner + date (idempotency `absence:{student}:{date}`) **AND** the school setting `absence_notices = on` |
| **Modules** | Webhook → aggregate by class → for each absent learner, fetch guardian → **template** SMS draft ("{child} was marked absent today…") → approval by class teacher or admin (schools can switch this to auto-send later) → S0 → LOG |
| **Safeguards** | Only finalised registers; correction after sending triggers an apology template draft; no AI involved |

## S5 — Parent enquiry management (current parents)
| | |
|---|---|
| **Trigger** | Gmail *Watch emails* on the school inbox label `EduFlow`; later, WhatsApp Business webhook; Africa's Talking inbound SMS callback |
| **Modules** | Trigger → HTTP GET `parents_guardians?school_id=eq.X&or=(email.eq.{from},phone.eq.{from})` → Claude **parent_message_triage** (message text only) → HTTP POST `communication_logs` (`direction=inbound`, `status=received`) → if `needs_human` or topic ∈ {complaint, safeguarding, health} → `staff_tasks` priority high + notification to admin; else Claude **enquiry_reply_drafter** with approved facts → draft for approval → LOG |
| **Unknown sender** | Not matched to a guardian → treat as a prospective enquiry: call `rpc/submit_enquiry` with `p_source='email'` and consent recorded as "implied by contacting the school" only if the school's privacy notice says so; otherwise just a task |
| **Test** | Fee question from known parent; complaint (must route to human, no draft); unknown sender |

## S6 — Daily administrative briefing
| | |
|---|---|
| **Trigger** | Schedule daily 06:45 Africa/Nairobi, Monday to Saturday |
| **Modules** | 1 Schedule → 2 GET active schools → 3 Iterator → 4 GET `v_school_dashboard?school_id=eq.X` → 5 GET overdue follow-ups (reference + category only), events next 7 days, tasks due today → 6 Claude **daily_briefing** (totals only, no learner names or individual balances) → 7 GET recipients: memberships with role school_admin/head_teacher → 8 Gmail send → 9 LOG |
| **Fallback** | AI fails → send the plain counts template |
| **Test** | Compare every number in the email with the dashboard; confirm no learner names or per-learner balances appear |

## S7 — Data retention clean-up
| | |
|---|---|
| **Trigger** | Schedule monthly, 1st at 02:00 |
| **Modules** | GET schools → for each: DELETE `admissions_enquiries?status=in.(new,acknowledged,closed,spam)&created_at=lt.{now − enquiry_retention_months}` → delete orphaned storage files for withdrawn/declined applications older than the retention period → LOG counts |
| **Why** | Kenya DPA 2019 storage-limitation principle; the school sets the period in Settings |

## S8 — AI draft endpoint (for the app's AI buttons)
| | |
|---|---|
| **Trigger** | Custom webhook called by the app with `{kind, school_id, input, access_token}` |
| **Security** | First module: HTTP GET `{{SUPABASE_URL}}/auth/v1/user` with the caller's `access_token` → reject if invalid; then GET `school_memberships?user_id=eq.{uid}&school_id=eq.{school_id}` (service key) → reject unless the role is office staff. Strip input to the prompt's allowed fields. |
| **Modules** | Router by `kind` → Claude **enquiry_reply_drafter** or **announcement_drafter** → Parse JSON → POST `ai_interaction_logs` → Webhook response `{draft, note, facts_to_confirm}` |
| **Note** | The response is only shown in the editor. It reaches a parent only after the staff member saves it as a draft and it is approved. |

## S9 — Health sweep
Hourly: re-queue `communication_logs` stuck in `queued` > 15 min or `failed` with `attempt_count < 3`; find enquiries with `category='unclassified'` older than 10 min and re-run S1's classification; alert YomieVerse (email) if any scenario logged `failed` 3+ times in 24 h.

---

## Go-live checklist for Make
1. Create the 4 keychain entries and the Gmail connection (use the school's or YomieVerse's Workspace account).
2. Build **LOG** first, then S0, S1, S3, S6, S8 (MVP). S2, S5, S7, S9 next; S4 in Phase 5.
3. In Supabase → Database → Webhooks create hooks for: `admissions_enquiries` INSERT → S1; `applications` INSERT/UPDATE → S2; `communication_logs` INSERT/UPDATE → S0; `payment_reminders` UPDATE → S0b.
4. Run each scenario's test list against the **demo school** before connecting a real school.
5. Turn scenarios ON one at a time and watch `automation_logs` on the dashboard for 48 hours.
