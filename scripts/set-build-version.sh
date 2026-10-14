git=`sh /etc/profile; which git`
branch_name=`$git rev-parse --abbrev-ref HEAD`
git_count=`$git rev-list "$branch_name" |wc -l | sed 's/^ *//;s/ *$//'`

build_number="${git_count}0"
if [ "$CONFIGURATION" != "Release" ]; then
  case "$branch_name" in
    master|release*) ;;
    *) build_number="$build_number-$branch_name" ;;
  esac
fi
if [ "$CI" = "true" ]; then
# Commit time, not build time: the app and its embedded extension run this
# script separately and their CFBundleVersion values must be identical.
build_date=`$git log -1 --format=%cd --date=format:%Y%m%d%H%M%S`
build_number="$build_date-continuous"
fi

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
dsym_plist="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
if [ -f "$dsym_plist" ] ; then
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$dsym_plist" || true
fi
