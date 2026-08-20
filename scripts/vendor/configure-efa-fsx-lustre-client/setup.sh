#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

PATH=/sbin:/bin:/usr/sbin:/usr/bin

CONFIGURE_ONCE="false"
SYSTEMD_ONLY="false"
SERVICE_NAME=configure-efa-fsx-lustre-client
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
CURRENT_SCRIPT_PATH=$SCRIPT_DIR/bin/${SERVICE_NAME}.py
TARGET_SCRIPT_PATH=/usr/local/sbin/${SERVICE_NAME}.py
SERVICE_FILE_PATH=/etc/systemd/system/${SERVICE_NAME}.service
PYTHON3_EXEC_PATH="/usr/bin/python3"

usage() {
    echo "\"$0\" helps you configure EFA interfaces for the FSx Lustre client. See more in README.md."
    echo ""
    echo "Usage: sudo $0 [options]"
    echo "Options:"
    echo "  --configure-once                        Do the configuration once and exit. Do not setup systemd service."
    echo "  --systemd-only                          Only setup and enable the systemd service. Do not perform actual"
    echo "                                          configurations until next reboot. Ignored if --configure-once is specified."
    echo "  --script-path                           Default ${TARGET_SCRIPT_PATH}"
    echo "  --optimized-for-gds                     Optimize EFA setup for GDS IO"
    echo "  --tcp-name <interface>                  Specify the TCP interface name to use for EFA. (default: the first"
    echo "                                          UP interface returned by 'hostname -I')"
    echo "  --disable-dmesg                         Disable dmesg output."
    echo "  --allow-no-efa                          Allow the script to continue without EFA interfaces. It still requires a EFA driver."
    echo "  --tcp-wait-time <wait_time>             Time to wait for TCP interface to be up (default: 120 seconds)."
    echo "  --tcp-wait-interval <wait_interval>     Interval between TCP interface checks (default: 10 seconds)."
    echo "  --python3-path                          Default ${PYTHON3_EXEC_PATH}"
    echo "  -h, --help                              Display this help message."
    exit 0
}

exit_with_err_msg() {
    echo "Error: $1"
    exit 1
}

# check for --help / -h option
for arg in "$@"; do
    [[ "$arg" == "--help" || "$arg" == "-h" ]] && usage && exit 0
done

if [[ $EUID -ne 0 ]]; then
    exit_with_err_msg "\"$(basename "${BASH_SOURCE[0]}")\" must be run as root. Please use sudo."
fi

check_empty_option() {
    if [[ -z "$2" || "$2" == --* ]]; then
        exit_with_err_msg "$1 requires a non-empty argument."
    fi
}

# check for setup.sh related options
declare -a other_options=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure-once)
            CONFIGURE_ONCE="true"
            shift
            ;;
        --systemd-only)
            SYSTEMD_ONLY="true"
            shift
            ;;
        --script-path)
            check_empty_option "$1" "$2"
            TARGET_SCRIPT_PATH=$2
            shift 2
            ;;
        --python3-path)
            check_empty_option "$1" "$2"
            PYTHON3_EXEC_PATH=$2
            shift 2
            ;;
        *)
            other_options+=("$1")
            shift
            ;;
    esac
done

echo "Checking python3 path: $PYTHON3_EXEC_PATH"
if command -v "$PYTHON3_EXEC_PATH" >/dev/null 2>&1; then
    echo "Found python3 executable: $PYTHON3_EXEC_PATH"
else
    exit_with_err_msg "Python3 executable not found: $PYTHON3_EXEC_PATH"
fi

if [ "$CONFIGURE_ONCE" == "true" ]; then
    echo "Running the ${SERVICE_NAME} script once and exiting."
    # run the configure script once and exit
    $PYTHON3_EXEC_PATH "${CURRENT_SCRIPT_PATH}" "${other_options[@]}"
    exit $?
else
    echo "Will setup a systemd service to run ${SERVICE_NAME}.py after every reboot..."
    set -- "${other_options[@]}"
fi

echo "Doing basic checks..."
$PYTHON3_EXEC_PATH "${CURRENT_SCRIPT_PATH}" --disable-dmesg --internal-check-only "${other_options[@]}" || exit 1

echo "Checking the script path..."
if [ -d "$TARGET_SCRIPT_PATH" ]; then
    exit_with_err_msg "$TARGET_SCRIPT_PATH is a directory. File path expected."
fi

echo "Copying the script to $TARGET_SCRIPT_PATH..."
rm -f "$TARGET_SCRIPT_PATH"
mkdir -p "$(dirname "$TARGET_SCRIPT_PATH")"
cp "$CURRENT_SCRIPT_PATH" "$TARGET_SCRIPT_PATH"

echo "Creating systemd service file under $SERVICE_FILE_PATH..."
tee $SERVICE_FILE_PATH << EOF
[Unit]
Description=Configure EFA FSx Lustre Client
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="PYTHONUNBUFFERED=1"
ExecStart=$PYTHON3_EXEC_PATH $TARGET_SCRIPT_PATH ${other_options[@]}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo ""

echo "Reloading systemd daemon..."
systemctl daemon-reload || exit_with_err_msg "Failed to reload systemd daemon."

if systemctl is-enabled --quiet ${SERVICE_NAME}.service; then
    echo "The service \"${SERVICE_NAME}.service\" is already enabled. Changes will apply on next boot. Please reboot."
    exit 0
fi

if [ "$SYSTEMD_ONLY" == "true" ]; then
    action_name="Enabling"
    systemctl_option=""
else
    action_name="Enabling and starting"
    systemctl_option="--now"
fi

echo "$action_name the service \"${SERVICE_NAME}.service\"..."
systemctl enable $systemctl_option ${SERVICE_NAME}.service ||
    exit_with_err_msg "${action_name} the service failed. The .service file is $SERVICE_FILE_PATH."
