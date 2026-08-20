# Leg-B EFA/mount walk — verbatim transcript (recon + gated walk + tuning), first-spinup session
# The baked automation (scripts/wsi-lustre-phase2.sh) was written from this record.
=== recon 2026-08-20T18:21:42Z ===
6.1.177-224.371.amzn2023.x86_64
NAME="Amazon Linux"
VERSION="2023"
ID="amzn"
LEG="lustre"
FSX_ID="fs-06b1492e3b7ef0455"
FSX_DNS_NAME="fs-06b1492e3b7ef0455.fsx.ap-northeast-2.amazonaws.com"
FSX_MOUNT_NAME="xeo3rbev"
S3_BUCKET="liad-wsi-cloud"
GIT_USER_NAME="Liad Hermelin"
GIT_USER_EMAIL=""
DATASET_PREFETCH="none"
SSM_PREFIX="/wsi-bench"
REPO_URL="https://github.com/liadhweka/wsi-cloud.git"
REPO_BRANCH="main"
--- lustre repo/pkg/module ---
no lustre repo yet (expected pre-walk)
Amazon Linux 2023 repository                     83 MB/s |  75 MB     00:00    
Amazon Linux 2023 NVIDIA repository              11 MB/s | 1.8 MB     00:00    
Amazon Linux 2023 Kernel Livepatch repository   630 kB/s |  69 kB     00:00    
Available Packages
Name         : lustre-client
Version      : 2.15.6
Release      : 32.amzn2023
Architecture : x86_64
Size         : 755 k
Source       : lustre-client-2.15.6-32.amzn2023.src.rpm
Repository   : amazonlinux
Summary      : Lustre File System
filename:       /lib/modules/6.1.177-224.371.amzn2023.x86_64/kernel/drivers/staging/lustrefsx/lustre/llite/lustre.ko
license:        GPL
version:        2.15.6
--- EFA ---
EFA installer not present
filename:       /lib/modules/6.1.177-224.371.amzn2023.x86_64/kernel/drivers/amazon/net/efa/efa.ko
version:        3.0.0a
--- links / lnet tools ---
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP> 
enp71s0          UP             06:8f:f9:9f:05:83 <BROADCAST,MULTICAST,UP,LOWER_UP> 
lnet tools not installed (expected)
--- nvidia ---
595.71.05
version:        2.29.4
/usr/local/cuda-12.9/targets/x86_64-linux/lib/libcufile.so
/usr/local/cuda-12.9/targets/x86_64-linux/lib/libcufile.so.0
/usr/local/cuda-12.9/targets/x86_64-linux/lib/libcufile.so.1.14.1
/usr/local/cuda-12/targets/x86_64-linux/lib/libcufile.so
/usr/local/cuda-12/targets/x86_64-linux/lib/libcufile.so.0
/usr/local/cuda-12/targets/x86_64-linux/lib/libcufile.so.1.14.1
/usr/local/cuda/targets/x86_64-linux/lib/libcufile.so
/usr/local/cuda/targets/x86_64-linux/lib/libcufile.so.0
/usr/local/cuda/targets/x86_64-linux/lib/libcufile.so.1.14.1
--- FSx describe ---
[
    "AVAILABLE",
    28800,
    "fs-06b1492e3b7ef0455.fsx.ap-northeast-2.amazonaws.com",
    "xeo3rbev",
    true,
    48000
]
--- DNS ---
10.1.1.67       fs-06b1492e3b7ef0455.fsx.ap-northeast-2.amazonaws.com
--- port 988 ---
port 988 reachable
--- EFA interface attached? ---
efa_0
mac=06:8f:f9:9f:05:83/ type=<?xml version="1.0" encoding="iso-8859-1"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
		 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
 <head>
  <title>404 - Not Found</title>
 </head>
 <body>
  <h1>404 - Not Found</h1>
 </body>
</html>
--- FSx full spec ---
[
    "AVAILABLE",
    28800,
    "PERSISTENT_2",
    1000,
    true,
    {
        "Iops": 48000,
        "Mode": "USER_PROVISIONED"
    }
]
--- PCI / drivers ---
47:00.0 Ethernet controller: Amazon.com, Inc. Elastic Network Adapter (ENA)
5c:00.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
driver: ena
version: 2.17.2g
firmware-version: 
--- fi_info presence ---
fi_info binary absent (userspace libfabric not installed)
--- ibv ---
ibv_devices absent
--- git email ---
git user.email UNSET

