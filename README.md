# CargoLens

CargoLens is a desktop-first shipment-document review workspace for freight forwarders and customs brokers. It keeps the filing system unchanged: executives review shipment data and download a CSV after manager approval.

## Current implementation

- **Demo mode:** seeded illustrative shipments, local-only edits and local file previews. It does not perform OCR or AI extraction. Do not enter Company A data.
- **Connected mode:** Supabase email/password authentication, executive/manager roles, shipment records, private document storage, short-lived signed previews, audit events, manual-entry marking, and server-enforced submission/approval checks.
- **AI extraction:** a Supabase Edge Function uploads documents to LlamaCloud Extract using a server-side secret, validates the structured result, saves per-field confidence and cited source evidence, and requires human confirmation for low-confidence fields. Use only synthetic take-home documents with the free tier; never send real customer or confidential pricing data through it.
- **Export:** the current CSV is a starter layout. The filing software's real Excel/CSV template is required before it can be called production-ready.

## Local demo

Requires Node.js 20.19+ or 22.12+.

```sh
npm install
npm run dev
```

With no `.env.local`, the app uses clearly labeled synthetic demo data. `npm run build` builds a split, minified production bundle; `npm test` runs the reconciliation checks.

### Synthetic extraction samples

- `public/samples/SHP-24811-*` contains clean, text-based invoice, packing-list, and bill-of-lading PDFs. The packing list intentionally reports 3,165 kg while the invoice and bill of lading report 3,120 kg.
- `public/samples/SHP-24812-*-scan.pdf` contains image-only, lightly skewed, faded, noisy scans for OCR/vision testing. The documents are synthetic and the three weights/packages agree.
- `tests/fixtures/document-extraction-golden.json` is the expected field reference and reconciliation result. Compare each extracted document with this reference to assess field accuracy and mismatch detection. Confidence scores are model estimates, not measured accuracy.

The sample preview is available in demo mode on shipments SHP-24811 and SHP-24812. For AI testing in the connected workspace, create a shipment and upload the corresponding PDFs from `public/samples`.

## Supabase connected workspace

1. Create a Supabase project in the **Mumbai `ap-south-1` region**. Region selection controls the primary data location; it does not by itself establish legal compliance.
2. In Supabase Auth, disable public sign-ups and invite staff using unique work accounts. Enable email/password auth and configure allowed redirect URLs for localhost and the deployed application.
3. Apply migrations `202611030001_initial.sql`, `202611030002_document_replacement.sql`, and `202611030003_manager_approval_workflow.sql` in order to the new project. The second migration enables executive-only removal of a mistaken upload. The third assigns stable `EXE-#####` / `MGR-#####` staff codes, scopes executive shipment access to the executive's own records, and creates a separate approval-event history for submissions, manager approvals, rejections and returns.
4. Add the Supabase Project URL and **publishable/anon key** to a local `.env.local` using `.env.example` as the template. These two browser values are public identifiers; the database relies on RLS for access control.
5. The profile trigger assigns invited accounts the executive role. Promote the designated manager in the Supabase SQL editor after verifying their user ID:

   ```sql
   update public.profiles set role = 'manager' where user_id = '<verified-auth-user-uuid>';
   ```

6. Set the same two Vite environment variables in Vercel for the demo deployment. Do **not** put a Supabase service-role key or AI provider key in any `VITE_` variable or browser code.

The migrations create private storage with 20 MB per-file limits and PDF/JPG/PNG/WebP allow-listing. Storage objects are named beneath a shipment UUID, downloads require an authenticated session, and preview links expire after 60 seconds. The database blocks submission until all three document types are reviewed, required values and line items are filled, invoice total equals line sum, weights and package counts reconcile, and low-confidence fields are confirmed. The manager queue contains only submitted and approved records and identifies the submitting executive by name and staff code. Manager decisions are stored in `shipment_approval_events`; rejection and return require a reason and send the executive's shipment back to the recheck queue. A different manager must approve before export.

## AI extraction setup (synthetic demo only)

The browser uploads a private document to Supabase Storage. The `extract-document` Edge Function verifies the signed-in executive, checks file type and size, downloads the document server-side and sends it to LlamaCloud Extract with a structured schema. It polls the asynchronous extraction job and stores LlamaCloud confidence scores and source citations per field. Missing metadata receives confidence zero, so a person must confirm it. It does not classify HSN or calculate duty. Run it only on the included synthetic PDFs or other data approved for the provider's free tier; free-tier documents are not appropriate for client prices, personal data, or real importer documents.

