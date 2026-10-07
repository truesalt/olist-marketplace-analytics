# Building the dashboard with Claude Code on a Windows laptop

Power BI Desktop is Windows-only and point-and-click, so Claude Code builds the dashboard through two text-based
routes:

| Part | How Claude Code does it | Why |
|---|---|---|
| **Data model**: 9 tables, relationships, date table, 29 measures, formats | **Power BI Modeling MCP server** (Microsoft) connected to the open Power BI Desktop file | Changes are applied live and Claude can **run DAX queries to check every measure** against the expected values |
| **Report pages and visuals** (Page 1 + Page 2 of `BUILD_GUIDE.md`) | Editing the report files of a **Power BI Project (`.pbip`)** folder (PBIR JSON) | The MCP server cannot create visuals; PBIP stores them as plain files |

You stay in the loop: you open/close Power BI Desktop when asked, look at the result, and paste error messages or
screenshots back to Claude. Expect **2-3 hours** in total.

---

## 1. On the Mac (before you go): about 10 minutes

1. **Put the repo somewhere the laptop can get it.** Recommended: a *private* GitHub repo.
   ```bash
   cd "/Users/truesalt/Downloads/SQL Project"
   gh repo create olist-marketplace-analytics --private --source . --push
   ```
   (No `gh`? Create an empty private repo on github.com, then `git remote add origin <url>` and `git push -u origin main`.)
   `.env` and `data/raw/` are git-ignored, so no password or raw data is uploaded.
2. **Zip the Power BI CSVs.** They are git-ignored (about 44 MB), so they travel separately:
   ```bash
   cd "/Users/truesalt/Downloads/SQL Project" && make export && zip -r ~/Desktop/olist_powerbi_data.zip powerbi/data
   ```
   Copy the zip to a USB stick or Google Drive. **Do not** copy `.env`: the laptop never needs MySQL.

## 2. On the Windows laptop: install (about 20 minutes)

1. **Power BI Desktop** from the Microsoft Store. Open it once and let it update.
   File → Options and settings → Options → **Current file → Data Load**: untick *Auto date/time* and
   *Autodetect new relationships*.
2. **Git for Windows**: <https://git-scm.com/download/win> (defaults are fine). Claude Code uses Git Bash for shell commands.
3. **Node.js LTS**: <https://nodejs.org>. The Power BI MCP server runs through `npx`.
4. **Claude Code**: in PowerShell (no admin needed):
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   Close and reopen PowerShell, run `claude`, and sign in with **your own** Claude account.
5. **Get the project**:
   ```powershell
   git clone https://github.com/<you>/olist-marketplace-analytics.git C:\olist
   ```
   Unzip `olist_powerbi_data.zip` so the CSVs land in `C:\olist\powerbi\data\` (you should see `_manifest.csv` there).
6. **Add the Power BI Modeling MCP server** to Claude Code (from `C:\olist`):
   ```powershell
   cd C:\olist
   claude mcp add powerbi-modeling -- npx -y @microsoft/powerbi-modeling-mcp
   ```
   Check the official README (github.com/microsoft/powerbi-modeling-mcp) for any extra flags or environment
   variables your version needs. `claude mcp list` should show the server as connected.

## 3. Create the empty project skeleton (5 minutes, by hand)

Power BI Desktop writes the skeleton, so the file format always matches the installed version:

1. Power BI Desktop → blank report → **File → Save as** → type **Power BI project (*.pbip)** →
   `C:\olist\powerbi\olist_dashboard.pbip`.
2. Leave it **open**. This creates `olist_dashboard.SemanticModel\` (TMDL) and `olist_dashboard.Report\` (PBIR) next to the `.pbip`.

## 4. Run Claude Code

```powershell
cd C:\olist
claude
```

Paste this prompt:

```text
You are on Windows with Power BI Desktop. Build the Power BI dashboard for this repo.

Read first: powerbi/BUILD_GUIDE.md (target pages and visuals, exact field wells), powerbi/DAX_measures.md
(29 measures + formats + expected values), powerbi/power_query_M.md (one M query per table, all columns typed),
powerbi/theme.json. Data CSVs are in C:\olist\powerbi\data\. The open Power BI Desktop file is
C:\olist\powerbi\olist_dashboard.pbip (a PBIP project).

