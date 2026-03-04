#!/bin/bash

# Run silently on boot to detect temperature sensor chips on the target machine
sudo sensors-detect --auto > /dev/null 2>&1

echo ""
echo "========================================"
echo "  DiagnoSTICK - Hardware Health Report"
echo "========================================"
echo ""

# ── DRIVE HEALTH ─────────────────────────────────────────────
# Checks SMART overall status plus the four attributes that predict
# failure even when overall status shows PASSED:
# attr 5   = reallocated sectors (bad spots drive worked around)
# attr 197 = pending sectors (suspected bad, not yet confirmed)
# attr 198 = offline uncorrectable (unreadable sectors)
# attr 187 = reported uncorrect (unrecoverable read errors logged)

echo "DRIVE HEALTH"
echo "────────────"

DRIVES=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}')

if [ -z "$DRIVES" ]; then
    echo "  No drives detected."
else
    for DRIVE in $DRIVES; do
        MODEL=$(sudo smartctl -i /dev/$DRIVE 2>/dev/null | grep "Device Model\|Product:" | head -1 | cut -d: -f2 | xargs)
        [ -z "$MODEL" ] && MODEL="Unknown model"

        echo "  Drive: /dev/$DRIVE ($MODEL)"

        SMART_STATUS=$(sudo smartctl -H /dev/$DRIVE 2>/dev/null | grep "SMART overall\|SMART Health Status")
        SMART_ATTRS=$(sudo smartctl -A /dev/$DRIVE 2>/dev/null)

        REALLOCATED=$(echo "$SMART_ATTRS" | awk '/Reallocated_Sector_Ct/ {print $10+0}'); REALLOCATED=${REALLOCATED:-0}
        PENDING=$(echo "$SMART_ATTRS" | awk '/Current_Pending_Sector/ {print $10+0}');    PENDING=${PENDING:-0}
        UNCORRECTABLE=$(echo "$SMART_ATTRS" | awk '/Offline_Uncorrectable/ {print $10+0}'); UNCORRECTABLE=${UNCORRECTABLE:-0}
        REPORTED=$(echo "$SMART_ATTRS" | awk '/Reported_Uncorrect/ {print $10+0}');       REPORTED=${REPORTED:-0}
        DRIVE_TEMP=$(echo "$SMART_ATTRS" | awk '/Temperature_Celsius/ {print $10+0}' | head -1)

        if echo "$SMART_STATUS" | grep -qi "FAILED"; then
            echo "  ⚠ FAILING — This drive has reported a failure. Back up any important"
            echo "    files immediately and replace this drive."
        elif [ "$REALLOCATED" -eq 0 ] && [ "$PENDING" -eq 0 ] && [ "$UNCORRECTABLE" -eq 0 ] && [ "$REPORTED" -eq 0 ]; then
            echo "  ✓ HEALTHY — No signs of drive failure detected."
        else
            echo "  ⚠ WARNING — The drive passed its basic health check but has concerns:"
            [ "$REALLOCATED" -gt 0 ] && echo "    - $REALLOCATED bad sector(s) found and worked around. If this number grows, replace the drive."
            [ "$PENDING" -gt 0 ]     && echo "    - $PENDING sector(s) suspected bad. Back up files as a precaution."
            [ "$UNCORRECTABLE" -gt 0 ] && echo "    - $UNCORRECTABLE sector(s) could not be read. Data in those areas may be lost. Replace this drive soon."
            [ "$REPORTED" -gt 0 ]    && echo "    - $REPORTED unrecoverable read error(s) logged. Back up files and replace this drive."
        fi

        if [ ! -z "$DRIVE_TEMP" ] && [ "$DRIVE_TEMP" -gt 0 ] 2>/dev/null; then
            [ "$DRIVE_TEMP" -gt 55 ] && echo "  ⚠ Drive temperature: ${DRIVE_TEMP}°C — Too hot. Check airflow." \
                                      || echo "  ✓ Drive temperature: ${DRIVE_TEMP}°C — Normal."
        fi

        echo ""
    done
fi

# ── CPU TEMPERATURE ──────────────────────────────────────────
# sensors-detect ran at startup so sensors should be configured.
# Falls back to kernel thermal zones if sensors returns nothing.
# Thresholds: above 80°C at idle = cooling problem, 65-80°C = elevated.

echo "CPU TEMPERATURE"
echo "───────────────"

SENSOR_OUTPUT=$(sensors 2>/dev/null | grep -E "Core|Package|Tdie|CPU" | grep "°C")
MAX_TEMP=$(sensors 2>/dev/null | grep -E "Core|Package|Tdie|CPU" | grep -oP '\+\K[0-9]+(?=\.\d+°C)' | head -1 | sort -n | tail -1)