=== WALK STEP A: lustre-client install 2026-08-20T18:40:46Z ===
kernel before: 6.1.177-224.371.amzn2023.x86_64
Last metadata expiration check: 0:32:59 ago on Thu Aug 20 18:07:47 2026.
Dependencies resolved.
================================================================================
 Package            Arch        Version                  Repository        Size
================================================================================
Installing:
 lustre-client      x86_64      2.15.6-32.amzn2023       amazonlinux      755 k

Transaction Summary
================================================================================
Install  1 Package

Total download size: 755 k
Installed size: 2.4 M
Downloading Packages:
lustre-client-2.15.6-32.amzn2023.x86_64.rpm      16 MB/s | 755 kB     00:00    
--------------------------------------------------------------------------------
Total                                           7.7 MB/s | 755 kB     00:00     
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1 
  Installing       : lustre-client-2.15.6-32.amzn2023.x86_64                1/1 
  Running scriptlet: lustre-client-2.15.6-32.amzn2023.x86_64                1/1 
  Verifying        : lustre-client-2.15.6-32.amzn2023.x86_64                1/1================================================================================
WARNING:
  A newer release of "Amazon Linux" is available.

  Available Versions:

  Version 2023.12.20260817:
    Run the following command to upgrade to 2023.12.20260817:

      dnf upgrade --releasever=2023.12.20260817

    Release notes:
     https://docs.aws.amazon.com/linux/al2023/release-notes/relnotes-2023.12.20260817.html

================================================================================
 

Installed:
  lustre-client-2.15.6-32.amzn2023.x86_64                                       

Complete!
--- installed NVR ---
lustre-client-2.15.6-32.amzn2023.x86_64
kernel after: 6.1.177-224.371.amzn2023.x86_64
lfs 2.15.6
lctl 2.15.6
/usr/sbin/lnetctl
=== WALK STEP B: configure-efa setup.sh 2026-08-20T18:41:01Z ===
Checking python3 path: /usr/bin/python3
Found python3 executable: /usr/bin/python3
Will setup a systemd service to run configure-efa-fsx-lustre-client.py after every reboot...
Doing basic checks...
Started configure-efa-fsx-lustre-client.py at 2026-08-20 18:41:01.959432
Checking whether cmd "lfs" exists in PATH...
Checking whether cmd "lctl" exists in PATH...
Checking whether cmd "ip" exists in PATH...
Checking whether cmd "curl" exists in PATH...
Checking whether cmd "modinfo" exists in PATH...
Using Lustre client version 2.15.6
Checking TCP interface...
Found TCP interface: enp71s0
Checking EFA driver version...
Using EFA driver version 3.0.0
Detected instance type: g6e.24xlarge
Checking EFA devices...
Found 1 available EFA device(s)
Setting up cpt_config_file at /etc/modprobe.d/modprobe.conf...
	Configuration to write to /etc/modprobe.d/modprobe.conf:
# START, AUTO GENERATED BY AWS FSxL CONFIGURE EFA SCRIPT, DO NOT MODIFY
options ksocklnd credits=2560
options ptlrpc ptlrpcd_per_cpt_max=32
# END, AUTO GENERATED BY AWS FSxL CONFIGURE EFA SCRIPT
	Dry run mode - skipping file write
Checking the script path...
Copying the script to /usr/local/sbin/configure-efa-fsx-lustre-client.py...
Creating systemd service file under /etc/systemd/system/configure-efa-fsx-lustre-client.service...
[Unit]
Description=Configure EFA FSx Lustre Client
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 /usr/local/sbin/configure-efa-fsx-lustre-client.py 
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

