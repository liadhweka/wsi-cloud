# =============================================================================
# lustre-main.tf — Leg B: FSx for Lustre at maximum capability + the client
# Applied 2026-08-20 for the current Leg-B build (concurrent legs, D6 amended);
# this revision adds the ratified second EFA interface + the EIP it forces.
# PROPOSED from the Leg-B session (repo tmp/ transfer copy — the laptop applies);
# lands via the planned destroy -> apply, never in place (see lifecycle note).
#
# Changes in this revision, with the doc-verified reasons (fetched 2026-08-20):
#   1. Second EFA interface on network card 1, type "efa-only" (RDMA only: no IP,
#      no second netdev, no routing side-effects; kefalnd binds the RDMA device and
#      AWS's configurator enumerates /sys/class/infiniband, so it is picked up
#      automatically). EC2 rule: one EFA per network card on multi-card types.
#      Needs a recent terraform-provider-aws for "efa-only" in launch templates —
#      if plan rejects the value, "efa" also works (adds an idle netdev).
#   2. associate_public_ip_address REMOVED from the primary interface, replaced by
#      an EIP. EC2 (docs, verbatim): "You can't auto-assign a public IP address if
#      you specify more than one network interface" — and an instance with a
#      secondary interface never regains an auto-assigned public IP after a
#      stop/start. Without the EIP the bootstrap has no internet path (this VPC
#      has no NAT/endpoints) and any provisioning stop would strand the box.
#   Rebuild watch item (open-items memory A.3): with 2 EFA devices AWS's
#   configurator enables its CPT path, which requires >=1 EFA per NUMA node
#   (2 nodes on g6e.24xlarge). If EC2 wires both cards to one node it fail-louds
#   and phase-2 leaves the fs unmounted; recovery = drop change #1 and reapply.
# =============================================================================

provider "aws" {
  region = "ap-northeast-2"
}

# ── Held-constant inputs (MUST match Leg A's final environment contract) ─────
variable "client_ami_id" {
  description = "Leg A's exact AMI (contract MUST_MATCH: ami_id + kernel). Verify it still exists before apply."
  type        = string
  default     = "ami-00f6db7984ad32b20"
}
variable "client_capacity_reservation_id" {
  description = "Leg B's OWN zonal CR (g6e.24xlarge, ap-northeast-2b) — concurrent legs, one CR each. Fill with the 2b CR id."
  type        = string
  default     = "cr-070fee5d94089a02c"
}
variable "client_instance_profile_arn" {
  description = "The long-lived client profile (outside terraform; same one as Leg A — leg-agnostic by design)"
  type        = string
  default     = "arn:aws:iam::130745022161:instance-profile/wsi-liad-client-profile"
}

# ── The experiment's own knobs (STAGES.md D7: 'Lustre at maximum') ───────────
variable "fsx_storage_capacity_gib" {
  description = "EFA-enabled P2 SSD takes capacity in 4800-GiB increments at the 1000 MBps/TiB tier (AWS: 4.8 TiB steps; 9.6/19.2/38.4 for lower tiers). Spec >=25 TiB -> 28800 GiB (28.125 TiB, ~28.8 GB/s baseline). Post-create: capacity can GROW; the throughput TIER of an EFA fs is immutable."
  type        = number
  default     = 28800
}
variable "fsx_metadata_iops" {
  description = "USER_PROVISIONED metadata IOPS (valid: 1500/3000/6000/12000 + multiples of 12000, max 192000; one MDS per 12000). 48000 is the FLOOR placeholder: updates may only INCREASE (downscaling unsupported) — final value verified against Leg A's measured metadata peaks at the stage lag, raised online if needed (recorded, ratified, priced)."
  type        = number
  default     = 48000
}

# ── Networking: self-contained. ONE subnet: EFA requires client + file system
#    in the same subnet. AZ = 2b (where Leg B's CR landed; capacity-forced —
#    aws_az is reclassified MAY_DIFFER in the contract with the rationale in
#    the D6 register; each leg stays intra-AZ, which is what matters). ────────
variable "az" {
  description = "Leg B's AZ — must match the CR's zone"
  type        = string
  default     = "ap-northeast-2b"
}
resource "aws_vpc" "wsi" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "wsi-lustre-vpc" }
}
resource "aws_internet_gateway" "wsi" {
  vpc_id = aws_vpc.wsi.id
  tags   = { Name = "wsi-lustre-igw" }
}
resource "aws_subnet" "wsi" {
  vpc_id                  = aws_vpc.wsi.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "wsi-lustre-subnet" }
}
resource "aws_route_table" "wsi" {
  vpc_id = aws_vpc.wsi.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wsi.id
  }
  tags = { Name = "wsi-lustre-rt" }
}
resource "aws_route_table_association" "wsi" {
  subnet_id      = aws_subnet.wsi.id
  route_table_id = aws_route_table.wsi.id
}