To enable it in a Supabase demo project:

1. Create a free LlamaCloud account at [cloud.llamaindex.ai](https://cloud.llamaindex.ai) and create an API key. The free tier is credit-limited; this project uses the cost-effective Extract tier. Check current quotas and usage in LlamaCloud because plan terms can change.
2. In VS Code, open the project folder and deploy `supabase/functions/extract-document/index.ts` as `extract-document` with JWT verification enabled. With the Supabase CLI installed and linked, use `npx supabase functions deploy extract-document`. The Dashboard's Edge Function editor is also an option.
3. In Supabase Dashboard → Edge Functions → Secrets, add `LLAMA_CLOUD_API_KEY` with the key you created. Optionally add `LLAMA_CLOUD_PROJECT_ID` if your LlamaCloud organization requires an explicit project, set `LLAMA_EXTRACT_TIER` to `cost_effective` (default), and set comma-separated `APP_ORIGINS` (the deployed URL plus local development URL). Never add these values to Vite variables, Git, or the browser. The key must not be pasted into chat or source files.
4. Retry extraction on the synthetic sample PDFs. Free-tier credits can run out; the function reports exhausted credits clearly and the document remains available for manual entry.

The implementation is a take-home demonstration, not an approved production AI route. LlamaCloud currently documents North America and Europe regions, not India, and external processing is not appropriate for real Company A customer documents or prices. A real client pilot needs a provider with reviewed no-training, retention, region, DPA and subprocessor terms (or a self-hosted India-region service), plus evaluation on the labeled 200-shipment set.

## Deployment and client-data boundary

Vercel Hobby is for personal, non-commercial use, and its current terms permit use of Hobby content for model training. Do not deploy this commercial client workflow or place real customer data on Hobby. A Vercel deployment can host a synthetic demo; production needs an eligible commercial plan or a different host, a verified India-region architecture, an approved provider, and client sign-off.

Supabase Free is for exploration, has 1 GB storage, can pause inactive projects and does not include automatic backups. Three documents per shipment at the stated 1,100 shipments/month can exhaust that quota quickly. Treat Free as a synthetic-data pilot only, not the production storage/availability plan. Budgeted production needs retention/deletion rules, backups with recovery drills, monitoring, malware/file inspection, rate limits, and a provider review for DPDP obligations.

## Before client pilot

- Obtain the exact filing-software import workbook, column order, date/number formats and multi-line item rules.
- Provide 200 de-identified or approved historical shipments with field-level labels, including skewed and bilingual scans.
- Agree on role assignments, manager separation, retention/deletion periods, incident contacts and approved data processors.
- Evaluate per-field and per-supplier accuracy; keep low-confidence or failed-check values blocked until human confirmation.
- Run security, accessibility, performance, backup/restore and production smoke checks on the selected paid/approved environment.

## Engineering checklist and verification

### Automated checks

Run these locally before a change is considered ready:

```sh
npm test
npm run build
npm audit --omit=dev
```

`npm test` uses Node's built-in test runner. It covers the reconciliation rules, missing source data, approval blockers, low-confidence confirmation, document review state, export gating, CSV formula-injection protection, extraction error handling, and the synthetic sample fixtures. `npm run build` checks the production Vite bundle and minifies assets. The golden fixture describes expected extraction values; it is not itself evidence that the live AI model reached a given accuracy.

### Performance and infrastructure decisions

| Area | Current implementation / verification |
| --- | --- |
| API response caching | Shipment, approval, profile, document and audit data stay uncached in the browser/CDN. They are private and change during review. |
| Expensive query caching | No expensive dashboard aggregation currently exists; avoid adding a cache until a measured query needs it and an invalidation rule is defined. |
| CDN / server-side caching | Vercel serves static deployment assets. Hashed `/assets/*` files are immutable for one year; synthetic `/samples/*` PDFs cache for one day; `index.html` is never stored. Verify response headers on the deployed URL. Vercel owns network distribution; the app does not implement a custom CDN. |
| Compression | The Vite build reports gzip sizes; Vercel handles compression for app assets when supported by the client. The browser calls Supabase directly, so API payload compression is provider-managed and was not verified here. Source shipment documents remain byte-for-byte intact for review evidence. |
| Load balancer | Vercel's hosting platform handles request distribution. No app-managed load balancer is configured or load-test result claimed. |
| Database indexes | Migrations index shipment status/date, supplier, owner/status/date, line items, documents, audit history and approval history. `shipment_no` is uniquely constrained for exact approved-shipment lookup. |
| N+1 queries | Manager list profile lookup batches user IDs with one `in(...)` request per page. The exact approved-shipment lookup fetches one owner's profile after the single shipment result. |
| Pagination | Connected workspace loads shipments in 50-row pages with a Load more action. Activity data is capped to the latest 250 entries and is not yet paginated. |
| Debounced search | Shipment search waits 220 ms after typing; exact approved-record lookup only runs for a shipment-ID-shaped query. |
| Code splitting / lazy loading | React, Supabase, icons and the sign-in screen are separate production chunks; the sign-in screen is loaded on demand. |
| Image optimization | Uploaded invoices and scans are preserved as originals. The included synthetic scan PDFs are already small (about 70–78 KB); no destructive re-encoding is applied to customer evidence. |
| Loading feedback | Session, account, workspace, extraction, search and load-more states provide progress feedback. Startup uses a branded loading state rather than shipment-row skeleton cards. |
| React rendering | Derived shipment lists and document previews use memoization where appropriate. Use React Profiler with a representative workspace before further optimization. |
| Dependencies | `npm ls --depth=0` verifies the declared dependency tree. Build-time tree shaking removes unused imported code; run the audit command above when npm advisory service is reachable. |
| Connection pooling | The browser uses Supabase's HTTPS/PostgREST API; it does not open direct Postgres connections. Supabase manages its database-side connections. |
| Non-critical scripts | No analytics or external marketing scripts are loaded. |

### Test status for this checkout (3 Nov 2026)

- **Passed:** `npm test` — 20 tests, 0 failures.
- **Passed:** `npm run build` — Vite production build and minification. The sign-in chunk is 4.36 kB (1.59 kB gzip); application JavaScript is split into React, Supabase, icons and app chunks. Build output reports gzip sizes.
- **Passed:** `vercel.json` parses as valid JSON.
- **Not completed:** `npm audit --omit=dev` — npm's advisory endpoint was unreachable in this environment. This is not a clean vulnerability report; retry from a network that can access `registry.npmjs.org`.
- **Not completed:** local browser/E2E and Lighthouse run — the dev server could not bind to `127.0.0.1:5173` (`EACCES`), and Lighthouse/Playwright are not installed in this project. Run a Lighthouse desktop audit on the deployed synthetic-data demo or locally where the dev server can bind. Record Performance, Accessibility, Best Practices and SEO scores with the tested deployment URL and date.
- **Requires project access:** Supabase integration/RLS/storage/manager-approval smoke tests require the configured Supabase project and separate executive and manager accounts. No production or customer data was used during this run.
- **Requires provider access and labels:** AI golden-set evaluation must run the included clean and noisy samples through the configured extraction provider, compare extracted values with `tests/fixtures/document-extraction-golden.json`, and calculate per-field accuracy. The 95% target requires 200 labeled historical shipments; no model accuracy claim is made from the current unit tests.

### Pre-release test plan

1. **Unit:** `npm test`; add regression cases for every fixed defect.
2. **Build and dependency health:** `npm run build`, `npm audit --omit=dev`, and `npm ls --depth=0`.
3. **AI extraction:** run both sample sets, compare each field against the golden JSON, check confidence/evidence, and verify the intentional 45 kg mismatch blocks submission. Repeat for skewed and bilingual labeled pages.
4. **Executive workflow:** sign in, create shipment, upload/replace/remove a document, extract or mark manual entry, review every source, correct fields, resolve checks, submit, then confirm it appears in the manager queue.
5. **Manager workflow:** verify executive name/code, approve, return with a reason, reject with a reason, search an approved shipment ID, and confirm approved/rejected/returned data persists after reload.
6. **Security:** verify executive ownership and manager permissions through Supabase RLS using two separate accounts; test unauthenticated access, file-type/size rejection, signed URL expiry, role escalation denial, CORS, and audit-event integrity. Do this only in a disposable test project.
7. **Performance/accessibility:** run Lighthouse desktop and tablet viewports, keyboard-only review, focus/contrast/label checks, large paginated list checks, and React Profiler with realistic synthetic volumes.
8. **Deployment/recovery:** confirm HTTPS/security/cache headers and intended hosting/data regions, exercise backup restore and production smoke checks on the approved environment. Supabase Free does not provide the production backup/availability guarantees needed for real client records.

The checks above are a take-home verification baseline, not a production security certification. Private customer data, importer contact details, or confidential pricing must not be entered into the demo. The app has no direct customs-portal integration, duty calculation, or importer tracking portal.