Reloading systemd daemon...
Enabling and starting the service "configure-efa-fsx-lustre-client.service"...
Created symlink /etc/systemd/system/multi-user.target.wants/configure-efa-fsx-lustre-client.service → /etc/systemd/system/configure-efa-fsx-lustre-client.service.
--- rc=0 ---
--- systemd service state ---
enabled
active
--- modprobe.conf block written ---
# START, AUTO GENERATED BY AWS FSxL CONFIGURE EFA SCRIPT, DO NOT MODIFY
options ksocklnd credits=2560
options ptlrpc ptlrpcd_per_cpt_max=32
# END, AUTO GENERATED BY AWS FSxL CONFIGURE EFA SCRIPT
=== WALK STEP C: THE HARD GATE 2026-08-20T18:41:28Z ===
--- service journal (config run) ---
Aug 20 18:41:02 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Loading Lustre/EFA modules...
Aug 20 18:41:03 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Configuring TCP interface...
Aug 20 18:41:03 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Cleaning up existing EFA interfaces...
Aug 20 18:41:03 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Configuring EFA interfaces...
Aug 20 18:41:03 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]:         Adding in parallel the EFA interfaces ['efa_0']...
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]:         1 out of 1 cmds have succeeded.
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]:         Successfully added all EFA interfaces
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Enabling Lustre discovery...
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Setting EFA as the preferred Lustre network (udsp)...
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: Loading Lustre module...
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal python3[122779]: configure-efa-fsx-lustre-client.py: [2026-08-20 18:41:12] Successfully configured and added 1 EFA interface(s).
Aug 20 18:41:12 ip-10-1-1-61.ap-northeast-2.compute.internal systemd[1]: Finished configure-efa-fsx-lustre-client.service - Configure EFA FSx Lustre Client.
--- lnetctl net show ---
net:
    - net type: lo
      local NI(s):
        - nid: 0@lo
          status: up
    - net type: tcp
      local NI(s):
        - nid: 10.1.1.61@tcp
          status: up
          interfaces:
              0: enp71s0
    - net type: efa
      local NI(s):
        - nid: 1.61.92.0@efa
          status: up
          interfaces:
              0: efa_0
=== WALK STEP C2: LNet reachability + discovery 2026-08-20T18:41:43Z ===
--- ping MGS @tcp ---
ping:
    - primary nid: 10.1.1.67@tcp
      Multi-Rail: False
      peer ni:
        - nid: 10.1.1.67@tcp
--- discover ---
discover:
    - primary nid: 10.1.1.67@tcp
      Multi-Rail: False
      peer ni:
        - nid: 10.1.1.67@tcp
--- peer show ---
peer:
    - primary nid: 10.1.1.67@tcp
      Multi-Rail: False
      peer ni:
        - nid: 10.1.1.67@tcp
          state: NA
=== WALK STEP D1: mount 2026-08-20T18:42:02Z ===
MOUNT OK
TARGET      SOURCE                  FSTYPE OPTIONS
/mnt/lustre 10.1.1.67@tcp:/xeo3rbev lustre rw,relatime,seclabel,checksum,flock,nouser_xattr,lruresize,lazystatfs,nouser_fid2path,verbose,encrypt
--- lfs df -h ---
UUID                       bytes        Used   Available Use% Mounted on
xeo3rbev-MDT0000_UUID      549.9G       10.9M      549.9G   1% /mnt/lustre[MDT:0]
xeo3rbev-MDT0001_UUID      549.9G        7.4M      549.9G   1% /mnt/lustre[MDT:1]
xeo3rbev-MDT0002_UUID      549.9G        7.4M      549.9G   1% /mnt/lustre[MDT:2]
xeo3rbev-MDT0003_UUID      549.9G        7.4M      549.9G   1% /mnt/lustre[MDT:3]
xeo3rbev-OST0000_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:0]
xeo3rbev-OST0001_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:1]
xeo3rbev-OST0002_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:2]
xeo3rbev-OST0003_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:3]
xeo3rbev-OST0004_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:4]
xeo3rbev-OST0005_UUID        4.5T       10.0M        4.5T   1% /mnt/lustre[OST:5]

filesystem_summary:        27.0T       60.0M       27.0T   1% /mnt/lustre

