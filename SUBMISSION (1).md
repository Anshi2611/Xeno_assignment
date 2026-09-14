# Comm-Log Send Reconciliation — Submission

Merchant 501, October 2026. Finance says the number should be **22**. Here's how I got there.

## 1. Reconciliation bridge — naive count to final answer

| # | What I ran / changed | Count | Why |
|---|---|---|---|
| 0 | `SELECT COUNT(*) FROM communication_log WHERE merchant_id=501 AND communication_type='2' AND delivery_status=900` | 26 | First instinct: a "qualifying send" is just anything that got delivered. |
| 1 | Dropped campaign `9004` ("Diwali Cart Recovery – Retry C") | 26 − 4 = **22** | It's a retry of `9001` and has 4 delivered rows (`C11–C14`), but `creation_status = 'approval_awaiting'` — it never cleared approval. `processing_status = 'processed'` just means the send pipeline ran; that's not the same as being signed off. |
| 2 | Checked: does any customer get delivered more than once inside the same retry chain (`9001→9002→9003` or `9201→9202`)? | no change | Nobody does, in this dataset — each customer who eventually succeeded, succeeded exactly once per chain. Built the dedup logic into the query anyway rather than relying on that coincidence. |
| 3 | Checked: does the standalone campaign `9101` need the same per-customer dedup? | no change | No — `9101` has no parent and nothing retries off it, so it isn't a retry chain. Customer `C20` was re-targeted and delivered twice (Oct 10 and Oct 20), and both should count (7 total, not 6). Collapsing those would have under-counted and given 21 instead of 22. |

10 (`9001` family) + 7 (`9101`, standalone) + 5 (`9201` family) = **22**, matching Finance.

## 2. How I got there, in more detail

My first pass at this was pretty basic — I just counted every row in `communication_log` that was actually delivered:

```sql
SELECT COUNT(*) FROM communication_log
WHERE merchant_id = 501 AND communication_type = '2' AND delivery_status = 900;
```

That gave me **26**. Four too many. So I went looking for why.

Turned out the culprit was campaign `9004` ("Diwali Cart Recovery – Retry C"). It's a retry of `9001`, and it has four delivered rows sitting in the log (`C11` through `C14`) that look completely normal — same channel, same delivery status, nothing flags them. But when I checked the `campaign` table, its `creation_status` was still `approval_awaiting`. It had finished *processing* (the send pipeline ran fine), but it had never actually been *approved*. Those aren't the same thing, and the README is pretty explicit that a campaign only counts once both have happened. So those 4 sends shouldn't be in the reported number at all, even though nothing in `communication_log` itself would tell you that.

26 − 4 = **22**. That matched.

Before calling it done, I checked two more things that could easily have gone wrong in a bigger dataset, even though neither one actually moved the number here:

- **Does anyone get delivered more than once inside the same retry chain?** (e.g. someone succeeding on both the original send and the retry). If that had happened, I'd need to count them once, not twice. Checked it — nobody in this dataset does. Every customer who eventually got through, got through exactly once per chain. So it didn't change anything, but I still wrote the query to handle it properly rather than just assuming it away.
- **Does the standalone campaign `9101` need the same treatment?** This one actually matters conceptually, just not numerically here — `9101` isn't part of any retry chain (no parent, nothing retries off it), so customer `C20` getting sent to twice (Oct 10 and Oct 20) should count as *two* separate events, not one. If I'd applied the same "dedupe by customer" logic here that I use for retry chains, I'd have gotten 6 instead of 7 for this campaign, and ended up at 21 overall instead of 22.

So the final math is: 10 customers reached under the `9001` family, 7 sends under standalone `9101`, 5 customers under the `9201` family. 10 + 7 + 5 = **22**.

## 3. The query

Everything above is implemented in `reconciliation.sql`. Roughly, it works like this:

1. First it filters `campaign` down to only the ones that have actually cleared both the approval and the processing gate — this is the step that drops `9004`.
2. Then it recursively walks each surviving campaign up to the root of its retry chain, so `9003 → 9002 → 9001` all resolve back to `9001`, no matter how deep the chain goes.
3. It tags each chain with how many campaigns are in it, so it can tell a real retry chain apart from a standalone campaign.
4. It pulls the delivered sends for merchant 501 in October, and for chains with more than one campaign it counts distinct customers; for standalone campaigns (chain size of 1) it counts every send, repeats included.

I also added two indexes — one on `campaign.parent_id` for the recursive walk, and a covering index on `communication_log` across the filter/join columns — so the engine can seek straight to the rows it needs instead of scanning the whole table. Checked this with `EXPLAIN QUERY PLAN` and it's using both.

Run it with:
```
sqlite3 data/comm_log.db < reconciliation.sql
```

## 4. What actually surprised me

Honestly, the `9004` thing was the one that got me — a campaign can be fully processed and look identical to any other successful send in the log, while quietly never having been approved. There's no flag on the log rows themselves; you only catch it by going back to the campaign table and checking approval status specifically. "Processed" just doesn't mean "approved," and I don't think I'd have caught that on a first read of the schema alone.

The other thing worth mentioning, even though it didn't change my final answer: the two "same customer, more than one row" situations in this data look identical on the surface — same `customer_id` showing up more than once, either against a linked campaign or the same one — but they need exactly opposite treatment. One version is a retry and should collapse to a single count; the other is a standalone re-send and shouldn't. Treat them the same way and you get a wrong number that still looks plausible.