# EFA-enabled SG: EFA requires ALL traffic allowed within the SG (self-
# referencing, both directions). Lustre's 988/1018-1023 are covered by the
# self rule; SSH from anywhere mirrors Leg A's posture.
# Proven live 2026-08-20: EFA traffic flowed under exactly these rules.
resource "aws_security_group" "wsi_bench_sg" {
  name        = "wsi-bench-sg"
  description = "EFA-enabled SG for FSx Lustre + client (self-ref all traffic; ssh in)"
  vpc_id      = aws_vpc.wsi.id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsi-bench-sg" }
}

# ── The file system: the ratified spec, verbatim ─────────────────────────────
resource "aws_fsx_lustre_file_system" "wsi" {
  deployment_type             = "PERSISTENT_2"
  storage_type                = "SSD"
  storage_capacity            = var.fsx_storage_capacity_gib
  per_unit_storage_throughput = 1000               # the top SSD tier
  subnet_ids                  = [aws_subnet.wsi.id]
  security_group_ids          = [aws_security_group.wsi_bench_sg.id]
  efa_enabled                 = true               # set-at-creation; requires P2 + metadata_configuration + EFA SG
  metadata_configuration {
    mode = "USER_PROVISIONED"
    iops = var.fsx_metadata_iops
  }
  tags = { Name = "wsi-lustre-leg-b" }
}

# ── The client: same silicon, same image, same profile as Leg A ──────────────
resource "aws_launch_template" "client" {
  name          = "wsi-lustre-client-lt"
  image_id      = var.client_ami_id
  instance_type = "g6e.24xlarge"
  key_name      = "liad"
  ebs_optimized = true
  iam_instance_profile { arn = var.client_instance_profile_arn }
  capacity_reservation_specification {
    capacity_reservation_target {
      capacity_reservation_id = var.client_capacity_reservation_id
    }
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      # 200 not 48: Leg A's 1.0b lost cells 35-36 to ENOSPC when telemetry
      # filled the 48 GB root mid-sweep (commit 4e17101). Root is the one
      # volume that can't be grown without a bounce; gp3 at 200 GB costs ~$16/mo.
      volume_size           = 200
      volume_type           = "gp3"
      throughput            = 250
      encrypted             = true
      delete_on_termination = true
    }
  }
  # Primary: EFA-with-ENA on network card 0 (enp71s0 + efa_0 on the validated
  # build). NO associate_public_ip_address here — impossible with a second
  # interface (see header change #2); the EIP below is the public path.
  network_interfaces {
    device_index          = 0
    interface_type        = "efa"            # the whole point of Leg B's transport
    subnet_id             = aws_subnet.wsi.id
    security_groups       = [aws_security_group.wsi_bench_sg.id]
    delete_on_termination = true
  }
  # Second EFA on network card 1 (header change #1; register L7). RDMA only.
  network_interfaces {
    device_index          = 1
    network_card_index    = 1
    interface_type        = "efa-only"
    subnet_id             = aws_subnet.wsi.id
    security_groups       = [aws_security_group.wsi_bench_sg.id]
    delete_on_termination = true
  }
  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
  }
  user_data = base64encode(local.wsi_lustre_client_user_data)
  tag_specifications {
    resource_type = "instance"
    # weka_hostgroup_type is a Leg-A leftover — kept because instance_metadata_tags
    # is enabled and nothing verified NOT to key on it; drop only after checking.
    tags          = { Name = "wsi-lustre-client", weka_hostgroup_type = "client" }
  }
}

resource "aws_instance" "client" {
  launch_template {
    id      = aws_launch_template.client.id
    version = "$Default"
  }
  tags = { Name = "wsi-lustre-client" }
  # ignore_changes: LT edits only land via destroy -> apply (the planned path);
  # an in-place apply after editing the LT would NOT touch the running instance.
  lifecycle { ignore_changes = [launch_template, user_data] }
}

# Public path: EIP on the primary interface (header change #2). Also survives
# stop/start — an auto-assigned IP would not, with a secondary interface present.
resource "aws_eip" "client" {
  domain = "vpc"
  tags   = { Name = "wsi-lustre-client" }
}
resource "aws_eip_association" "client" {
  instance_id   = aws_instance.client.id
  allocation_id = aws_eip.client.id
}

output "fsx_dns_name" { value = aws_fsx_lustre_file_system.wsi.dns_name }
output "fsx_mount_name" { value = aws_fsx_lustre_file_system.wsi.mount_name }
output "fsx_id" { value = aws_fsx_lustre_file_system.wsi.id }
output "client_public_ip" { value = aws_eip.client.public_ip }