--- peer show after mount (EFA evidence at peer level) ---
peer:
    - primary nid: 10.1.1.203@tcp
      Multi-Rail: True
      peer ni:
        - nid: 10.1.1.203@tcp
          state: NA
        - nid: 1.203.71.0@efa
          state: NA
    - primary nid: 10.1.1.59@tcp
      Multi-Rail: True
      peer ni:
        - nid: 10.1.1.59@tcp
          state: NA
        - nid: 1.59.71.0@efa
          state: NA
    - primary nid: 198.19.18.75@tcp1
      Multi-Rail: True
      peer ni:
        - nid: 198.19.18.75@tcp1
          state: NA
    - primary nid: 198.19.19.220@tcp1
      Multi-Rail: True
      peer ni:
        - nid: 198.19.19.220@tcp1
          state: NA
    - primary nid: 10.1.1.206@tcp
      Multi-Rail: True
      peer ni:
        - nid: 10.1.1.206@tcp
          state: NA
        - nid: 1.206.71.0@efa
          state: NA
    - primary nid: 198.19.19.175@tcp1
      Multi-Rail: True
      peer ni:
        - nid: 198.19.19.175@tcp1
          state: NA
    - primary nid: 198.19.15.59@tcp1
      Multi-Rail: True
      peer ni:
        - nid: 198.19.15.59@tcp1
          state: NA
    - primary nid: 10.1.1.88@tcp
      Multi-Rail: False
      peer ni:
        - nid: 10.1.1.88@tcp
          state: NA
    - primary nid: 10.1.1.67@tcp
      Multi-Rail: False
      peer ni:
        - nid: 10.1.1.67@tcp
          state: NA
    - primary nid: 10.1.1.140@tcp
      Multi-Rail: True
      peer ni:
        - nid: 10.1.1.140@tcp
          state: NA
        - nid: 1.140.71.0@efa
          state: NA
    - primary nid: 10.1.1.193@tcp
=== WALK STEP D2: transport-proof dd 2026-08-20T18:42:27Z ===
--- counters BEFORE ---
    - net type: tcp
              send_count: 82
              recv_count: 87
    - net type: efa
              send_count: 18
              recv_count: 18
1000+0 records in
1000+0 records out
1048576000 bytes (1.0 GB, 1000 MiB) copied, 0.90317 s, 1.2 GB/s
--- counters AFTER write ---
    - net type: tcp
              send_count: 92
              recv_count: 96
    - net type: efa
              send_count: 1018
              recv_count: 2018
--- read-back (drop nothing, direct read) ---
1000+0 records in
1000+0 records out
1048576000 bytes (1.0 GB, 1000 MiB) copied, 1.02545 s, 1.0 GB/s
--- counters AFTER read ---
    - net type: tcp
              send_count: 95
              recv_count: 99
    - net type: efa
              send_count: 3025
              recv_count: 4025
--- stripe of testfile + default dir layout ---
/mnt/lustre/testfile
  lcm_layout_gen:    5
  lcm_mirror_count:  1
  lcm_entry_count:   4
    lcme_id:             1
    lcme_mirror_id:      0
    lcme_flags:          init
    lcme_extent.e_start: 0
    lcme_extent.e_end:   104857600
      lmm_stripe_count:  1
      lmm_stripe_size:   1048576
      lmm_pattern:       raid0
      lmm_layout_gen:    0
      lmm_stripe_offset: 0
      lmm_objects:
      - 0: { l_ost_idx: 0, l_fid: [0x100000000:0x2:0x0] }

    lcme_id:             2
    lcme_mirror_id:      0
    lcme_flags:          init
--- default layout (RECORD → LUSTRE_STRIPE_LAYOUT) ---
  lcm_layout_gen:    0
  lcm_mirror_count:  1
  lcm_entry_count:   4
    lcme_id:             N/A
    lcme_mirror_id:      N/A
    lcme_flags:          0
    lcme_extent.e_start: 0
    lcme_extent.e_end:   104857600
      stripe_count:  1       stripe_size:   1048576       pattern:       raid0       stripe_offset: -1

    lcme_id:             N/A
    lcme_mirror_id:      N/A
    lcme_flags:          0
    lcme_extent.e_start: 104857600
    lcme_extent.e_end:   10737418240
      stripe_count:  8       stripe_size:   1048576       pattern:       raid0       stripe_offset: -1

    lcme_id:             N/A
    lcme_mirror_id:      N/A
    lcme_flags:          0
    lcme_extent.e_start: 10737418240
    lcme_extent.e_end:   107374182400
      stripe_count:  16       stripe_size:   1048576       pattern:       raid0       stripe_offset: -1

    lcme_id:             N/A
    lcme_mirror_id:      N/A
    lcme_flags:          0
    lcme_extent.e_start: 107374182400
    lcme_extent.e_end:   EOF
      stripe_count:  32       stripe_size:   1048576       pattern:       raid0       stripe_offset: -1

