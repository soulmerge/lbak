#!/bin/bash

# debug
# set -x

# load configuration
# TODO: remove me
. $(dirname "$0")/conf.sh

die() {
    echo $@ >&2
    exit 1
}

NOW=$(date '+%Y-%m-%d %H:%M:%S')
test -z "$LVM" && LVM=/sbin/lvm

# ensure required paths exist
mkdir -p "$TARGET"
mkdir -p "$MNT" || (mount | grep -q "$MNT" && umount "$MNT")

# ensure there is no other lbak process running
LOCK="$TARGET/.lock.lbak"
if test -f "$LOCK"; then
    ps ax | grep "^[[:space:]]*$(cat "$LOCK") " && die "Backup in progress by PID $(cat "$LOCK")"
fi
echo $$ > "$LOCK"

for LVCONF in $LVS; do
    # gather variables
    LV=${LVCONF%:*}
    SIZE=${LVCONF#*:}
    test "$SIZE" = "$LVCONF" && SIZE="1G"
    SNAPLV=$LV.lbak_snap
    FOLDER=$($LVM lvdisplay $LV | grep "LV Path" | sed 's+.*LV Path */dev/++' | tr / -)
    # remove old snap volume
    test $LVM lvdisplay $SNAPLV 2>/dev/null && $LVM lvremove -f $SNAPLV >/dev/null
    # create new snap volume
    $LVM lvcreate -L $SIZE -s $LV -n $SNAPLV >/dev/null
    # mount snap volume
    mount $SNAPLV "$MNT"
    # make local backup
        FROM="$MNT"
        TO="$TARGET/$FOLDER"
        TMPTO="$TO/_flat/$NOW (incomplete)"
        mkdir -p "$TMPTO/.lbak"
        RSYNCOPTS="--archive --delete --max-size=50M"
        test -e "$TO/latest" && RSYNCOPTS="$RSYNCOPTS --link-dest=$TO/latest"
        test -e "$FROM/.lbak-exclude" && RSYNCOPTS="$RSYNCOPTS --exclude-from=$FROM/.lbak-exclude"
        rsync $RSYNCOPTS "$FROM/" "$TMPTO"
        mv "$TMPTO" "$TO/_flat/$NOW"
        rm -f "$TO/latest"
        ln -s "_flat/$NOW" "$TO/latest"
    # done, unmount and remove snap volume
    umount "$MNT"
    $LVM lvremove -f $SNAPLV >/dev/null
    # clean up
        # (hourly data)
        mkdir -p "$TO/hourly"
        rm -f "$TO/hourly/"*
        ls "$TO/_flat" | uniq --check-chars=13 | tail -n 12 | while read BAK; do
            ln -s "../_flat/$BAK" "$TO/hourly"
        done
        # (daily data)
        mkdir -p "$TO/daily"
        rm -f "$TO/daily/"*
        ls "$TO/_flat" | uniq --check-chars=10 | tail -n 30 | while read BAK; do
            ln -s "../_flat/$BAK" "$TO/daily"
        done
        # (monthly data)
        mkdir -p "$TO/monthly"
        rm -f "$TO/monthly/"*
        ls "$TO/_flat" | uniq --check-chars=7 | tail -n 12 | while read BAK; do
            ln -s "../_flat/$BAK" "$TO/monthly"
        done
        # (yearly data)
        mkdir -p "$TO/yearly"
        rm -f "$TO/yearly/"*
        ls "$TO/_flat" | uniq --check-chars=4 | while read BAK; do
            ln -s "../_flat/$BAK" "$TO/yearly"
        done
        # remove unreferenced instances
        USED=$(find "$TO" -maxdepth 2 -mindepth 2 -type l -exec basename "{}" \;)
        for SNAPSHOT in "$TO"/_flat/*; do
            echo "$USED" | grep -q "$(basename "$SNAPSHOT")" || rm -rf "$SNAPSHOT"
        done
done

if [[ "$OFFSITE" ]]; then
    rsync --archive --compress --delete --hard-links --numeric-ids "$TARGET" "$OFFSITE"
fi

rm -f "$LOCK"
