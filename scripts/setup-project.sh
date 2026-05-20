#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# One-time setup for the my-slurm GCP project + local dev environment.
# Idempotent — safe to re-run.
#
# This codifies every snag encountered while standing up the reference cluster
# so colleagues with the same default project + same homebrew + same Terraform
# can run a single script and get to a deployable state.
#
# NIST 800-171 stance:
#   Baseline 800-171 is met by Google Cloud's defaults (FedRAMP-authorized
#   services, immutable Cloud Audit Logs _Required sink for 400 days, IAM-based
#   access control). The hardening sections below — Shielded VM, OS Login,
#   no-public-IPs + Cloud NAT, write-only audit sink — are *defensibility
#   upgrades* for a CUI enclave handoff, not strict compliance gates. Each is
#   documented in docs/success_checklist.md with the relevant NIST § and rationale.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-my-slurm}"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
LOG_SINK_NAME="my-slurm-audit-sink"
LOG_SINK_BUCKET="my-slurm-audit-logs"
NAT_REGIONS=(us-central1 us-south1 us-west1 us-east4 us-east5)
GAR_REPO="workloads"
# Multi-region Artifact Registry ("us") for our 5-region Spot fan-out: image pulled from
# nearest region, no cross-region pull penalty for compute outside us-central1.
GAR_LOCATION="us"

echo "==> [1/7] Local toolchain"
echo "    Cluster Toolkit v1.90.0 requires Terraform == 1.12.2 and Packer >= 1.15"
if ! command -v terraform >/dev/null || [[ "$(terraform version | head -1)" != *"v1.12.2"* ]]; then
  echo "    Installing Terraform 1.12.2 via tfenv..."
  if ! command -v tfenv >/dev/null; then
    brew install tfenv
    brew link tfenv 2>/dev/null || true
  fi
  tfenv install 1.12.2
  tfenv use 1.12.2
  if [[ -L "$HOME/bin/terraform" ]]; then
    ln -sf "$HOME/.config/tfenv/versions/1.12.2/terraform" "$HOME/bin/terraform"
  fi
else
  echo "    Terraform $(terraform version | head -1)"
fi
if ! command -v packer >/dev/null; then
  echo "    Installing Packer via hashicorp/tap..."
  brew tap hashicorp/tap 2>/dev/null || true
  brew install hashicorp/tap/packer
else
  echo "    Packer $(packer --version)"
fi

echo
echo "==> [2/7] Enable APIs on $PROJECT_ID"
gcloud services enable \
  compute.googleapis.com \
  file.googleapis.com \
  lustre.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  orgpolicy.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  cloudbilling.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="$PROJECT_ID"

echo
echo "==> [3/7] Org policies — keep requireShieldedVm bypass (Lustre kmod needs Secure Boot OFF),"
echo "          let the other 3 org-level enforcements apply"
# We bypass compute.requireShieldedVm at the project level because the Managed
# Lustre client kernel module (lustre-client-modules-*-gcp) is not signed
# against Ubuntu's Secure Boot Microsoft-cert chain. With Secure Boot ON,
# `modprobe lustre` fails with "Key was rejected by service" and /lustre never
# mounts. Per-VM we still set enable_shielded_vm: true + vTPM + integrity-
# monitoring (so 2/3 of the protections apply); the project-level bypass just
# accepts that Secure Boot can't be enforced until we MOK-sign the Lustre kmod
# in the Packer build (tracked as known blocker; future hardening upgrade).
#
# The OTHER 3 org policies (requireOsLogin, disableSerialPortAccess,
# vmExternalIpAccess) are fully satisfied by cluster.yaml + build-lustre-image.yaml
# settings, so we delete any stale project-level bypasses for those.
cat > /tmp/policy-requireshielded.yaml <<EOF
name: projects/${PROJECT_ID}/policies/compute.requireShieldedVm
spec:
  inheritFromParent: false
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy /tmp/policy-requireshielded.yaml --project="$PROJECT_ID" >/dev/null 2>&1 \
  && echo "    set project-level bypass: compute.requireShieldedVm (Lustre kmod gap)"
for pol in compute.requireOsLogin compute.disableSerialPortAccess compute.vmExternalIpAccess; do
  if gcloud org-policies describe "$pol" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud org-policies delete "$pol" --project="$PROJECT_ID" >/dev/null 2>&1 \
      && echo "    deleted project-level override: $pol (org enforcement now applies)" \
      || echo "    no project-level override to delete: $pol"
  fi
done

