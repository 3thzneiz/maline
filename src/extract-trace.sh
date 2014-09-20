#!/bin/bash

# Copyright 2013,2014 Marko Dimjašević, Simone Atzeni, Ivo Ugrina, Zvonimir Rakamarić
#
# This file is part of maline.
#
# maline is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# maline is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with maline.  If not, see <http://www.gnu.org/licenses/>.


# Clean up upon exiting from the process
function __sig_func {
    if [ $SPOOF -eq 1 ]; then
	kill $SMS_PID &>/dev/null
	kill $GEO_PID &>/dev/null
    fi
    exit 1
}

function get_app_pid {
    # This function will try to fetch app's PID for at most 15s
    RETRY_COUNT=60
    __APP_PID=
    for i in $(seq 1 $RETRY_COUNT); do
	# Fetch the app PID
	__APP_PID=`adb -P $ADB_SERVER_PORT shell "ps" | grep -v "USER " | grep $PROC_NAME | head -1 | awk -F" " '{print $2}'`
	if [ ! -z "$__APP_PID" ]; then
    	    break
	fi
    done
    eval "$1=$__APP_PID"
}

# Set traps
trap __sig_func SIGQUIT
trap __sig_func SIGKILL
trap __sig_func SIGTERM

# App under test
PACK_PROC_ACT=($(getAppActivityName.sh $1))
APP_NAME="${PACK_PROC_ACT[0]}"
PROC_NAME="${PACK_PROC_ACT[1]}"
ACTIVITY_NAME="${PACK_PROC_ACT[2]}"

# Console port
CONSOLE_PORT="$2"

# ADB server port
ADB_SERVER_PORT="$3"

# ADB port
ADB_PORT="$4"

# Get the current time
TIMESTAMP="$5"

# Directory where Android log files should be stored
LOG_DIR="$6"

# Main loop counter from maline.sh
COUNTER="$7"

# Number of events that should be sent to each app
EVENT_NUM="$8"

# A flag indicating whether we should spoof text messages and location
# updates
SPOOF="$9"

# get apk file name
APK_FILE_NAME=$(basename $1 .apk)

# Log file names
LOGFILE="$COUNTER-$APK_FILE_NAME-$APP_NAME-$TIMESTAMP.log"
LOGCATFILE="$COUNTER-$APK_FILE_NAME-$APP_NAME-$TIMESTAMP.logcat"

MONKEY_SEED=42

# Start the app and start tracing its system calls
echo "Starting the app... "
echo "Process name to look for: $PROC_NAME"
echo "About to start the app with the following command: am start -n ${APP_NAME}/${ACTIVITY_NAME}"
adb -P $ADB_SERVER_PORT shell "am start -n ${APP_NAME}/${ACTIVITY_NAME} && set `ps | grep $PROC_NAME` && strace -f -tt -T -p \$2 &>> /sdcard/$LOGFILE" &>/dev/null &

# Fetch app's PID
get_app_pid APP_PID

# Get the PID of the strace instance
STRACE_PID=`adb -P $ADB_SERVER_PORT shell "ps -C strace" | grep -v "USER " | awk -F" " '{print $2}'`

if [ $SPOOF -eq 1 ]; then
    echo "Also sending geo-location updates in parallel..."
    LOCATIONS_FILE="$MALINE/data/locations-list"
    GEO_COUNT=$(cat $LOCATIONS_FILE | wc -l)
    send-locations.sh $LOCATIONS_FILE 0 $GEO_COUNT $CONSOLE_PORT &
    GEO_PID=$!
    echo "Spoofing SMS text messages in paralell too..."
    MESSAGES_FILE="$MALINE/data/sms-list"
    send-all-sms.sh $MESSAGES_FILE $CONSOLE_PORT &
    SMS_PID=$!
fi

COUNT_PER_ITER=100
ITERATIONS=$(($EVENT_NUM/$COUNT_PER_ITER))

echo "Testing the app..."
echo "There will be up to $ITERATIONS iterations, each sending $COUNT_PER_ITER random events to the app"

# WARNING: linker: libdvm.so has text relocations. This is wasting memory and is a security risk. Please fix.
WARNING_MSG_PART="Please"


for i in $(seq 1 $ITERATIONS); do
    # Check if the user has interrupted the execution in the meantime
    check-adb-status.sh $ADB_SERVER_PORT $ADB_PORT || __sig_func

    ACTIVE=`adb -P $ADB_SERVER_PORT shell "ps" | grep $APP_PID`
    # Check if the app is still running. If not, stop testing and stracing
    if [ -z "$ACTIVE" ]; then
	echo "App not running any more. Stopping testing... "
	break
    fi

    # Check if the user has interrupted the execution in the meantime
    check-adb-status.sh $ADB_SERVER_PORT $ADB_PORT || __sig_func

    # Send $COUNT_PER_ITER random events to the app with Monkey, with
    # a delay between consecutive events because the Android emulator
    # is slow
    echo "Iteration $i, sending $COUNT_PER_ITER random events to the app..."
    timeout 45 adb -P $ADB_SERVER_PORT shell "monkey --throttle 100 -p $APP_NAME -s $MONKEY_SEED $COUNT_PER_ITER 2>&1 | grep -v $WARNING_MSG_PART"
    # increase the seed for the next round of events
    let MONKEY_SEED=MONKEY_SEED+1
done

if [ $SPOOF -eq 1 ]; then
    kill $SMS_PID &>/dev/null
    kill $GEO_PID &>/dev/null
fi

check-adb-status.sh $ADB_SERVER_PORT $ADB_PORT || __sig_func

adb -P $ADB_SERVER_PORT shell "kill $STRACE_PID" &>/dev/null

# Pull the logfile to the host machine
echo -n "Pulling the app system calls log file... "
mkdir -p $LOG_DIR

DEFAULT_EVENT_NUM=1000
TIME_OUT=$(echo "420 * $EVENT_NUM / $DEFAULT_EVENT_NUM" | bc)
timeout $TIME_OUT adb -P $ADB_SERVER_PORT pull /sdcard/$LOGFILE $LOG_DIR &>/dev/null && echo "done" || echo "failed"

# Remove the logfile from the device
RM_CMD="rm /sdcard/$LOGFILE"

adb -P $ADB_SERVER_PORT shell "$RM_CMD" 

# Fetch logcat log and remove it from the phone
echo -n "Pulling the app execution logcat file... "
adb -P $ADB_SERVER_PORT shell "logcat -d > /sdcard/$LOGCATFILE 2>/dev/null" && \
adb -P $ADB_SERVER_PORT pull /sdcard/$LOGCATFILE $LOG_DIR &>/dev/null && echo "done" || echo "failed"
RM_CAT_CMD="rm /sdcard/$LOGCATFILE"
adb -P $ADB_SERVER_PORT shell "$RM_CAT_CMD"

exit 0
