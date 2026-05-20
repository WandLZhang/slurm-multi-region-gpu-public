# Capacity Strategy

A daily-poll + multi-task-fallback strategy that an HPC admin team can run to guarantee *some* GPU capacity for researchers without a Future Reservation contract. Built around three independent tasks (Calendar Mode → Flex-Start → Spot) and one researcher-facing partition that auto-routes to whichever task is up.

---

## Task 1 — Daily Calendar Mode opportunistic grab

**Goal**: catch any H100/H100 Mega/H200/B200 Calendar window that's >7 days (past Flex's max), book it before someone else does.

**Cron job (runs 0600 UTC daily)**:
```bash
#!/bin/bash
# scripts/calendar-poll.sh
for sku in a3-ultragpu-8g a3-megagpu-8g a3-highgpu-8g a4-highgpu-8g; do
  for region in us-central1 us-south1 us-west1 us-east4 us-east5; do
    OUT=$(gcloud compute advice calendar-mode \
      --machine-type=$sku --vm-count=2 --region=$region \
      --duration-range=min=7d,max=30d \
      --start-time-range=from=$(date -u -d '+1 day' +%Y-%m-%d),to=$(date -u -d '+60 day' +%Y-%m-%d) \
      --format=json 2>/dev/null)
    # If recommendation has location set (means BOOKABLE), submit FR
    BOOKABLE=$(echo "$OUT" | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.location // empty')
    if [[ -n "$BOOKABLE" ]]; then
      START=$(echo "$OUT" | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.startTime')
      END=$(echo "$OUT" | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.endTime')
      ZONE=$(basename "$BOOKABLE")
      echo "GRAB: $sku in $ZONE, $START → $END"
      gcloud compute future-reservations create my-cal-$(date +%s) \
        --reservation-mode=CALENDAR \
        --zone=$ZONE \
        --vm-count=2 \
        --machine-type=$sku \
        --start-time="$START" \
        --end-time="$END"
    fi
  done
done
```

---

## Task 2 — Daily Flex-Start submission

**Goal**: keep one Flex-Start request in queue per target zone. When DWS has capacity, it allocates atomically.

**How many VMs to request**: the H200 Flex pool typically runs near-saturation in the busiest zones, with single-digit % free elsewhere. Match the per-zone ask to what the queue can plausibly fulfill in days, not weeks. **Submit one or two VMs per zone**, not ten.

**Cron job (runs 0600 UTC daily)**:
```bash
#!/bin/bash
# scripts/flex-poll.sh
for zone in us-south1-b us-central1-b us-east4-b us-west1-c; do
  # Skip if we already have a pending Flex request in this zone
  PENDING=$(gcloud compute reservations list --filter="zone~$zone AND specificReservation.dwsFlex.enabled=true AND status=PROVISIONING" --format='value(name)')
  if [[ -n "$PENDING" ]]; then
    echo "SKIP $zone: pending request $PENDING"
    continue
  fi
  # Submit a new 7-day Flex request for 1 VM
  gcloud compute reservations create my-flex-${zone}-$(date +%s) \
    --zone=$zone --vm-count=1 \
    --machine-type=a3-ultragpu-8g \
    --provisioning-model=FLEX_START \
    --max-run-duration=604800s
done
```

> **Note:** To determine which zones have the most Flex-Start and Spot capacity for your target SKU, use `gcloud compute advice calendar-mode` and review the [DWS Flex-Start documentation](https://docs.cloud.google.com/compute/docs/instances/use-flex-start). Capacity distribution shifts daily — run your own queries to determine the best zones for your deployment.

---

## Task 3 — Researcher `sbatch` flow

**Goal**: a researcher's `sbatch` lands on the best GPU available right now, without them caring which zone, SKU, or channel ran it. The researcher *never* triggers Calendar or Flex submissions — those are owned by Tasks 1 and 2 above. By the time `sbatch` runs, the partition has already been populated with whatever the admin's morning cron managed to provision.

The nodeset list is defined in `blueprints/cluster.yaml`. Each nodeset is assigned a Slurm `Weight` (lower = higher priority). The partition walks them in order until one returns capacity. Example structure:

| Slurm Weight | Nodeset type | SKU | Consumption mode |
| :---- | :---- | :---- | :---- |
| — | Active Calendar / Flex nodesets (when admin's cron has booked them) | varies | Non-preemptible — top of list |
| 1–4 | H200 nodesets across CONUS regions | a3-ultragpu-8g | Spot |
| 5–7 | H100 Mega nodesets across CONUS regions | a3-megagpu-8g | Spot |
| 8–11 | H100 vanilla nodesets across CONUS regions | a3-highgpu-8g | Spot |

Slurm Weight is set per-nodeset via `node_conf.Weight` in `blueprints/cluster.yaml` (lower = higher priority). Assign weights based on your own capacity analysis — prioritize zones with the deepest Spot pools for each SKU.

**How the researcher uses it**:
- Default: `sbatch script.sh` — Slurm picks the highest-priority nodeset that has capacity. The script gets whichever GPU class won the allocation.
- SKU-sensitive (e.g. needs the 141 GiB H200 specifically): `sbatch --constraint=h200 script.sh`. Each H200 nodeset has `Feature=h200,gpu` declared, each H100 Mega has `Feature=h100mega,gpu`, each H100 has `Feature=h100,gpu`, so `--constraint=h200` filters to H200 rows only.
- Pin to a specific nodeset: `sbatch --nodelist=<deployment>-h200spotsouthb-0 script.sh`.
- Multi-node H200 training: `sbatch --constraint=h200,rdma -N 2 script.sh` — picks the in-region nodeset where RDMA is wired (cross-region H200 nodesets are single-node only).

**Fast-fail Spot**: partition `ResumeTimeout=600` (10 min). If a chosen Spot nodeset can't allocate in 10 min the resume hook fails it and Slurm tries another nodeset on the next eval cycle (sub-minute). The researcher just sees a single CF (Configuring) state, not a chain of failures.

---

## Operational rhythm

| When | What | Task |
| :---- | :---- | :---- |
| 06:00 UTC daily | Calendar advice poll → grab any >7-day window | 1 |
| 06:05 UTC daily | Flex-Start submit (1 per zone, skip if pending) | 2 |
| Per researcher submit | `sbatch` → Slurm picks the partition's highest-priority nodeset that has capacity | 3 |
| Per Spot preemption | `--requeue` → resume hook → next nodeset on the list | 3 |
| Weekly | Audit Calendar reservations: cancel ones not consumed by half their window | 1 |