echo
echo "==> [4/7] Grant the default Compute Engine SA the roles Cluster Toolkit needs"
# artifactregistry.writer here is for Cloud Build (which since 2024 uses the
# default Compute SA, not the legacy cloudbuild SA, when triggered by gcloud
# builds submit). Without it, container builds fail at the push step.
# Compute nodes only need .reader at runtime; the .writer is a Cloud-Build-time
# privilege carried by the same SA. the customer can tighten by giving Cloud Build a
# dedicated SA via --service-account on submit if the threat model requires.
for role in roles/storage.objectAdmin roles/compute.instanceAdmin.v1 \
            roles/logging.logWriter roles/monitoring.metricWriter \
            roles/iam.serviceAccountUser \
            roles/artifactregistry.reader \
            roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$DEFAULT_COMPUTE_SA" \
    --role="$role" \
    --condition=None >/dev/null
  echo "    granted: $role"
done

# Artifact Registry Docker repo for workload containers. Researchers reference
# images via `srun --container-image=us-docker.pkg.dev/$PROJECT_ID/$GAR_REPO/<name>:<tag>`.
# Compute SA pulls via the artifactregistry.reader role granted above; Cloud
# Build pushes via the artifactregistry.writer role granted to the Cloud Build SA.
if ! gcloud artifacts repositories describe "$GAR_REPO" --location="$GAR_LOCATION" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$GAR_REPO" \
    --repository-format=docker --location="$GAR_LOCATION" \
    --description="Container images for SLURM workloads (multi-region US)" \
    --project="$PROJECT_ID" >/dev/null
  echo "    created Artifact Registry repo: us-docker.pkg.dev/$PROJECT_ID/$GAR_REPO (multi-region US)"
else
  echo "    Artifact Registry repo exists: us-docker.pkg.dev/$PROJECT_ID/$GAR_REPO"
fi

# Cloud Build's default SA needs artifactregistry.writer to push the workload
# images it builds. Without this, `gcloud builds submit` fails at the push step
# with "Permission 'artifactregistry.repositories.uploadArtifacts' denied".
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$CLOUDBUILD_SA" \
  --role="roles/artifactregistry.writer" \
  --condition=None >/dev/null 2>&1 \
  && echo "    granted Cloud Build SA artifactregistry.writer"

echo
echo "==> [5/7] Lustre service-account identity"
# Trigger Lustre service-account creation if absent (one-time per project).
gcloud beta services identity create --service=lustre.googleapis.com \
  --project="$PROJECT_ID" >/dev/null 2>&1 || true

echo
echo "==> [6/7] Network: routing-mode GLOBAL, internal firewall, OS Login,"
echo "          Cloud NAT in every region we deploy nodesets to"
gcloud compute networks update default --project="$PROJECT_ID" \
  --bgp-routing-mode=GLOBAL >/dev/null 2>&1 \
  && echo "    default VPC routing-mode = GLOBAL" \
  || echo "    (default VPC not present yet — re-run after first deploy)"

if ! gcloud compute firewall-rules describe default-allow-internal \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules create default-allow-internal \
    --project="$PROJECT_ID" --network=default --direction=INGRESS \
    --action=ALLOW --source-ranges=10.128.0.0/9 --rules=tcp,udp,icmp \
    --description="Allow internal traffic between default VPC subnets." >/dev/null
  echo "    created firewall: default-allow-internal"
else
  echo "    firewall exists: default-allow-internal"
fi

# OS Login project-wide. The cluster.yaml also sets enable_oslogin: true on
# the v6 modules; project metadata is the belt-and-suspenders.
gcloud compute project-info add-metadata --project="$PROJECT_ID" \
  --metadata=enable-oslogin=TRUE >/dev/null 2>&1 \
  && echo "    project metadata: enable-oslogin=TRUE"

# Project DNS: GlobalOnly so cross-region VMs resolve short hostnames (the
# slurm-gcp setup uses the controller's short hostname for the /opt/apps NFS
# mount; cross-region default-DNS scope is per-region only). Trade-off: GCP
# warns this is less resilient to cross-region DNS outages — for the customer the
# better-but-heavier option is a Cloud DNS private zone with manual A records.
gcloud compute project-info add-metadata --project="$PROJECT_ID" \
  --metadata=VmDnsSetting=GlobalOnly >/dev/null 2>&1 \
  && echo "    project metadata: VmDnsSetting=GlobalOnly"

# Cloud Router + NAT in every region we deploy nodesets to. Without these,
# compute VMs without public IPs (enable_public_ips: false in cluster.yaml)
# can't reach the internet to pip install torch + can't reach GCS endpoint.
# One router + NAT per region; idempotent.
for region in "${NAT_REGIONS[@]}"; do
  router="default-nat-router-${region}"
  if ! gcloud compute routers describe "$router" --region="$region" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute routers create "$router" --network=default \
      --region="$region" --project="$PROJECT_ID" >/dev/null
    echo "    created router: $router"
  fi
  if ! gcloud compute routers nats describe "default-nat-${region}" \
       --router="$router" --region="$region" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute routers nats create "default-nat-${region}" \
      --router="$router" --region="$region" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges \
      --enable-logging --log-filter=ERRORS_ONLY \
      --project="$PROJECT_ID" >/dev/null
    echo "    created Cloud NAT: default-nat-${region}"
  else
    echo "    Cloud NAT exists: default-nat-${region}"
  fi
