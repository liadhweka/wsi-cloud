## Overview
This `setup.sh` helps you
1. Import Lustre related modules
1. Configure a TCP interface (prerequisite of EFA interfaces)
1. Configure EFA interfaces
for the FSx Lustre client. This script by default sets up a systemd service (in `/etc/systemd/system/configure-efa-fsx-lustre-client.service`) to automatically do the configurations each time the client reboots.

The script needs `sudo` permission to run. It accepts the following options:

1. `--configure-once`: Run configuration immediately without creating systemd service. Use for one-time setup or manual control.
1. `--systemd-only`: Create systemd service without immediate configuration. Configuration occurs on next reboot. Ignored if `--configure-once` is used.
1. `--script-path`: Custom path for systemd service script (default: `/usr/local/sbin/configure-efa-fsx-lustre-client.sh`).
1. `--tcp-name`: Specify TCP interface name. Auto-detects first UP interface from `hostname -I` if not provided.
1. `--disable-dmesg`: Suppress error/warning messages in dmesg output
1. `--allow-no-efa`: Continue setup even if EFA interface not found. Without this flag, script exits with error code 1 when EFA unavailable. EFA driver still required.
1. `--tcp-wait-time`:  Maximum seconds to wait for TCP interface availability (default: 120 seconds)
1. `--tcp-wait-interval`: Retry interval for TCP interface checks (default: 1 second)
1. `--help`: Display help message.

### Example usage
```bash
# example 1
sudo ./setup.sh

# example 2
sudo ./setup.sh --tcp-name eth1 --tcp-wait-time 1200 --tcp-wait-interval 55 --disable-dmesg --allow-no-efa

# example 3
sudo ./setup.sh --tcp-name eth1

# example 4
sudo ./setup.sh --configure-once

# example 5
sudo ./setup.sh --configure-once --tcp-name eth1

# example 6
./setup.sh --help
```

## Helpful Systemd Cmds
To (re)enable the systemd service
```bash
sudo systemctl enable configure-efa-fsx-lustre-client.service
sudo systemctl start configure-efa-fsx-lustre-client.service
```

To check a systemd service's status:
```bash
sudo systemctl status configure-efa-fsx-lustre-client.service
```

To view the output of the systemd configure script:
```bash
# to check for possible errors/warnings
sudo dmesg
# to check entire logs
sudo journalctl -u configure-efa-fsx-lustre-client.service
```

To disable a systemd service:
```bash
sudo systemctl stop configure-efa-fsx-lustre-client.service
sudo systemctl disable configure-efa-fsx-lustre-client.service
```

## Mounting your Amazon FSx File System Automatically
You can update the `/etc/fstab` file in your Lustre Client so that it mounts your Amazon FSx file system each time it reboots. Note that mounting a filesystem depends on the EFA configurations to be finished first.

```bash
file_system_dns_name@tcp:/mountname /fsx lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=configure-efa-fsx-lustre-client.service,x-systemd.after=configure-efa-fsx-lustre-client.service 0 0
```

Add the above entry to `/etc/fstab`. See [AWS FSx Lustre User Guide](https://docs.aws.amazon.com/fsx/latest/LustreGuide/mount-fs-auto-mount-onreboot.html) for explaination of each option used above.
