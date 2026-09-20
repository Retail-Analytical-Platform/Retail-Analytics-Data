# Foundations of the Approach — From Raw Data to Stakeholder Insight

This document is the **entry point** before reading `readmechat.md` and
`readmechat2stakeholder.md`. It isn't SQL — it's the **line of reasoning**:
why the analysis was done in this order, what was worth worrying about at
each stage, and how each stage justifies the next. If the other two documents
answer "what" and "how", this document answers **"why this order"**.

---

## 1. Starting Point: The Question to Answer

There are 5 data files (`dim_customer`, `dim_date`, `dim_product`,
`dim_store`, `fact_sales`) forming a star schema in Postgres. The end goal is
simple: **produce insight that can be trusted for business decisions.**

But there's one principle held from the start:

> **Raw data isn't automatically trustworthy — especially if it's never been
> validated.**

This principle drives the entire order of work below, and explains why the
work didn't jump straight into "build a revenue-by-region dashboard" at the
start.

---

## 2. Framework — 4 Sequential Stages

The thinking process is split into 4 major stages. Each stage **cannot be
skipped**, because the next stage depends on the trust built in the one
before it.

```
Stage 1              Stage 2                Stage 3                 Stage 4
Learn structure  →   Audit data trust   →   Clean/flag what      →  Business insight
& relationships       (don't assume)         can/can't be trusted     for stakeholders
     |                     |                       |                       |
     v                     v                       v                       v
 star schema,        anti-join on FKs,       UPDATE dim_date,        readmechat2
 5 tables,           check revenue           UPDATE fact_sales,      stakeholder.md
 primary keys        formula, check           CREATE VIEW            (business language,
                     constant discount,       fact_sales_clean       numbers safe to use)
                     check duplicate emails
     └───────────────────────┬──────────────────────────┘
                     readmechat.md
                (technical foundation & audit)
```

### Stage 1 — Learn the data structure & relationships
Before writing a single analysis query, it's necessary to know: what tables
exist, what their primary keys are, and how they connect to each other
(`fact_sales` as the fact table, four dimension tables around it). This is
purely mapping — no right/wrong judgment yet.

**Why first?** Because every later stage (audit, cleaning, insight) relies on
`JOIN`s between tables. Without understanding the relationships first, a
`JOIN` could silently be wrong (e.g. one that silently drops or duplicates
rows) without noticing.

### Stage 2 — Audit data trust ("don't assume")
This is where the core mindset lives: **every column that will be used for a
business decision must first be tested for internal consistency.** Example
questions asked of the data at this stage:
- Does every foreign key in `fact_sales` actually have a matching row in the
  dimension tables? (if not → a `JOIN` could silently lose data)
- Does `revenue` actually equal `quantity × price × (1 - discount)`? (if it
  doesn't match → that means one column can't be used to validate another)
- Does `discount_pct` actually vary, or is it just a constant number with no
  analytical value?
- Are `quarter`/`is_weekend` in `dim_date` actually consistent with the real
  date (`full_date`/`day_of_week`)?
- Are any customers recorded twice (same email, different `customer_key`)?

**Why this stage before business insight?** Because if "Top 10 most
profitable products" had been built straight away without auditing first, it
would only become apparent later that many products in this data have
negative margin (sale price < cost price) — and that could have already been
presented to stakeholders as fact when it's actually a data defect.

### Stage 3 — Clean what can be cleaned, flag what can't
The Stage 2 audit doesn't always end in "fix it". Three kinds of follow-up
were used, depending on the nature of the problem:

| Type of problem | Action | Example |
|---|---|---|
| Can be recomputed from a correct source | **Fix directly** (`UPDATE`) | `quarter` and `is_weekend` can be recomputed from `full_date`/`day_of_week`, so they were fixed directly. |
| The source of truth is clear, but lives in another column | **Build a view / synchronize** | `fact_sales.category` isn't trustworthy on its own → `fact_sales_clean` was built, pulling `category` from `dim_product`. |
| No clear source of truth exists | **Don't fix, just flag** | `revenue` doesn't match the manual formula — the original formula is unknown, so `revenue` was **not** overwritten, just documented as unable to be cross-validated. Same for negative product margins — not something to "fix", but flagged as unfit for use. |

The principle: **never overwrite data without being sure what the correct
value is.** It's safer to flag something as "untrustworthy" than to force a
fix based on an assumption that might be wrong.

These two sub-stages (2 and 3) are what `readmechat.md` contains — that
document is the **technical thought record**, written in sequence so anyone
(including a later reread) can follow why one query ran before another.

### Stage 4 — Business insight, but only on a safe foundation
Only after Stages 2–3 are done is it appropriate to answer business
questions: which category sells best, which region is most profitable, which
customers are most valuable, etc. But there's one additional rule at this
stage: **every insight built must deliberately avoid columns already flagged
as problematic in Stage 2**, or explain the limitation if used anyway.

This is what `readmechat2stakeholder.md` contains — not just "business
queries", but business queries that have **already been filtered** through
the knowledge from Stages 2–3. Concrete examples:
- `fact_sales_clean` is used (not the raw `fact_sales.category`) because
  Stages 2/3 already proved the raw column is out of sync.
- Monthly trend is computed from `full_date` directly, **not** from
  `month_name`, because Stage 2 found `month_name` was never fixed and is
  still inconsistent.
- Product margin is deliberately **not** shown to stakeholders, because Stage
  2 found many negative margins with a questionable source.
- A "Data Limitations" section was added explicitly so anyone reading the
  business document knows the limits of the numbers they're seeing — a
  direct translation of the audit findings from Stage 2, just in different
  language (technical to business).

---

## 3. Relationship Between the Three Documents

```
readmechatpenjelasanawal.md   <- You are here: MAP & REASONING behind the order
        |
        |  explains why the order is this way
        v
readmechat.md                 <- FOUNDATION: structure + data quality audit,
                                  explained syntax by syntax, in sequence,
                                  each query tied to the one before/after it
        |
        |  the validation & cleanup results become "the rules"
        v
readmechat2stakeholder.md     <- APPLICATION: business insight queries built
                                  on top of tables/columns that have already
                                  "passed" the audit, in language and framing
                                  for non-technical readers
```

Suggested reading order: **this document first** (to understand the
reasoning framework) → then `readmechat.md` (to understand the technical
detail and why the data needed cleaning) → then `readmechat2stakeholder.md`
(to understand how those results translate into business decisions). Reading
in reverse order is possible, but the risk is: the business insight in the
third document can feel like it's "suddenly avoiding this or that column"
without knowing why — that reason lives in the second document, and the
reasoning behind it lives here.

---

## 4. Principles Held from Start to Finish

1. **Structure first, meaning second.** Understand the relationships between
   tables before judging the content of the data.
2. **Audit before analysis.** Never build business insight on a column that
   hasn't been tested for consistency.
3. **Only fix when the source of truth is clear.** If the correct value
   isn't certain, don't overwrite the data — just flag it as untrustworthy.
4. **Business insight must inherit the caution from the audit stage.** Every
   number that reaches a stakeholder must be traceable: why this column was
   used, why that column was avoided.
5. **Separate technical language and business language, but never separate
   the honesty.** `readmechat2stakeholder.md` is written in non-technical
   language, but the data limitations are still communicated (the "Data
   Limitations" section), not hidden for the sake of a tidy-looking
   presentation.

In short: **there was never a direct jump from raw data to a business
conclusion.** There's always an audit-and-cleanup bridge in between, and that
bridge is what makes it possible to trust — or know exactly when to be
suspicious of — the numbers ultimately presented.