PHASE A - semantic model, using the powerbi-modeling MCP server against the OPEN Desktop file:
1. Create text parameter DataFolder = "C:\olist\powerbi\data\" and the 9 tables using the M scripts exactly
   as written in power_query_M.md. Refresh.
2. Create the 4 relationships from BUILD_GUIDE.md section 3.1 (many-to-one, single direction, active).
   No relationships for fact_seller_leads or the mart_* tables.
3. Mark dim_date as date table on [date]; sort month_name by month_num; hide the *_id columns listed in
   BUILD_GUIDE 3.3; add calculated column dim_seller[seller_code] = LEFT(dim_seller[seller_id], 8).
4. Create the _Measures table and all 29 measures from DAX_measures.md with their format strings; create the
   'Top N' what-if parameter (5-25, default 10) and the optional Main Category helper measure.
5. VALIDATE: run DAX queries and compare with the "Expected values" table in DAX_measures.md
   (GMV 15,683,707 / Orders 97,905 / AOV 160.19 / On-time 93.1% / Avg Delivery Days 12.5 / Low Review 13.8% /
   Repeat Rate 180d 1.99% / MQLs 8,000 / Won 842 / With First Sale 379). Show me a table expected vs actual and
   fix any mismatch before continuing. Then tell me to save (Ctrl+S) and CLOSE Power BI Desktop.

PHASE B - report pages, by editing the PBIR files in olist_dashboard.Report\ (Desktop must be closed):
1. Inspect the existing report folder structure Power BI Desktop created and follow that exact schema/version.
2. Create page "Marketplace Ops Overview" and page "Customers & Seller Supply", 1280x720, with every visual,
   position and field well listed in BUILD_GUIDE.md sections 6 and 7 (combo chart: secondary axis off; matrix
   conditional formatting; Top-N table filtered on Show In Top N = 1; constant line 0.8 on the Pareto chart).
   Use the key-findings text exactly as written in BUILD_GUIDE section 7. Apply theme.json as the report theme.
3. Tell me to reopen the .pbip. I will report errors or send screenshots; fix them until both pages render.

Rules: never invent numbers (all text comes from the repo). Do not touch files outside C:\olist. Ask before
anything destructive. Commit progress with git when a phase works.
```

**Your part while it runs:**
- Approve Claude Code's tool prompts (MCP calls, file edits inside `C:\olist`).
- When asked, save and close or reopen Power BI Desktop.
- If Desktop shows an error on open, copy the full message to Claude.
- For layout fixes, take a screenshot (Win + Shift + S) and paste it into Claude Code (Alt+V).

## 5. Finish (30 minutes)

1. In Power BI Desktop, check both pages against `BUILD_GUIDE.md` §8, the formatting checklist. Fix small layout issues by hand.
2. **File → Save as → `olist_dashboard.pbix`** in `C:\olist\powerbi\` (the README links this file). Keep the `.pbip` too.
3. **File → Export → PDF** → `C:\olist\powerbi\olist_dashboard.pdf`.
4. Screenshots of each page → `C:\olist\powerbi\screenshots\page1_overview.png` and `page2_customers_supply.png`.
5. Optional: publish (`BUILD_GUIDE.md` §11: Publish to web or NovyPro) and note the link.
6. Ask Claude Code: *"Update README.md: replace the dashboard placeholders with the screenshots, PDF and link, then
   commit and push."*
7. **On your friend's laptop afterwards:** run `/logout` in Claude Code and sign out of GitHub (or delete the stored
   credential in Windows Credential Manager). Delete `C:\olist` if you don't want to leave the project there.
8. Back on the Mac: `git pull`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `claude mcp list` shows the server as failed | `node --version` must work in a new PowerShell; re-run the `claude mcp add` command; check the server README for required env vars |
| MCP server can't find a model | Power BI Desktop must be **open** with `olist_dashboard.pbip` loaded |
| Power BI Desktop says the report folder is invalid after Phase B | Paste the full error to Claude; worst case `git checkout -- powerbi/olist_dashboard.Report` and retry a page at a time |
| Numbers differ from the expected values | Usually a relationship in the wrong direction or a column typed as text; Claude's validation step should catch it |
| "Running scripts is disabled" in PowerShell | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, then retry the install |
| Visual layout is fiddly via files | Let Claude finish the model (Phase A) and build the visuals by hand with BUILD_GUIDE §6-7 (about 1.5 h) |
