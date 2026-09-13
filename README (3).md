# Comm-Log Send Reconciliation

Take-home submission — reconciling merchant 501's October 2026 send data against Finance's `target_base` metric.

**Final answer: `target_base = 22`**

## What's in here

| File | What it is |
|---|---|
| [`SUBMISSION.md`](./SUBMISSION.md) | The write-up: naive-count-to-final-number bridge, explanation of the query, and what surprised me in the data |
| [`reconciliation.sql`](./reconciliation.sql) | The runnable SQL that computes `target_base = 22` |
| [`DATA_DICTIONARY.md`](./DATA_DICTIONARY.md) | The schema/data dictionary provided with the assignment |
| [`generate_dataset.py`](./generate_dataset.py) | The script that generated the synthetic dataset (provided) |
| `data/comm_log.db`, `data/campaign.csv`, `data/communication_log.csv` | The raw data |

## How to run it

```bash
sqlite3 data/comm_log.db < reconciliation.sql
```

Start with [`SUBMISSION.md`](./SUBMISSION.md) for the full reasoning.