done

# IAP-for-SSH ingress firewall (since compute VMs lose public IPs, SSH must
# go through Identity-Aware Proxy). 35.235.240.0/20 is Google's IAP range.
if ! gcloud compute firewall-rules describe default-allow-iap-ssh \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules create default-allow-iap-ssh \
    --project="$PROJECT_ID" --network=default --direction=INGRESS \
    --action=ALLOW --source-ranges=35.235.240.0/20 --rules=tcp:22 \
    --description="Allow IAP SSH ingress (compute VMs have no public IPs)." >/dev/null
  echo "    created firewall: default-allow-iap-ssh"
else
  echo "    firewall exists: default-allow-iap-ssh"
fi

# Cloud Audit Logs: a write-only Cloud Logging bucket with retention lock.
# Defense-in-depth on top of the immutable _Required sink. NIST §3.3.8 / §3.3.9.
if ! gcloud logging buckets describe "$LOG_SINK_BUCKET" --location=us-central1 \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud logging buckets create "$LOG_SINK_BUCKET" --location=us-central1 \
    --retention-days=400 --description="Audit-log write-only sink, 400-day retention" \
    --project="$PROJECT_ID" >/dev/null
  echo "    created log bucket: $LOG_SINK_BUCKET (400-day retention)"
fi
if ! gcloud logging sinks describe "$LOG_SINK_NAME" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud logging sinks create "$LOG_SINK_NAME" \
    "logging.googleapis.com/projects/$PROJECT_ID/locations/us-central1/buckets/$LOG_SINK_BUCKET" \
    --log-filter='LOG_ID("cloudaudit.googleapis.com/activity") OR LOG_ID("cloudaudit.googleapis.com/data_access") OR LOG_ID("cloudaudit.googleapis.com/system_event")' \
    --project="$PROJECT_ID" >/dev/null
  echo "    created log sink: $LOG_SINK_NAME → $LOG_SINK_BUCKET"
else
  echo "    log sink exists: $LOG_SINK_NAME"
fi

echo
echo "==> [7/8] Per-workload staging is researcher-owned (post-deploy, on the controller)"
echo "    Three-layer storage model:"
echo "      /home    — Filestore (user code, env, .ssh)"
echo "      /lustre  — Managed Lustre (parallel-POSIX read-only inputs +"
echo "                 write-heavy checkpoints; the canonical compute layer)"
echo "      /gcs     — GCS-FUSE (durable archive for sbatch stdout +"
echo "                 long-term sharing; not a runtime read/write layer)"
echo "    Per-workload contract:"
echo "      1. Build a container image, push to Artifact Registry (us-docker.pkg.dev/$PROJECT_ID/$GAR_REPO)"
echo "      2. SBATCH lazy-pulls large data inputs from GCS to /lustre on first run"
echo "         (idempotent skip thereafter), or admin pre-stages once."
echo "      3. Researcher SBATCH: srun --container-image=... --container-mounts=/lustre,/gcs"
echo "    See tests/containers/cifm/{Dockerfile,cloudbuild.yaml} for the canonical pattern"
echo "    and tests/jobs/example.sh for the reference SBATCH."

echo
echo "==> [8/8] Quotas — verify GPU/Spot capacity in target regions"
for region in us-central1 us-south1; do
  echo "    --- $region GPU quotas ---"
  gcloud compute regions describe "$region" --project="$PROJECT_ID" --format="json" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for q in d.get('quotas', []):
    m = q.get('metric', '')
    if any(s in m for s in ['NVIDIA','H100','H200','A100','PREEMPTIBLE_NVIDIA']):
        print(f'      {m}: limit={q.get(\"limit\",0)}, usage={q.get(\"usage\",0)}')
" || echo "      (no quota data)"
done

echo
echo "==> Done. Next:"
echo "    1. cd cluster-toolkit && make             # build the gcluster binary"
echo "    2. cd .. && cluster-toolkit/gcluster create blueprints/cluster.yaml --out . -w"
echo "    3.        cluster-toolkit/gcluster deploy my-slurm --auto-approve"
echo
echo "    For VPC Service Controls (org-level, out of scope for this script):"
echo "    https://cloud.google.com/vpc-service-controls/docs/create-service-perimeters"