if [ ! -z "$SENSOR_OUTPUT" ] && [ ! -z "$MAX_TEMP" ]; then
    echo "$SENSOR_OUTPUT" | while read line; do echo "  $line"; done
    if   [ "$MAX_TEMP" -gt 80 ]; then echo "  ⚠ CPU is running hot (${MAX_TEMP}°C at idle). The cooling system may be blocked or failing."
    elif [ "$MAX_TEMP" -gt 65 ]; then echo "  ⚠ CPU temperature is elevated (${MAX_TEMP}°C). Consider cleaning dust from vents."
    else                               echo "  ✓ CPU temperature is normal (${MAX_TEMP}°C)."
    fi
else
    THERMAL=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    if [ ! -z "$THERMAL" ]; then
        TEMP_C=$((THERMAL / 1000))
        if   [ "$TEMP_C" -gt 80 ]; then echo "  ⚠ CPU is running hot (${TEMP_C}°C at idle). The cooling system may be blocked or failing."
        elif [ "$TEMP_C" -gt 65 ]; then echo "  ⚠ CPU temperature is elevated (${TEMP_C}°C). Consider cleaning dust from vents."
        else                             echo "  ✓ CPU temperature is normal (${TEMP_C}°C)."
        fi
    else
        echo "  Temperature data not available on this machine."
    fi
fi
echo ""

# ── BATTERY ──────────────────────────────────────────────────
# Compares current full charge capacity to original design capacity.
# Health below 60% means significant capacity loss.

echo "BATTERY"
echo "───────"

BATTERY_PATH=$(ls /sys/class/power_supply/ 2>/dev/null | grep -i "bat" | head -1)

if [ -z "$BATTERY_PATH" ]; then
    echo "  No battery detected — this is a desktop, or the battery is removed."
else
    BATT_DIR="/sys/class/power_supply/$BATTERY_PATH"

    if [ -f "$BATT_DIR/energy_full" ]; then
        FULL=$(cat $BATT_DIR/energy_full); DESIGN=$(cat $BATT_DIR/energy_full_design)
    elif [ -f "$BATT_DIR/charge_full" ]; then
        FULL=$(cat $BATT_DIR/charge_full); DESIGN=$(cat $BATT_DIR/charge_full_design)
    else
        FULL=0; DESIGN=0
    fi

    if [ "$DESIGN" -gt 0 ] 2>/dev/null; then
        HEALTH=$((FULL * 100 / DESIGN))
        STATUS=$(cat $BATT_DIR/status 2>/dev/null)
        echo "  Battery health: ${HEALTH}% of original capacity remaining"
        echo "  Current status: $STATUS"
        if   [ "$HEALTH" -ge 80 ]; then echo "  ✓ Battery is in good condition."
        elif [ "$HEALTH" -ge 60 ]; then echo "  ⚠ Battery has worn down. Expect shorter battery life than when new."
        else                             echo "  ⚠ Battery has lost significant capacity. Consider replacement."
        fi
    else
        echo "  Could not read battery capacity data."
    fi
fi
echo ""

# ── MEMORY ───────────────────────────────────────────────────
# memtester does a quick in-OS check on available RAM.
# If it finds errors, the user is offered a full test via memtest86+,
# which is bundled on the stick and tests all RAM before the OS loads.

echo "MEMORY"
echo "──────"

AVAILABLE_MB=$(free -m | awk '/^Mem:/ {print $7}')
TEST_MB=256
[ "$AVAILABLE_MB" -lt 256 ] 2>/dev/null && TEST_MB=64

echo "  Running a quick memory check (${TEST_MB}MB). This takes about 30-60 seconds..."
MEMTEST_OUTPUT=$(sudo memtester ${TEST_MB}M 1 2>&1)

if echo "$MEMTEST_OUTPUT" | grep -q "FAIL"; then
    echo ""
    echo "  ⚠ Memory errors were detected. This can cause crashes and data corruption."
    echo ""
    echo "  A full memory test can check all of your RAM more thoroughly."
    echo "  This will restart the machine into the test. It may take 30-60 minutes."
    echo "  Save any open work on this machine before continuing."
    echo ""
    read -p "  Run full memory test now? (y/n): " RUN_MEMTEST
    if [[ "$RUN_MEMTEST" =~ ^[Yy]$ ]]; then
        echo "  Launching full memory test..."
        # memtest86+ location varies by distro — adjust path if needed after testing
        sudo /boot/memtest86+x64.efi 2>/dev/null || sudo memtester 512M 3
    fi
else
    echo "  ✓ No memory errors found in quick test."
fi
echo ""

# ── FOOTER ───────────────────────────────────────────────────

echo "========================================"
echo "  Report complete."
echo "========================================"
echo ""
echo "This tool is free and open source."
echo "If you paid for this stick, ask for a refund."
echo "Build your own at: github.com/dannomack/diagnostick"
echo ""
