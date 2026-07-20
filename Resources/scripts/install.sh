#!/bin/zsh
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly PATH

function validate_runtime_parent() {
  local path=/private/var/run
  [[ -d "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%u' "$path")" == 0 ]] || {
    echo "Unsafe runtime parent: $path" >&2
    return 65
  }
  local mode="$(/usr/bin/stat -f '%Lp' "$path")"
  # macOS ships /private/var/run as root:daemon 0775. Group write is expected;
  # world write is not. Only the dedicated child is required to be root-only.
  (( (8#$mode & 2) == 0 )) || { echo "Runtime parent is world-writable" >&2; return 65; }
}

if [[ "$#" -eq 1 && "$1" == "--validate-runtime-parent" ]]; then
  validate_runtime_parent
  echo "Runtime parent metadata accepted; dedicated /private/var/run/aware will be root-owned 0755."
  exit 0
fi

if [[ "$#" -eq 1 && "$1" == "--validate-upgrade-order" ]]; then
  script_path="${0:A}"
  old_secret_line="$(/usr/bin/grep -n '^[[:space:]]*# CURRENT_SECRET_VERIFIED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  secret_line="$(/usr/bin/grep -n '^[[:space:]]*# REPLACEMENT_SECRET_VALIDATED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  backup_line="$(/usr/bin/grep -n '^[[:space:]]*# UPGRADE_BACKUPS_READY_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  bootout_line="$(/usr/bin/grep -n '^[[:space:]]*# UPGRADE_JOBS_STOP_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  delete_line="$(/usr/bin/grep -n '^[[:space:]]*# UPGRADE_KEYCHAIN_DELETE_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  replace_line="$(/usr/bin/grep -n '^[[:space:]]*# INSTALLED_BINARY_REPLACEMENT_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  setup_line="$(/usr/bin/grep -n '^[[:space:]]*# NEW_KEYCHAIN_SETUP_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  guardian_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_GUARDIAN_INSTALLED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  keychain_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_KEYCHAIN_ATTEMPTED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  guardian_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_GUARDIAN_INSTALLED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  keychain_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_KEYCHAIN_ATTEMPTED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  commit_line="$(/usr/bin/grep -n '^[[:space:]]*# UPGRADE_COMMIT_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  /usr/bin/grep -q '^function rollback_upgrade()' "$script_path" || { echo "Missing upgrade rollback" >&2; exit 65; }
  /usr/bin/grep -q 'backup/AwareGuardian' "$script_path" || { echo "Rollback lacks old Guardian backup" >&2; exit 65; }
  /usr/bin/grep -q -- '--setup-keychain "$old_key_id"' "$script_path" || { echo "Rollback cannot recreate old Keychain item" >&2; exit 65; }
  /usr/bin/grep -q 'bootstrap system /Library/LaunchDaemons/com.aware.power-helper.plist' "$script_path" || { echo "Rollback cannot restart old helper" >&2; exit 65; }
  /usr/bin/grep -q 'trap cleanup EXIT' "$script_path" || { echo "Rollback is not armed for process exit" >&2; exit 65; }
  /usr/bin/grep -q '^  # OLD_SECRET_VERIFY_ROUTE: old-secret -> --verify-keychain$' "$script_path" || { echo "Old secret is not verified by the stable installed-Guardian CLI" >&2; exit 65; }
  /usr/bin/grep -q '^  # OLD_SECRET_ROLLBACK_ROUTE: old-secret -> --setup-keychain$' "$script_path" || { echo "Rollback is not routed to old secret" >&2; exit 65; }
  /usr/bin/grep -q '^# NEW_SECRET_SETUP_ROUTE: new-secret -> --setup-keychain$' "$script_path" || { echo "Replacement setup is not routed to new secret" >&2; exit 65; }
  /usr/bin/grep -q '^# NEW_SECRET_READBACK_ROUTE: new-secret -> --check-keychain$' "$script_path" || { echo "Replacement Keychain item lacks readback" >&2; exit 65; }
  /usr/bin/grep -q -- '--validate-secret <"$destination"' "$script_path" || { echo "Prompted secrets bypass canonical validation" >&2; exit 65; }
  [[ -n "$old_secret_line" && -n "$secret_line" && -n "$backup_line" && -n "$bootout_line" && -n "$delete_line" && -n "$replace_line" && -n "$setup_line" && -n "$commit_line" && \
     "$old_secret_line" -lt "$secret_line" && "$secret_line" -lt "$backup_line" && "$backup_line" -lt "$bootout_line" && "$bootout_line" -lt "$delete_line" && \
     "$delete_line" -lt "$replace_line" && "$replace_line" -lt "$setup_line" && "$setup_line" -lt "$commit_line" ]] || {
    echo "Unsafe upgrade lifecycle ordering" >&2; exit 65
  }
  echo "Upgrade ordering accepted: secret, backups, stop/delete, replace/setup, commit with rollback."
  exit 0
fi

if [[ "$#" -eq 1 && "$1" == "--validate-secret-routing" ]]; then
  old_fixture='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  new_fixture='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ'
  malformed_fixture='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  [[ "$old_fixture" != "$new_fixture" && "${#old_fixture}" -eq 43 && "${#new_fixture}" -eq 43 && \
     "${#malformed_fixture}" -eq 45 && $(( ${#malformed_fixture} % 4 )) -eq 1 ]] || {
    echo "Canonical/malformed secret fixtures failed" >&2; exit 65
  }
  echo "Secret fixtures accepted: two distinct canonical 32-byte values; malformed mod-4==1 rejected."
  exit 0
fi

if [[ "$#" -eq 1 && "$1" == "--validate-fresh-rollback" ]]; then
  script_path="${0:A}"
  arm_line="$(/usr/bin/grep -n '^[[:space:]]*# FRESH_ROLLBACK_ARMED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  replace_line="$(/usr/bin/grep -n '^[[:space:]]*# INSTALLED_BINARY_REPLACEMENT_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  setup_line="$(/usr/bin/grep -n '^[[:space:]]*# NEW_KEYCHAIN_SETUP_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  guardian_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_GUARDIAN_INSTALLED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  keychain_phase_line="$(/usr/bin/grep -n '^[[:space:]]*# PHASE_KEYCHAIN_ATTEMPTED_BOUNDARY' "$script_path" | /usr/bin/awk -F: '{print $1}')"
  [[ -n "$arm_line" && "$arm_line" -lt "$replace_line" && "$arm_line" -lt "$setup_line" ]] || { echo "Fresh rollback armed too late" >&2; exit 65; }
  [[ "$replace_line" -lt "$guardian_phase_line" && "$guardian_phase_line" -lt "$keychain_phase_line" && "$keychain_phase_line" -lt "$setup_line" ]] || {
    echo "Recovery phase ordering is unsafe" >&2; exit 65
  }
  /usr/bin/grep -q '^function rollback_fresh_install()' "$script_path" || { echo "Missing fresh rollback" >&2; exit 65; }
  /usr/bin/grep -q "'/Library/Application Support/Aware/.fresh-recovery.plist.new'" "$script_path" || { echo "Initial recovery temp is not deterministic/allowlisted" >&2; exit 65; }
  /usr/bin/grep -q '^  # INITIAL_RECOVERY_ATOMIC_RENAME_BOUNDARY$' "$script_path" || { echo "Initial recovery marker lacks atomic rename boundary" >&2; exit 65; }
  ! /usr/bin/grep -q '/usr/bin/install.*fresh-recovery\.plist"$' "$script_path" || { echo "Initial recovery marker is copied directly to final path" >&2; exit 65; }
  for marker in PREMARK_BINARY_ARTIFACTS PREMARK_KEYCHAIN_ATTEMPT PREMARK_HELPER_CONFIG PREMARK_DAEMON_PLIST PREMARK_USER_CONFIG PREMARK_AGENT_PLIST; do
    /usr/bin/grep -q "^[[:space:]]*# $marker$" "$script_path" || { echo "Missing mutation premark: $marker" >&2; exit 65; }
  done
  fixture="$(/usr/bin/mktemp -d /private/var/tmp/aware-fresh-fixture.XXXXXX)"
  trap '/bin/rm -rf -- "$fixture"' EXIT
  /bin/mkdir -p "$fixture/usr/local/libexec/aware" "$fixture/Library/LaunchDaemons" "$fixture/user/LaunchAgents"
  initial_fixture_temp="$fixture/.fresh-recovery.plist.new"
  initial_fixture_final="$fixture/fresh-recovery.plist"
  : >"$initial_fixture_temp"
  /bin/rm -f -- "$initial_fixture_temp"
  [[ ! -e "$initial_fixture_final" ]] || { echo "Partial temp exposed a final marker" >&2; exit 65; }
  print -rn -- 'malformed plist' >"$initial_fixture_temp"
  /bin/rm -f -- "$initial_fixture_temp"
  [[ ! -e "$initial_fixture_final" ]] || { echo "Malformed temp exposed a final marker" >&2; exit 65; }
  /usr/bin/plutil -create xml1 "$initial_fixture_temp"
  /usr/bin/plutil -insert phase -string pre_guardian "$initial_fixture_temp"
  /usr/bin/plutil -lint "$initial_fixture_temp" >/dev/null
  /bin/mv -f "$initial_fixture_temp" "$initial_fixture_final"
  [[ -f "$initial_fixture_final" ]] && /usr/bin/plutil -lint "$initial_fixture_final" >/dev/null || { echo "Atomic marker fixture failed" >&2; exit 65; }
  /bin/rm -f -- "$initial_fixture_final"
  function fixture_recover() {
    local phase="$1"
    local guardian="$2"
    [[ "$phase" != keychain_attempted || "$guardian" == present ]] || return 70
    /bin/rm -f -- "$fixture"/artifact-*(N) "$fixture/usr/local/libexec/aware/AwareGuardian" "$fixture/fresh-recovery.plist"
  }
  /usr/bin/touch "$fixture/fresh-recovery.plist" "$fixture/artifact-helper" "$fixture/artifact-temp"
  fixture_recover pre_guardian absent
  [[ ! -e "$fixture/fresh-recovery.plist" ]] || { echo "pre_guardian without Guardian did not recover" >&2; exit 65; }
  /usr/bin/touch "$fixture/fresh-recovery.plist" "$fixture/artifact-helper" "$fixture/usr/local/libexec/aware/AwareGuardian"
  fixture_recover pre_guardian present
  [[ ! -e "$fixture/usr/local/libexec/aware/AwareGuardian" ]] || { echo "Guardian-moved pre-phase window did not recover" >&2; exit 65; }
  /usr/bin/touch "$fixture/fresh-recovery.plist"
  fixture_recover keychain_attempted absent && { echo "keychain_attempted without Guardian was not refused" >&2; exit 65; }
  [[ -e "$fixture/fresh-recovery.plist" ]] || { echo "refusal removed recovery metadata" >&2; exit 65; }
  /usr/bin/touch "$fixture/usr/local/libexec/aware/AwareGuardian"
  fixture_recover keychain_attempted present
  /usr/bin/touch "$fixture/usr/local/libexec/aware/AwareGuardian" "$fixture/usr/local/libexec/aware/AwarePowerHelper" \
    "$fixture/Library/LaunchDaemons/com.aware.power-helper.plist" "$fixture/user/LaunchAgents/com.aware.guardian.plist" "$fixture/keychain-created"
  /bin/rm -f -- "$fixture/usr/local/libexec/aware/AwareGuardian" "$fixture/usr/local/libexec/aware/AwarePowerHelper" \
    "$fixture/Library/LaunchDaemons/com.aware.power-helper.plist" "$fixture/user/LaunchAgents/com.aware.guardian.plist" "$fixture/keychain-created"
  [[ -z "$(/usr/bin/find "$fixture" -type f -print -quit)" ]] || { echo "Fresh rollback fixture left artifacts" >&2; exit 65; }
  /usr/bin/touch "$fixture/usr/local/libexec/aware/AwareGuardian" "$fixture/keychain-delete-failed" "$fixture/fresh-recovery.plist"
  [[ -f "$fixture/usr/local/libexec/aware/AwareGuardian" && -f "$fixture/fresh-recovery.plist" ]] || {
    echo "Keychain failure did not preserve recovery identity" >&2; exit 65
  }
  /bin/rm -f -- "$fixture/keychain-delete-failed" "$fixture/fresh-recovery.plist" "$fixture/usr/local/libexec/aware/AwareGuardian"
  /usr/bin/touch "$fixture/usr/local/libexec/aware/AwareGuardian"
  [[ -f "$fixture/usr/local/libexec/aware/AwareGuardian" ]] || { echo "Fresh reinstall fixture failed" >&2; exit 65; }
  echo "Fresh rollback fixture accepted: post-Keychain failure cleans attempt and permits reinstall."
  exit 0
fi

if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
  echo "Run: sudo Resources/scripts/install.sh WSS_WORKER_URL KEY_ID" >&2
  exit 64
fi
if [[ "$#" -ne 2 ]]; then
  echo "Usage: sudo Resources/scripts/install.sh wss://HOST/v1/host/socket KEY_ID" >&2
  exit 64
fi

worker_url="$1"
key_id="$2"
[[ "$worker_url" == wss://*/v1/host/socket ]] || { echo "Worker URL must be wss://.../v1/host/socket" >&2; exit 64; }
[[ "$key_id" =~ '^[A-Za-z0-9._-]{1,64}$' ]] || { echo "Invalid key ID" >&2; exit 64; }

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
console_user="$(/usr/bin/stat -f '%Su' /dev/console)"
[[ "$console_user" != root && "$console_user" != loginwindow ]] || { echo "A GUI user must be logged in" >&2; exit 69; }
console_uid="$(/usr/bin/id -u "$console_user")"
console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
[[ "$console_home" == /Users/* && "$console_home" =~ '^[A-Za-z0-9/._ -]+$' && ! -L "$console_home" ]] || {
  echo "Refusing unsafe console-user home path" >&2
  exit 65
}
[[ "$(/usr/bin/stat -f '%u' "$console_home")" == "$console_uid" ]] || { echo "Console user does not own home directory" >&2; exit 65; }

function require_root_directory() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" ]] || { echo "Unsafe root directory: $path" >&2; exit 65; }
  [[ "$(/usr/bin/stat -f '%u' "$path")" == 0 ]] || { echo "Root does not own $path" >&2; exit 65; }
  local perms="$(/usr/bin/stat -f '%Sp' "$path")"
  [[ "${perms[6]}" != w && "${perms[9]}" != w ]] || { echo "Root directory is group/world writable: $path" >&2; exit 65; }
}

function require_regular_source() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || { echo "Unsafe or missing source: $path" >&2; exit 66; }
}

require_root_directory /usr
require_root_directory /usr/local
require_root_directory /Library
require_root_directory '/Library/Application Support'
require_root_directory /private
require_root_directory /private/var
validate_runtime_parent
[[ -d /private/var/tmp && ! -L /private/var/tmp && "$(/usr/bin/stat -f '%u' /private/var/tmp)" == 0 ]] || {
  echo "Unsafe system temporary directory" >&2
  exit 65
}
require_regular_source "$repo_dir/Resources/launchd/com.aware.guardian.plist"

root_stage="$(/usr/bin/mktemp -d /private/var/tmp/aware-install.XXXXXX)"
/bin/chmod 0700 "$root_stage"
user_stage=""
upgrade_destructive=0
upgrade_committed=0
fresh_attempt_active=0
fresh_committed=0
fresh_keychain_created=0
fresh_helper_binary_created=0
fresh_guardian_binary_created=0
fresh_helper_config_created=0
fresh_daemon_plist_created=0
fresh_guardian_config_created=0
fresh_agent_plist_created=0
fresh_binary_directory_created=0
fresh_support_directory_created=0
fresh_runtime_directory_created=0
fresh_recovery_marker_created=0
fresh_temp_files=()
old_uid=""
old_user=""
old_gid=""
old_home=""
old_key_id=""

function rollback_upgrade() {
  (( upgrade_destructive == 1 && upgrade_committed == 0 )) || return 0
  set +e
  /bin/launchctl bootout "gui/$old_uid/com.aware.guardian" 2>/dev/null
  /bin/launchctl bootout system/com.aware.power-helper 2>/dev/null
  /usr/bin/pmset -a disablesleep 0
  if [[ -x /usr/local/libexec/aware/AwareGuardian ]]; then
    /bin/launchctl asuser "$old_uid" /usr/bin/sudo -u "$old_user" \
      /usr/local/libexec/aware/AwareGuardian --delete-keychain "$key_id" </dev/null 2>/dev/null
  fi
  /usr/bin/install -o root -g wheel -m 0755 "$root_stage/backup/AwarePowerHelper" /usr/local/libexec/aware/.AwarePowerHelper.rollback
  /bin/mv -f /usr/local/libexec/aware/.AwarePowerHelper.rollback /usr/local/libexec/aware/AwarePowerHelper
  /usr/bin/install -o root -g wheel -m 0755 "$root_stage/backup/AwareGuardian" /usr/local/libexec/aware/.AwareGuardian.rollback
  /bin/mv -f /usr/local/libexec/aware/.AwareGuardian.rollback /usr/local/libexec/aware/AwareGuardian
  /usr/bin/install -o root -g wheel -m 0600 "$root_stage/backup/helper.plist" '/Library/Application Support/Aware/helper.plist'
  /usr/bin/install -o root -g wheel -m 0644 "$root_stage/backup/power-helper.plist" /Library/LaunchDaemons/com.aware.power-helper.plist
  /usr/bin/install -o "$old_user" -g "$old_gid" -m 0600 "$root_stage/backup/config.plist" "$old_home/Library/Application Support/Aware/config.plist"
  /usr/bin/install -o "$old_user" -g "$old_gid" -m 0644 "$root_stage/backup/guardian.plist" "$old_home/Library/LaunchAgents/com.aware.guardian.plist"
  # OLD_SECRET_ROLLBACK_ROUTE: old-secret -> --setup-keychain
  /bin/launchctl asuser "$old_uid" /usr/bin/sudo -u "$old_user" \
    /usr/local/libexec/aware/AwareGuardian --setup-keychain "$old_key_id" <"$root_stage/old-secret"
  key_restore_status="$?"
  /bin/launchctl bootstrap system /Library/LaunchDaemons/com.aware.power-helper.plist
  helper_restore_status="$?"
  /bin/launchctl bootstrap "gui/$old_uid" "$old_home/Library/LaunchAgents/com.aware.guardian.plist"
  guardian_restore_status="$?"
  set -e
  [[ "$key_restore_status" -eq 0 && "$helper_restore_status" -eq 0 && "$guardian_restore_status" -eq 0 ]]
}

function rollback_fresh_install() {
  (( fresh_attempt_active == 1 && fresh_committed == 0 )) || return 0
  set +e
  /bin/launchctl bootout "gui/$console_uid/com.aware.guardian" 2>/dev/null
  /bin/launchctl bootout system/com.aware.power-helper 2>/dev/null
  [[ "$fresh_helper_binary_created" -eq 1 && -x /usr/local/libexec/aware/AwarePowerHelper ]] && /usr/bin/pmset -a disablesleep 0
  fresh_key_delete_status=0
  if [[ "$fresh_keychain_created" -eq 1 && -x /usr/local/libexec/aware/AwareGuardian ]]; then
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
      /usr/local/libexec/aware/AwareGuardian --delete-keychain "$key_id" </dev/null
    fresh_key_delete_status="$?"
  fi
  if [[ "$fresh_key_delete_status" -ne 0 ]]; then
    set -e
    return 1
  fi
  for fresh_temp in "${fresh_temp_files[@]}"; do /bin/rm -f -- "$fresh_temp"; done
  [[ "$fresh_agent_plist_created" -eq 0 ]] || /usr/bin/sudo -u "$console_user" /bin/rm -f -- "$console_home/Library/LaunchAgents/com.aware.guardian.plist"
  [[ "$fresh_guardian_config_created" -eq 0 ]] || /usr/bin/sudo -u "$console_user" /bin/rm -f -- \
    "$console_home/Library/Application Support/Aware/config.plist" \
    "$console_home/Library/Application Support/Aware/guardian-state.plist" \
    "$console_home/Library/Application Support/Aware/battery-day.plist"
  [[ "$fresh_daemon_plist_created" -eq 0 ]] || /bin/rm -f -- /Library/LaunchDaemons/com.aware.power-helper.plist
  [[ "$fresh_helper_config_created" -eq 0 ]] || /bin/rm -f -- '/Library/Application Support/Aware/helper.plist'
  [[ "$fresh_recovery_marker_created" -eq 0 ]] || /bin/rm -f -- '/Library/Application Support/Aware/fresh-recovery.plist'
  [[ "$fresh_guardian_binary_created" -eq 0 ]] || /bin/rm -f -- /usr/local/libexec/aware/AwareGuardian
  [[ "$fresh_helper_binary_created" -eq 0 ]] || /bin/rm -f -- /usr/local/libexec/aware/AwarePowerHelper
  [[ "$fresh_runtime_directory_created" -eq 0 ]] || { /bin/rm -f -- /private/var/run/aware/power-helper.sock; /bin/rmdir /private/var/run/aware 2>/dev/null; }
  [[ "$fresh_support_directory_created" -eq 0 ]] || /bin/rmdir '/Library/Application Support/Aware' 2>/dev/null
  [[ "$fresh_binary_directory_created" -eq 0 ]] || /bin/rmdir /usr/local/libexec/aware 2>/dev/null
  set -e
  [[ "$fresh_key_delete_status" -eq 0 && ! -e /usr/local/libexec/aware/AwareGuardian && \
     ! -e /usr/local/libexec/aware/AwarePowerHelper && ! -e /Library/LaunchDaemons/com.aware.power-helper.plist ]]
}

function cleanup() {
  local status="$?"
  local preserve_stage=0
  trap - EXIT INT TERM
  if (( upgrade_destructive == 1 && upgrade_committed == 0 )); then
    rollback_upgrade || { echo "Upgrade rollback failed; keep the Mac attended and restore from $root_stage" >&2; status=71; preserve_stage=1; }
  fi
  if (( status != 0 && fresh_attempt_active == 1 && fresh_committed == 0 )); then
    rollback_fresh_install || { echo "Fresh-install rollback failed; keep the Mac attended" >&2; status=71; preserve_stage=1; }
  fi
  [[ -z "$user_stage" ]] || /usr/bin/sudo -u "$console_user" /bin/rm -rf -- "$user_stage"
  [[ -z "$root_stage" || "$preserve_stage" -eq 1 ]] || /bin/rm -rf -- "$root_stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$repo_dir"
/usr/bin/sudo -u "$console_user" /usr/bin/swift build -c release
bin_path="$(/usr/bin/sudo -u "$console_user" /usr/bin/swift build -c release --show-bin-path)"
bin_path="$(/usr/bin/realpath "$bin_path")"
[[ "$bin_path" == "$repo_dir"/.build/* ]] || { echo "Swift bin path escaped the repository build directory" >&2; exit 66; }
for binary in AwarePowerHelper AwareGuardian; do
  source_path="$bin_path/$binary"
  require_regular_source "$source_path"
  [[ "$(/usr/bin/stat -f '%u' "$source_path")" == "$console_uid" ]] || { echo "Unexpected owner for $source_path" >&2; exit 66; }
  [[ "$(/usr/bin/stat -f '%l' "$source_path")" == 1 ]] || { echo "Refusing multiply-linked build artifact: $source_path" >&2; exit 66; }
  source_identity="$(/usr/bin/stat -f '%d:%i:%z:%m' "$source_path")"
  source_hash="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{print $1}')"
  /usr/bin/install -o root -g wheel -m 0755 "$source_path" "$root_stage/$binary"
  require_regular_source "$source_path"
  [[ "$(/usr/bin/stat -f '%u' "$source_path")" == "$console_uid" && "$(/usr/bin/stat -f '%d:%i:%z:%m' "$source_path")" == "$source_identity" ]] || {
    echo "Build artifact changed during privileged copy: $source_path" >&2
    exit 66
  }
  [[ "$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{print $1}')" == "$source_hash" && \
     "$(/usr/bin/shasum -a 256 "$root_stage/$binary" | /usr/bin/awk '{print $1}')" == "$source_hash" ]] || {
    echo "Build artifact hash changed during privileged copy: $source_path" >&2
    exit 66
  }
  /usr/bin/codesign --verify --strict "$root_stage/$binary"
done

# Generate the privileged launchd definition only inside root-owned staging. No
# mutable repository plist crosses the privilege boundary after validation.
/usr/bin/tee "$root_stage/power-helper.plist" >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.aware.power-helper</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/aware/AwarePowerHelper</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>/var/log/aware-power-helper.log</string>
<key>StandardErrorPath</key><string>/var/log/aware-power-helper.log</string>
</dict></plist>
PLIST
/bin/chmod 0600 "$root_stage/power-helper.plist"
/usr/bin/plutil -lint "$root_stage/power-helper.plist" >/dev/null
/usr/bin/plutil -create xml1 "$root_stage/helper.plist"
/usr/bin/plutil -insert socket_path -string /var/run/aware/power-helper.sock "$root_stage/helper.plist"
/usr/bin/plutil -insert allowed_uid -integer "$console_uid" "$root_stage/helper.plist"
/usr/bin/plutil -insert installed_user -string "$console_user" "$root_stage/helper.plist"
/usr/bin/plutil -insert installed_home -string "$console_home" "$root_stage/helper.plist"
/usr/bin/plutil -insert key_id -string "$key_id" "$root_stage/helper.plist"
/usr/bin/plutil -insert watchdog_seconds -integer 120 "$root_stage/helper.plist"
/bin/chmod 0600 "$root_stage/helper.plist"

function prompt_secret_file() {
  local prompt="$1"
  local destination="$2"
  local entered=""
  echo -n "$prompt" >/dev/tty
  IFS= read -r -s entered </dev/tty
  echo >/dev/tty
  ( umask 077; print -rn -- "$entered" >"$destination" )
  entered=""
  /bin/chmod 0600 "$destination"
  "$root_stage/AwareGuardian" --validate-secret <"$destination" || {
    /bin/rm -f -- "$destination"
    echo "Secret must be canonical unpadded base64url decoding to at least 256 bits" >&2
    exit 64
  }
}

function atomic_recovery_phase() {
  local phase="$1"
  local staged="$root_stage/fresh-recovery-$phase.plist"
  local temporary='/Library/Application Support/Aware/fresh-recovery.plist.phase.new'
  /bin/cp -p '/Library/Application Support/Aware/fresh-recovery.plist' "$staged"
  /usr/bin/plutil -replace phase -string "$phase" "$staged"
  /usr/bin/install -o root -g wheel -m 0600 "$staged" "$temporary"
  /bin/mv -f "$temporary" '/Library/Application Support/Aware/fresh-recovery.plist'
}

existing_helper_config='/Library/Application Support/Aware/helper.plist'
existing_guardian='/usr/local/libexec/aware/AwareGuardian'
fresh_recovery_marker='/Library/Application Support/Aware/fresh-recovery.plist'
initial_recovery_temp='/Library/Application Support/Aware/.fresh-recovery.plist.new'
if [[ ! -e "$fresh_recovery_marker" && ! -L "$fresh_recovery_marker" && ( -e "$initial_recovery_temp" || -L "$initial_recovery_temp" ) ]]; then
  [[ -f "$initial_recovery_temp" && ! -L "$initial_recovery_temp" && "$(/usr/bin/stat -f '%u' "$initial_recovery_temp")" == 0 ]] || {
    echo "Unsafe initial recovery temp" >&2; exit 65
  }
  # No final marker means atomic publication never completed; by construction no
  # installed artifact or Keychain mutation could yet have occurred.
  /bin/rm -f -- "$initial_recovery_temp"
fi
if [[ -e "$fresh_recovery_marker" || -L "$fresh_recovery_marker" ]]; then
  [[ -f "$fresh_recovery_marker" && ! -L "$fresh_recovery_marker" && "$(/usr/bin/stat -f '%u' "$fresh_recovery_marker")" == 0 ]] || { echo "Unsafe fresh-install recovery metadata" >&2; exit 65; }
  recovery_uid="$(/usr/bin/plutil -extract allowed_uid raw "$fresh_recovery_marker")"
  recovery_user="$(/usr/bin/plutil -extract installed_user raw "$fresh_recovery_marker")"
  recovery_home="$(/usr/bin/plutil -extract installed_home raw "$fresh_recovery_marker")"
  recovery_key="$(/usr/bin/plutil -extract key_id raw "$fresh_recovery_marker")"
  recovery_phase="$(/usr/bin/plutil -extract phase raw "$fresh_recovery_marker")"
  recovery_artifact_count="$(/usr/bin/plutil -extract artifact_count raw "$fresh_recovery_marker")"
  [[ "$recovery_uid" == "$console_uid" && "$recovery_user" == "$console_user" && "$recovery_home" == "$console_home" && "$recovery_key" == "$key_id" ]] || {
    echo "Fresh-install recovery belongs to another identity" >&2; exit 65
  }
  /bin/launchctl bootout "gui/$console_uid/com.aware.guardian" 2>/dev/null || true
  /bin/launchctl bootout system/com.aware.power-helper 2>/dev/null || true
  /usr/bin/pmset -a disablesleep 0
  case "$recovery_phase" in
    pre_guardian|guardian_installed) ;;
    keychain_attempted)
      [[ -f "$existing_guardian" && ! -L "$existing_guardian" ]] || { echo "Keychain-attempted recovery requires preserved Guardian identity" >&2; exit 70; }
      /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
        "$existing_guardian" --delete-keychain "$key_id" || { echo "Retry cleanup could not delete Keychain item; recovery metadata retained" >&2; exit 70; }
      ;;
    *) echo "Unknown fresh-recovery phase" >&2; exit 65 ;;
  esac
  [[ "$recovery_artifact_count" =~ '^[0-9]+$' && "$recovery_artifact_count" -le 16 ]] || { echo "Invalid recovery manifest" >&2; exit 65; }
  for (( recovery_index=0; recovery_index<recovery_artifact_count; recovery_index++ )); do
    recovery_artifact="$(/usr/bin/plutil -extract "artifact_$recovery_index" raw "$fresh_recovery_marker")"
    [[ "$recovery_artifact" == /usr/local/libexec/aware/* || "$recovery_artifact" == '/Library/Application Support/Aware/'* || \
       "$recovery_artifact" == /Library/LaunchDaemons/com.aware.* || "$recovery_artifact" == /private/var/run/aware/* || \
       "$recovery_artifact" == "$console_home/Library/Application Support/Aware/"* || "$recovery_artifact" == "$console_home/Library/LaunchAgents/com.aware."* ]] || {
      echo "Unsafe recovery manifest path" >&2; exit 65
    }
    /bin/rm -f -- "$recovery_artifact"
  done
  /bin/rm -f -- "$fresh_recovery_marker"
  /bin/rmdir /usr/local/libexec/aware '/Library/Application Support/Aware' /private/var/run/aware 2>/dev/null || true
fi
is_upgrade=0
if [[ -e "$existing_helper_config" || -L "$existing_helper_config" || -e "$existing_guardian" || -L "$existing_guardian" ]]; then
  is_upgrade=1
  [[ -f "$existing_helper_config" && ! -L "$existing_helper_config" && -f "$existing_guardian" && ! -L "$existing_guardian" ]] || {
    echo "Incomplete/unsafe existing install; refusing upgrade" >&2; exit 65
  }
  old_key_id="$(/usr/bin/plutil -extract key_id raw "$existing_helper_config")"
  prompt_secret_file "Current host HMAC secret (hidden): " "$root_stage/old-secret"
  # OLD_SECRET_VERIFY_ROUTE: old-secret -> --verify-keychain
  /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
    "$existing_guardian" --verify-keychain "$old_key_id" <"$root_stage/old-secret" || {
      echo "Current secret does not match the existing Guardian Keychain item" >&2; exit 70
    }
fi
# CURRENT_SECRET_VERIFIED_BOUNDARY
prompt_secret_file "Replacement host HMAC secret (hidden): " "$root_stage/new-secret"
# REPLACEMENT_SECRET_VALIDATED_BOUNDARY

# Upgrade boundary: stop the old jobs and use the old installed Guardian identity
# to delete its Keychain item before any installed executable is replaced.
if (( is_upgrade == 1 )); then
  [[ -f "$existing_helper_config" && ! -L "$existing_helper_config" && "$(/usr/bin/stat -f '%u' "$existing_helper_config")" == 0 ]] || {
    echo "Incomplete/unsafe existing install; refusing upgrade" >&2; exit 65
  }
  [[ -f "$existing_guardian" && ! -L "$existing_guardian" && "$(/usr/bin/stat -f '%u' "$existing_guardian")" == 0 ]] || {
    echo "Existing Guardian identity is unavailable; refusing upgrade" >&2; exit 65
  }
  old_uid="$(/usr/bin/plutil -extract allowed_uid raw "$existing_helper_config")"
  old_user="$(/usr/bin/plutil -extract installed_user raw "$existing_helper_config")"
  old_gid="$(/usr/bin/id -g "$old_user")"
  old_home="$(/usr/bin/plutil -extract installed_home raw "$existing_helper_config")"
  old_key_id="$(/usr/bin/plutil -extract key_id raw "$existing_helper_config")"
  [[ "$old_uid" == "$console_uid" && "$old_user" == "$console_user" && "$old_home" == "$console_home" ]] || {
    echo "Existing install belongs to a different GUI identity" >&2; exit 65
  }
  [[ "$old_key_id" =~ '^[A-Za-z0-9._-]{1,64}$' ]] || { echo "Invalid existing key ID" >&2; exit 65; }
  old_helper='/usr/local/libexec/aware/AwarePowerHelper'
  old_daemon='/Library/LaunchDaemons/com.aware.power-helper.plist'
  old_agent="$old_home/Library/LaunchAgents/com.aware.guardian.plist"
  old_guardian_config="$old_home/Library/Application Support/Aware/config.plist"
  for old_file in "$old_helper" "$old_daemon" "$old_agent" "$old_guardian_config"; do
    [[ -f "$old_file" && ! -L "$old_file" ]] || { echo "Incomplete existing install: $old_file" >&2; exit 65; }
  done
  /usr/bin/install -d -o root -g wheel -m 0700 "$root_stage/backup"
  /usr/bin/install -o root -g wheel -m 0755 "$old_helper" "$root_stage/backup/AwarePowerHelper"
  /usr/bin/install -o root -g wheel -m 0755 "$existing_guardian" "$root_stage/backup/AwareGuardian"
  /usr/bin/install -o root -g wheel -m 0600 "$existing_helper_config" "$root_stage/backup/helper.plist"
  /usr/bin/install -o root -g wheel -m 0644 "$old_daemon" "$root_stage/backup/power-helper.plist"
  /usr/bin/install -o root -g wheel -m 0600 "$old_guardian_config" "$root_stage/backup/config.plist"
  /usr/bin/install -o root -g wheel -m 0644 "$old_agent" "$root_stage/backup/guardian.plist"
  /usr/bin/codesign --verify --strict "$root_stage/backup/AwarePowerHelper"
  /usr/bin/codesign --verify --strict "$root_stage/backup/AwareGuardian"
  /usr/bin/plutil -lint "$root_stage/backup/helper.plist" "$root_stage/backup/power-helper.plist" \
    "$root_stage/backup/config.plist" "$root_stage/backup/guardian.plist" >/dev/null
  # UPGRADE_BACKUPS_READY_BOUNDARY
  upgrade_destructive=1
  # UPGRADE_JOBS_STOP_BOUNDARY
  /bin/launchctl bootout "gui/$old_uid/com.aware.guardian" 2>/dev/null || true
  /bin/launchctl bootout system/com.aware.power-helper 2>/dev/null || true
  /usr/bin/pmset -a disablesleep 0
  # UPGRADE_KEYCHAIN_DELETE_BOUNDARY
  /bin/launchctl asuser "$old_uid" /usr/bin/sudo -u "$old_user" \
    "$existing_guardian" --delete-keychain "$old_key_id" || {
      echo "Old Guardian could not delete its Keychain item; installed files were not replaced" >&2
      exit 70
    }
fi

# FRESH_ROLLBACK_ARMED_BOUNDARY
if (( is_upgrade == 0 )); then
  for fresh_target in /usr/local/libexec/aware/AwareGuardian /usr/local/libexec/aware/AwarePowerHelper \
    '/Library/Application Support/Aware/helper.plist' /Library/LaunchDaemons/com.aware.power-helper.plist \
    '/Library/Application Support/Aware/.fresh-recovery.plist.new' \
    "$console_home/Library/Application Support/Aware/config.plist" "$console_home/Library/LaunchAgents/com.aware.guardian.plist"; do
    [[ ! -e "$fresh_target" && ! -L "$fresh_target" ]] || { echo "Existing Aware artifact requires attended recovery: $fresh_target" >&2; exit 65; }
  done
  fresh_attempt_active=1
fi

/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec
require_root_directory /usr/local/libexec
if (( fresh_attempt_active == 1 )) && [[ ! -e /usr/local/libexec/aware ]]; then fresh_binary_directory_created=1; fi
/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec/aware
require_root_directory /usr/local/libexec/aware
if (( fresh_attempt_active == 1 )) && [[ ! -e '/Library/Application Support/Aware' ]]; then fresh_support_directory_created=1; fi
/usr/bin/install -d -o root -g wheel -m 0755 '/Library/Application Support/Aware'
require_root_directory '/Library/Application Support/Aware'
if (( fresh_attempt_active == 1 )); then
  /usr/bin/plutil -create xml1 "$root_stage/fresh-recovery.plist"
  /usr/bin/plutil -insert allowed_uid -integer "$console_uid" "$root_stage/fresh-recovery.plist"
  /usr/bin/plutil -insert installed_user -string "$console_user" "$root_stage/fresh-recovery.plist"
  /usr/bin/plutil -insert installed_home -string "$console_home" "$root_stage/fresh-recovery.plist"
  /usr/bin/plutil -insert key_id -string "$key_id" "$root_stage/fresh-recovery.plist"
  /usr/bin/plutil -insert phase -string pre_guardian "$root_stage/fresh-recovery.plist"
  recovery_artifacts=(
    /usr/local/libexec/aware/AwareGuardian
    /usr/local/libexec/aware/AwarePowerHelper
    "/usr/local/libexec/aware/.AwareGuardian.$$.new"
    "/usr/local/libexec/aware/.AwarePowerHelper.$$.new"
    '/Library/Application Support/Aware/helper.plist'
    "/Library/Application Support/Aware/helper.plist.$$.new"
    /Library/LaunchDaemons/com.aware.power-helper.plist
    "/Library/LaunchDaemons/com.aware.power-helper.plist.$$.new"
    /private/var/run/aware/power-helper.sock
    "$console_home/Library/Application Support/Aware/config.plist"
    "$console_home/Library/Application Support/Aware/guardian-state.plist"
    "$console_home/Library/Application Support/Aware/battery-day.plist"
    "$console_home/Library/LaunchAgents/com.aware.guardian.plist"
    '/Library/Application Support/Aware/fresh-recovery.plist.phase.new'
    '/Library/Application Support/Aware/.fresh-recovery.plist.new'
  )
  /usr/bin/plutil -insert artifact_count -integer "${#recovery_artifacts[@]}" "$root_stage/fresh-recovery.plist"
  for (( recovery_index=0; recovery_index<${#recovery_artifacts[@]}; recovery_index++ )); do
    /usr/bin/plutil -insert "artifact_$recovery_index" -string "${recovery_artifacts[$((recovery_index + 1))]}" "$root_stage/fresh-recovery.plist"
  done
  fresh_recovery_marker_created=1
  fresh_temp_files+=("$initial_recovery_temp")
  /usr/bin/install -o root -g wheel -m 0600 "$root_stage/fresh-recovery.plist" "$initial_recovery_temp"
  /bin/chmod 0600 "$initial_recovery_temp"
  /usr/bin/plutil -lint "$initial_recovery_temp" >/dev/null
  # INITIAL_RECOVERY_ATOMIC_RENAME_BOUNDARY
  /bin/mv -f "$initial_recovery_temp" "$fresh_recovery_marker"
fi
if [[ -e /private/var/run/aware || -L /private/var/run/aware ]]; then
  require_root_directory /private/var/run/aware
fi
if (( fresh_attempt_active == 1 )) && [[ ! -e /private/var/run/aware ]]; then fresh_runtime_directory_created=1; fi
/usr/bin/install -d -o root -g wheel -m 0755 /private/var/run/aware
require_root_directory /private/var/run/aware

# INSTALLED_BINARY_REPLACEMENT_BOUNDARY
for binary in AwarePowerHelper AwareGuardian; do
  destination="/usr/local/libexec/aware/$binary"
  [[ ! -L "$destination" ]] || { echo "Refusing symlink destination: $destination" >&2; exit 65; }
  temporary="/usr/local/libexec/aware/.$binary.$$.new"
  fresh_temp_files+=("$temporary")
  # PREMARK_BINARY_ARTIFACTS
  if (( fresh_attempt_active == 1 )); then
    [[ "$binary" == AwareGuardian ]] && fresh_guardian_binary_created=1 || fresh_helper_binary_created=1
  fi
  /usr/bin/install -o root -g wheel -m 0755 "$root_stage/$binary" "$temporary"
  /bin/mv -f "$temporary" "$destination"
done
# PHASE_GUARDIAN_INSTALLED_BOUNDARY
if (( fresh_attempt_active == 1 )); then atomic_recovery_phase guardian_installed; fi

# The new installed Guardian creates the item it later reads. The secret never
# appears in argv or the environment.
# PREMARK_KEYCHAIN_ATTEMPT
# PHASE_KEYCHAIN_ATTEMPTED_BOUNDARY
if (( fresh_attempt_active == 1 )); then atomic_recovery_phase keychain_attempted; fi
# NEW_KEYCHAIN_SETUP_BOUNDARY
# NEW_SECRET_SETUP_ROUTE: new-secret -> --setup-keychain
if (( fresh_attempt_active == 1 )); then fresh_keychain_created=1; fi
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
  /usr/local/libexec/aware/AwareGuardian --setup-keychain "$key_id" <"$root_stage/new-secret"
# NEW_SECRET_READBACK_ROUTE: new-secret -> --check-keychain
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
  /usr/local/libexec/aware/AwareGuardian --check-keychain "$key_id" <"$root_stage/new-secret"

helper_config='/Library/Application Support/Aware/helper.plist'
[[ ! -L "$helper_config" ]] || { echo "Refusing symlink destination: $helper_config" >&2; exit 65; }
# PREMARK_HELPER_CONFIG
if (( fresh_attempt_active == 1 )); then fresh_helper_config_created=1; fi
fresh_temp_files+=("${helper_config}.$$.new")
/usr/bin/install -o root -g wheel -m 0600 "$root_stage/helper.plist" "${helper_config}.$$.new"
/bin/mv -f "${helper_config}.$$.new" "$helper_config"

daemon_plist='/Library/LaunchDaemons/com.aware.power-helper.plist'
require_root_directory /Library/LaunchDaemons
[[ ! -L "$daemon_plist" ]] || { echo "Refusing symlink destination: $daemon_plist" >&2; exit 65; }
# PREMARK_DAEMON_PLIST
if (( fresh_attempt_active == 1 )); then fresh_daemon_plist_created=1; fi
fresh_temp_files+=("${daemon_plist}.$$.new")
/usr/bin/install -o root -g wheel -m 0644 "$root_stage/power-helper.plist" "${daemon_plist}.$$.new"
/bin/mv -f "${daemon_plist}.$$.new" "$daemon_plist"

user_stage="$(/usr/bin/sudo -u "$console_user" /usr/bin/mktemp -d "/private/var/tmp/aware-user-${console_uid}.XXXXXX")"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -create xml1 "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert cloud_socket_url -string "$worker_url" "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert key_id -string "$key_id" "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert helper_socket_path -string /var/run/aware/power-helper.sock "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert auto_arm -bool true "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert battery_sentinel_hours -integer 24 "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -insert imessage_adapter_enabled -bool false "$user_stage/config.plist"
/usr/bin/sudo -u "$console_user" /bin/chmod 0600 "$user_stage/config.plist"
/usr/bin/sed "s|__USER_HOME__|$console_home|g" "$repo_dir/Resources/launchd/com.aware.guardian.plist" |
  /usr/bin/sudo -u "$console_user" /usr/bin/tee "$user_stage/guardian.plist" >/dev/null
/usr/bin/sudo -u "$console_user" /usr/bin/plutil -lint "$user_stage/guardian.plist" >/dev/null
/usr/bin/sudo -u "$console_user" /bin/chmod 0644 "$user_stage/guardian.plist"

user_support="$console_home/Library/Application Support/Aware"
/usr/bin/sudo -u "$console_user" /usr/bin/install -d -m 0700 "$user_support" "$console_home/Library/LaunchAgents" "$console_home/Library/Logs"
guardian_config="$user_support/config.plist"
agent_plist="$console_home/Library/LaunchAgents/com.aware.guardian.plist"
# PREMARK_USER_CONFIG
if (( fresh_attempt_active == 1 )); then fresh_guardian_config_created=1; fi
/usr/bin/sudo -u "$console_user" /bin/mv -f "$user_stage/config.plist" "$guardian_config"
# PREMARK_AGENT_PLIST
if (( fresh_attempt_active == 1 )); then fresh_agent_plist_created=1; fi
/usr/bin/sudo -u "$console_user" /bin/mv -f "$user_stage/guardian.plist" "$agent_plist"

/bin/launchctl bootstrap system "$daemon_plist"
/bin/launchctl bootstrap "gui/$console_uid" "$agent_plist"
if (( fresh_attempt_active == 1 )); then
  /bin/rm -f -- '/Library/Application Support/Aware/fresh-recovery.plist'
  fresh_recovery_marker_created=0
fi
# UPGRADE_COMMIT_BOUNDARY
upgrade_committed=1
fresh_committed=1
echo "Aware installed and armed. Lock the screen before relying on remote access."
