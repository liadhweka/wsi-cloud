# =============================================================================
# lustre-client-bootstrap.tf — Leg B client user-data wrapper.
# Applied 2026-08-20 for the current Leg-B build; validated live end-to-end
# (0 warnings, 0 fatals on that boot).
#
# Deliberately DIFFERENT from Leg A's wrapper in one structural way: there is
# no post-mount hook. The mount automation lives in the REPO, not in user-data —
# bootstrap-instance.sh's lustre branch (step 6.1) arms wsi-lustre-phase2.service,
# the baked per-boot oneshot that configures EFA, enforces the D16 gate, and
# mounts with a counter-proof. User-data therefore does ONLY the mount-
# independent half: conf file, repo clone, and the leg-aware bootstrap.
# Reasoning + decision register + manual fallback:
# docs/cloud-setup/LUSTRE-PROVISIONING.md (in the repo).
#
# Revision note (2026-08-20, from the Leg-B session review): the wrapper's
# repo-missing failure line is WSI-FATAL-prefixed so the standard triage
# (`grep WSI- /var/log/wsi-bootstrap.log`) catches the worst failure mode —
# clone failed, nothing ran. That was the only functional change; the rest is
# verbatim the applied version.
# =============================================================================

variable "wsi_s3_bucket" {
  type    = string
  default = "liad-wsi-cloud"
}
variable "wsi_repo_url" {
  type    = string
  default = "https://github.com/liadhweka/wsi-cloud.git"
}
variable "wsi_repo_branch" {
  type    = string
  default = "main"
}
variable "wsi_git_user_name" {
  type    = string
  default = "Liad Hermelin"
}
variable "wsi_git_user_email" {
  type    = string
  default = "liad.hermelin@weka.io"
}
variable "wsi_dataset_prefetch" {
  description = "none|pilot|full — datasets are already fully staged+verified in S3 from Leg A, so 'none' is correct for Leg B."
  type        = string
  default     = "none"
}
variable "wsi_ssm_prefix" {
  type    = string
  default = "/wsi-bench"
}

locals {
  wsi_lustre_client_user_data = <<EOT
#!/bin/bash
# ================= wsi-cloud Leg-B client bootstrap (wrapper) =================
exec >> /var/log/wsi-bootstrap.log 2>&1
set -x
set +e
cd /home/ec2-user 2>/dev/null || cd /
echo "=== wsi Leg-B wrapper started $(date -u) ==="

cat > /etc/wsi-bootstrap.conf <<CONF
LEG="lustre"
FSX_ID="${aws_fsx_lustre_file_system.wsi.id}"
FSX_DNS_NAME="${aws_fsx_lustre_file_system.wsi.dns_name}"
FSX_MOUNT_NAME="${aws_fsx_lustre_file_system.wsi.mount_name}"
S3_BUCKET="${var.wsi_s3_bucket}"
GIT_USER_NAME="${var.wsi_git_user_name}"
GIT_USER_EMAIL="${var.wsi_git_user_email}"
DATASET_PREFETCH="${var.wsi_dataset_prefetch}"
SSM_PREFIX="${var.wsi_ssm_prefix}"
REPO_URL="${var.wsi_repo_url}"
REPO_BRANCH="${var.wsi_repo_branch}"
CONF
chmod 644 /etc/wsi-bootstrap.conf

dnf install -y git

BOOT_USER=ec2-user
REPO_DIR=/home/$BOOT_USER/wsi-cloud
if [ ! -d "$REPO_DIR/.git" ]; then
  runuser -u $BOOT_USER -- git clone --branch "${var.wsi_repo_branch}" "${var.wsi_repo_url}" "$REPO_DIR"
else
  runuser -u $BOOT_USER -- git -C "$REPO_DIR" pull --ff-only || true
fi

if [ -f "$REPO_DIR/scripts/bootstrap-instance.sh" ]; then
  bash "$REPO_DIR/scripts/bootstrap-instance.sh"
else
  echo "WSI-FATAL: scripts/bootstrap-instance.sh not found in the repo — bootstrap did not run"
fi
echo "=== wsi Leg-B wrapper finished $(date -u) ==="
# ==============================================================================
EOT
}