=== WALK STEP D3: fstab + data dir 2026-08-20T18:42:57Z ===
fs-06b1492e3b7ef0455.fsx.ap-northeast-2.amazonaws.com@tcp:/xeo3rbev /mnt/lustre lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=configure-efa-fsx-lustre-client.service,x-systemd.after=configure-efa-fsx-lustre-client.service 0 0
--- fstab tail ---
UUID=1B2C-1908        /boot/efi       vfat    defaults,noatime,uid=0,gid=0,umask=0077,shortname=winnt,x-systemd.automount 0 2
/dev/md/wsi-scratch /data/local-nvme xfs defaults,noatime,nofail 0 0
fs-06b1492e3b7ef0455.fsx.ap-northeast-2.amazonaws.com@tcp:/xeo3rbev /mnt/lustre lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=configure-efa-fsx-lustre-client.service,x-systemd.after=configure-efa-fsx-lustre-client.service 0 0
total 34
drwxr-xr-x. 5 ec2-user ec2-user 33280 Aug 20 18:42 .
drwxr-xr-x. 3 root     root        20 Aug 20 18:13 ..
drwxr-xr-x. 2 ec2-user ec2-user  1024 Aug 20 18:42 data
=== WALK STEP E: D-11 client tuning (AWS performance-tips, fetched 2026-08-20) 2026-08-20T18:58:11Z ===
ldlm.namespaces.xeo3rbev-OST0005-osc-ffff8c4d0cd43800.lru_max_age=600000
ldlm.namespaces.xeo3rbev-OST0005-osc-ffff8c4d0cd43800.lru_size=9600
osc.xeo3rbev-OST0005-osc-ffff8c4d0cd43800.max_rpcs_in_flight=32
mdc.xeo3rbev-MDT0003-mdc-ffff8c4d0cd43800.max_rpcs_in_flight=64
mdc.xeo3rbev-MDT0003-mdc-ffff8c4d0cd43800.max_mod_rpcs_in_flight=50
llite.xeo3rbev-ffff8c4d0cd43800.statahead_max=512
llite.xeo3rbev-ffff8c4d0cd43800.statahead_agl=1
llite.xeo3rbev-ffff8c4d0cd43800.statahead_xattr=1
--- verify applied ---
osc.xeo3rbev-OST0000-osc-ffff8c4d0cd43800.max_rpcs_in_flight=32
mdc.xeo3rbev-MDT0000-mdc-ffff8c4d0cd43800.max_rpcs_in_flight=64
mdc.xeo3rbev-MDT0001-mdc-ffff8c4d0cd43800.max_rpcs_in_flight=64
mdc.xeo3rbev-MDT0002-mdc-ffff8c4d0cd43800.max_rpcs_in_flight=64
mdc.xeo3rbev-MDT0003-mdc-ffff8c4d0cd43800.max_rpcs_in_flight=64
mdc.xeo3rbev-MDT0000-mdc-ffff8c4d0cd43800.max_mod_rpcs_in_flight=50
mdc.xeo3rbev-MDT0001-mdc-ffff8c4d0cd43800.max_mod_rpcs_in_flight=50
mdc.xeo3rbev-MDT0002-mdc-ffff8c4d0cd43800.max_mod_rpcs_in_flight=50
mdc.xeo3rbev-MDT0003-mdc-ffff8c4d0cd43800.max_mod_rpcs_in_flight=50
llite.xeo3rbev-ffff8c4d0cd43800.statahead_max=512
llite.xeo3rbev-ffff8c4d0cd43800.statahead_agl=1
llite.xeo3rbev-ffff8c4d0cd43800.statahead_xattr=1
ldlm.namespaces.xeo3rbev-OST0000-osc-ffff8c4d0cd43800.lru_max_age=600000
ldlm.namespaces.xeo3rbev-OST0000-osc-ffff8c4d0cd43800.lru_size=9600
