#!/bin/zsh
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly PATH

if [[ "$#" -eq 1 && "$1" == "--validate-keychain-order" ]]; then
  script_path="${0:A}"
  delete_line="$(/usr/bin/grep -n '^[[:space:]]*# INSTALLED_GUARDIAN_KEYCHAIN_DELETE_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  remove_line="$(/usr/bin/grep -n '^[[:space:]]*# INSTALLED_BINARY_REMOVE_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  battery_line="$(/usr/bin/grep -n '^[[:space:]]*/usr/bin/sudo.*battery-day\.plist' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  [[ -n "$delete_line" && -n "$remove_line" && -n "$battery_line" && "$delete_line" -lt "$remove_line" && "$remove_line" -lt "$battery_line" ]] || {
    echo "Unsafe uninstall Keychain ordering" >&2; exit 65
  }
  forbidden='/usr/bin/'security
  ! /usr/bin/grep -q "$forbidden" "$script_path" || { echo "security CLI is forbidden" >&2; exit 65; }
  echo "Uninstall ordering accepted: Guardian Keychain delete, binary removal, Battery Day cleanup."
  exit 0
fi

if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 64
fi

helper_config='/Library/Application Support/Aware/helper.plist'
fresh_recovery_marker='/Library/Application Support/Aware/fresh-recovery.plist'
if [[ ! -e "$helper_config" && ! -L "$helper_config" && ( -e "$fresh_recovery_marker" || -L "$fresh_recovery_marker" ) ]]; then
  installed_guardian='/usr/local/libexec/aware/AwareGuardian'
  [[ -f "$fresh_recovery_marker" && ! -L "$fresh_recovery_marker" && "$(/usr/bin/stat -f '%u' "$fresh_recovery_marker")" == 0 ]] || { echo "Unsafe fresh-install recovery metadata" >&2; exit 65; }
  recovery_uid="$(/usr/bin/plutil -extract allowed_uid raw "$fresh_recovery_marker")"
  recovery_user="$(/usr/bin/plutil -extract installed_user raw "$fresh_recovery_marker")"
  recovery_home="$(/usr/bin/plutil -extract installed_home raw "$fresh_recovery_marker")"
  recovery_key="$(/usr/bin/plutil -extract key_id raw "$fresh_recovery_marker")"
  recovery_phase="$(/usr/bin/plutil -extract phase raw "$fresh_recovery_marker")"
  recovery_artifact_count="$(/usr/bin/plutil -extract artifact_count raw "$fresh_recovery_marker")"
  [[ "$recovery_uid" =~ '^[0-9]+$' && "$recovery_user" =~ '^[A-Za-z0-9._-]+$' && \
     "$recovery_home" == /Users/* && ! -L "$recovery_home" && "$recovery_key" =~ '^[A-Za-z0-9._-]{1,64}$' && \
     "$(/usr/bin/id -u "$recovery_user")" == "$recovery_uid" ]] || { echo "Invalid fresh-recovery identity" >&2; exit 65; }
  /bin/launchctl bootout "gui/$recovery_uid/com.aware.guardian" 2>/dev/null || true
  /bin/launchctl bootout system/com.aware.power-helper 2>/dev/null || true
  /usr/bin/pmset -a disablesleep 0
  case "$recovery_phase" in
    pre_guardian|guardian_installed) ;;
    keychain_attempted)
      [[ -f "$installed_guardian" && ! -L "$installed_guardian" ]] || { echo "Keychain-attempted recovery requires Guardian; metadata preserved" >&2; exit 70; }
      /bin/launchctl asuser "$recovery_uid" /usr/bin/sudo -u "$recovery_user" \
        "$installed_guardian" --delete-keychain "$recovery_key" || { echo "Keychain retry failed; Guardian and recovery metadata preserved" >&2; exit 70; }
      ;;
    *) echo "Unknown fresh-recovery phase" >&2; exit 65 ;;
  esac
  [[ "$recovery_artifact_count" =~ '^[0-9]+$' && "$recovery_artifact_count" -le 16 ]] || { echo "Invalid recovery manifest" >&2; exit 65; }
  for (( recovery_index=0; recovery_index<recovery_artifact_count; recovery_index++ )); do
    recovery_artifact="$(/usr/bin/plutil -extract "artifact_$recovery_index" raw "$fresh_recovery_marker")"
    [[ "$recovery_artifact" == /usr/local/libexec/aware/* || "$recovery_artifact" == '/Library/Application Support/Aware/'* || \
       "$recovery_artifact" == /Library/LaunchDaemons/com.aware.* || "$recovery_artifact" == /private/var/run/aware/* || \
       "$recovery_artifact" == "$recovery_home/Library/Application Support/Aware/"* || "$recovery_artifact" == "$recovery_home/Library/LaunchAgents/com.aware."* ]] || {
      echo "Unsafe recovery manifest path" >&2; exit 65
    }
    /bin/rm -f -- "$recovery_artifact"
  done
  /bin/rm -f -- "$fresh_recovery_marker"
  /bin/rmdir /usr/local/libexec/aware '/Library/Application Support/Aware' /private/var/run/aware 2>/dev/null || true
  echo "Incomplete fresh installation recovered and removed; reinstall is now safe."
  exit 0
fi
[[ -f "$helper_config" && ! -L "$helper_config" && "$(/usr/bin/stat -f '%u' "$helper_config")" == 0 ]] || {
  echo "Cannot safely resolve installed Aware owner from root configuration" >&2
  exit 65
}
installed_uid="$(/usr/bin/plutil -extract allowed_uid raw "$helper_config")"
installed_user="$(/usr/bin/plutil -extract installed_user raw "$helper_config")"
installed_home="$(/usr/bin/plutil -extract installed_home raw "$helper_config")"
key_id="$(/usr/bin/plutil -extract key_id raw "$helper_config")"
[[ "$installed_uid" =~ '^[0-9]+$' && "$installed_uid" -ge 500 ]] || { echo "Invalid installed UID" >&2; exit 65; }
[[ "$installed_user" =~ '^[A-Za-z0-9._-]+$' ]] || { echo "Invalid installed account" >&2; exit 65; }
[[ "$key_id" =~ '^[A-Za-z0-9._-]{1,64}$' ]] || { echo "Invalid installed key ID" >&2; exit 65; }
[[ "$(/usr/bin/id -u "$installed_user")" == "$installed_uid" ]] || { echo "Installed UID/account mismatch" >&2; exit 65; }
resolved_home="$(/usr/bin/dscl . -read "/Users/$installed_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
[[ "$installed_home" == "$resolved_home" && "$installed_home" == /Users/* && ! -L "$installed_home" && \
   "$(/usr/bin/stat -f '%u' "$installed_home")" == "$installed_uid" ]] || {
  echo "Installed home identity mismatch" >&2
  exit 65
}
agent_plist="$installed_home/Library/LaunchAgents/com.aware.guardian.plist"
installed_guardian='/usr/local/libexec/aware/AwareGuardian'
[[ -f "$installed_guardian" && ! -L "$installed_guardian" && "$(/usr/bin/stat -f '%u' "$installed_guardian")" == 0 ]] || {
  echo "Installed Guardian identity is unavailable; refusing uninstall" >&2
  exit 65
}

/bin/launchctl bootout "gui/$installed_uid/com.aware.guardian" 2>/dev/null || true
/bin/launchctl bootout system/com.aware.power-helper 2>/dev/null || true
# Required recovery invariant if a daemon is killed before its termination handler runs.
/usr/bin/pmset -a disablesleep 0
# Preserve root owner/key metadata and the installed binary identity until exact,
# idempotent Keychain deletion succeeds.
# INSTALLED_GUARDIAN_KEYCHAIN_DELETE_BOUNDARY
if ! /bin/launchctl asuser "$installed_uid" /usr/bin/sudo -u "$installed_user" \
  "$installed_guardian" --delete-keychain "$key_id"; then
  echo "Keychain deletion failed; installed owner metadata was preserved for retry" >&2
  exit 70
fi
/usr/bin/sudo -u "$installed_user" /bin/rm -f -- "$agent_plist"
/usr/bin/sudo -u "$installed_user" /bin/rm -f -- "$installed_home/Library/Application Support/Aware/guardian-state.plist"
/bin/rm -f -- /Library/LaunchDaemons/com.aware.power-helper.plist /var/run/aware/power-helper.sock
# INSTALLED_BINARY_REMOVE_BOUNDARY
for root_directory in /usr/local/libexec/aware '/Library/Application Support/Aware'; do
  if [[ -e "$root_directory" || -L "$root_directory" ]]; then
    [[ -d "$root_directory" && ! -L "$root_directory" && "$(/usr/bin/stat -f '%u' "$root_directory")" == 0 ]] || {
      echo "Refusing unsafe installed path: $root_directory" >&2
      exit 65
    }
    /bin/rm -rf -- "$root_directory"
  fi
done
/usr/bin/sudo -u "$installed_user" /bin/rm -f -- "$installed_home/Library/Application Support/Aware/battery-day.plist"
echo "Aware removed; normal sleep has been restored. User calibration/config files were preserved."
