
-- target_base reconciliation merchant 501, October 2026

-- What this answers: for every underlying communication (a campaign
-- plus whatever retries chain off it), how many distinct customers
-- were actually reached -- with un-approved campaigns thrown out
-- entirely, and standalone (non-retried) campaigns counted send-by-send
-- rather than customer-by-customer.
--
-- Usage: sqlite3 data/comm_log.db < reconciliation.sql

-- --- indexes 
-- campaign.parent_id gets walked once per level while resolving retry
-- chains, so it earns an index. communication_log is filtered on
-- (merchant_id, communication_type, delivery_status, sent_time) and
-- then joined/grouped on (communication_id, customer_id) -- folding all
-- of that into one covering index means the engine never has to touch
-- the underlying table rows, just the index.
CREATE INDEX IF NOT EXISTS idx_campaign_parent_id
    ON campaign (parent_id);

CREATE INDEX IF NOT EXISTS idx_comm_log_lookup
    ON communication_log (
        merchant_id, communication_type, delivery_status, sent_time,
        communication_id, customer_id
    );

-- --- the query 
WITH RECURSIVE

-- Only campaigns that cleared both the approval gate and the send
-- pipeline count toward reporting at all. Anything still
-- approval_awaiting is dropped right here, before it can touch anything
-- downstream (this is what excludes campaign 9004 in the sample data).
eligible AS (
    SELECT id, parent_id
    FROM campaign
    WHERE creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND processing_status = 'processed'
),

-- Walk each eligible campaign up to the root of its retry chain.
-- A row is a chain root when it has no parent, or its parent got
-- filtered out above -- the anti-join (LEFT JOIN ... WHERE p.id IS NULL)
-- avoids the NULL-handling gotchas that `parent_id NOT IN (subquery)`
-- carries and lets the planner use the parent_id index either way.
chain (id, root_id) AS (
    SELECT e.id, e.id
    FROM eligible e
    LEFT JOIN eligible p ON p.id = e.parent_id
    WHERE p.id IS NULL

    UNION ALL

    SELECT e.id, c.root_id
    FROM eligible e
    JOIN chain c ON e.parent_id = c.id
),

-- Tag each campaign with how many eligible members its chain has.
-- A window function does this in the same pass as the recursive walk,
-- instead of a second GROUP BY + join back onto `chain`.
chain_sized AS (
    SELECT id, root_id,
           COUNT(*) OVER (PARTITION BY root_id) AS n_members
    FROM chain
),

-- Pull only the sends that matter -- delivered, right merchant,
-- right type, right month -- and attach each to its chain.
sends AS (
    SELECT cs.root_id, cs.n_members, cl.customer_id
    FROM communication_log cl
    JOIN chain_sized cs ON cs.id = cl.communication_id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = '2'
      AND cl.delivery_status = 900
      AND cl.sent_time >= '2026-10-01'
      AND cl.sent_time <  '2026-11-01'
),

-- A chain with more than one eligible member (i.e. it actually has
-- retries) counts each customer once, however many attempts it took.
-- A lone campaign with nothing chained to it counts every send as its
-- own event, repeats and all.
per_root AS (
    SELECT root_id,
           CASE WHEN n_members > 1
                THEN COUNT(DISTINCT customer_id)
                ELSE COUNT(*)
           END AS qualifying_sends
    FROM sends
    GROUP BY root_id, n_members
)

SELECT SUM(qualifying_sends) AS target_base
FROM per_root;
