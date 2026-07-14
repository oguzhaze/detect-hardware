#!/usr/bin/env bash
# =============================================================
#  SERVER INVENTORY  (standalone)
#  Hardware/asset list + RAID level/state + SMART health + PSU + network.
#  Extracted from healthcheck.sh - prints ONLY the inventory block.
#
#  Usage:
#     sudo ./inventory.sh
#
#  Run as root for full detail (dmidecode, SMART, storcli).
#  If a RAID controller is present and no CLI is found, Broadcom StorCLI is
#  auto-installed (.deb/dpkg systems). Override URL with STORCLI_DEB_URL.
# =============================================================
set -uo pipefail 2>/dev/null || true

# Prefer a UTF-8 locale (clean box-drawing / widths); harmless if unavailable.
if [[ -z "${LC_ALL:-}" ]]; then
  if   locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$';     then export LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then export LC_ALL=en_US.UTF-8
  fi
fi

IS_ROOT=0; [[ "$(id -u)" -eq 0 ]] && IS_ROOT=1
WARNINGS=(); add_warn(){ WARNINGS+=("$1"); }

# State populated by the gatherers and consumed by print_inventory
STATUS_SMART="SKIP"; SUM_SMART=""
STATUS_RAID="SKIP";  SUM_RAID=""
RAID_KIND=""; RAID_LEVEL=""; RAID_CTRL=""
# Hardware RAID controller version/firmware (populated by raid_controller_version)
RAID_CTRL_MODEL=""; RAID_CTRL_FW=""; RAID_CTRL_PKG=""; RAID_CTRL_BIOS=""; RAID_CTRL_DRV=""; RAID_CTRL_SN=""
NET_IPV4=""; NET_GW=""; NET_DNS=""
OS_UPDATES=""; Q_OS=""

STORCLI_DEB_URL="${STORCLI_DEB_URL:-https://github.com/oguzhaze/detect-hardware/raw/refs/heads/main/storcli_007.3703.0000.0000_all.deb}"
# SHA-256 checksum for the .deb above. Defaults to "<deb URL>.sha256"; override if hosted elsewhere.
STORCLI_SHA256_URL="${STORCLI_SHA256_URL:-${STORCLI_DEB_URL}.sha256}"

# Lightweight network info (no ping/curl) for the inventory
gather_net_info() {
  local ipv4_cidr gw4 dns_list
  ipv4_cidr="$(ip -4 -br addr show scope global 2>/dev/null | awk 'NR==1{print $3}')"
  [[ -z "$ipv4_cidr" ]] && ipv4_cidr="$(ip -4 addr 2>/dev/null | awk '/inet /&&!/127.0.0.1/{print $2; exit}')"
  gw4="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  dns_list="$( {
      resolvectl status 2>/dev/null | awk -F: '/DNS Servers/{print $2}';
      resolvectl dns 2>/dev/null;
      awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null;
    } | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]*:){2,}[0-9a-fA-F]*' \
      | grep -vE '^127\.0\.0\.(1|53)$' | awk 'NF && !seen[$0]++' | paste -sd', ' )"
  NET_IPV4="${ipv4_cidr:-n/a}"; NET_GW="${gw4:-n/a}"; NET_DNS="${dns_list:-n/a}"
}

os_update_status() {
  local pend="" stamp="" now diff age="" mgr=""
  if command -v apt-get >/dev/null 2>&1; then
    mgr="apt"
    if command -v apt >/dev/null 2>&1; then
      pend="$(apt list --upgradable 2>/dev/null | grep -c '/')"
    fi
    [[ -z "$pend" || "$pend" == "0" ]] && pend="$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst')"
    if [[ -f /var/lib/apt/periodic/update-success-stamp ]]; then
      stamp="$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null)"
    elif [[ -e /var/cache/apt/pkgcache.bin ]]; then
      stamp="$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null)"
    elif [[ -d /var/lib/apt/lists ]]; then
      stamp="$(stat -c %Y /var/lib/apt/lists 2>/dev/null)"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    mgr="dnf"
    pend="$(dnf -q -C check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^(Last|Obsoleting|Security|Loaded)/ {c++} END{print c+0}')"
    [[ -e /var/cache/dnf ]] && stamp="$(stat -c %Y /var/cache/dnf 2>/dev/null)"
  elif command -v yum >/dev/null 2>&1; then
    mgr="yum"
    pend="$(yum -q -C check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^(Last|Obsoleting|Loaded)/ {c++} END{print c+0}')"
  else
    OS_UPDATES="unknown (no apt/dnf/yum)"; return
  fi
  pend="${pend//[^0-9]/}"; [[ -z "$pend" ]] && pend="0"

  if [[ -n "$stamp" && "$stamp" =~ ^[0-9]+$ ]]; then
    now="$(date +%s)"; diff=$(( now - stamp ))
    if   (( diff < 3600 ));  then age="$(( diff/60 ))m ago"
    elif (( diff < 86400 )); then age="$(( diff/3600 ))h ago"
    else                          age="$(( diff/86400 ))d ago"; fi
  fi

  if [[ "$pend" == "0" ]]; then
    OS_UPDATES="up to date (0 pending)"
  else
    OS_UPDATES="${pend} update(s) available"
  fi
  [[ -n "$age" ]] && OS_UPDATES="${OS_UPDATES}; package lists refreshed ${age}"
}

parse_smart_stats() {
  local a="$1" t p w life
  # Temperature: ATA(194) / NVMe / SAS
  t="$(echo "$a" | awk '$2=="Temperature_Celsius"||$2=="Airflow_Temperature_Cel"{print $10; exit}')"
  [[ -z "$t" ]] && t="$(echo "$a" | sed -nE 's/^Temperature:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  [[ -z "$t" ]] && t="$(echo "$a" | sed -nE 's/.*Current Drive Temperature:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  # Power On Hours: ATA / NVMe / SAS
  p="$(echo "$a" | awk '$2=="Power_On_Hours"{print $10; exit}')"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/^Power On Hours:[[:space:]]+([0-9,]+).*/\1/p' | head -1)"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/.*number of hours powered up[^0-9]*([0-9]+).*/\1/p' | head -1)"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/.*Accumulated power on time, hours:minutes[[:space:]]+([0-9]+):.*/\1/p' | head -1)"
  p="${p//,/}"
  # SSD Wear: NVMe / SAS SSD / ATA SSD
  w="$(echo "$a" | sed -nE 's/^Percentage Used:[[:space:]]+([0-9]+)%?.*/\1/p' | head -1)"
  [[ -z "$w" ]] && w="$(echo "$a" | sed -nE 's/.*Percentage used endurance indicator:[[:space:]]+([0-9]+)%.*/\1/p' | head -1)"
  if [[ -z "$w" ]]; then
    w="$(echo "$a" | awk '$2=="Wear_Leveling_Count"{print $10; exit}')"
    if [[ -z "$w" ]]; then
      life="$(echo "$a" | awk '$2=="SSD_Life_Left"||$2=="Media_Wearout_Indicator"{print $4; exit}')"
      [[ "$life" =~ ^[0-9]+$ ]] && w=$((100 - life))
    fi
  fi
  echo "${t}|${p}|${w}"
}

smart_disk_block() {
  local a="$1" label="$2"
  local model health t p w r realloc spare stats info pf
  model="$(echo "$a" | sed -nE 's/^(Device Model|Model Number|Product):[[:space:]]+(.+)/\2/p' | head -1 | sed 's/[[:space:]]*$//')"
  [[ -z "$model" ]] && model="$(echo "$a" | sed -nE 's/^Vendor:[[:space:]]+(.+)/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
  health="$(echo "$a" | grep -iE 'overall-health|SMART Health Status' | grep -oiE 'PASSED|FAILED|OK' | head -1)"
  [[ -z "$health" ]] && health="n/a"
  stats="$(parse_smart_stats "$a")"; t="${stats%%|*}"; r="${stats#*|}"; p="${r%%|*}"; w="${r##*|}"
  realloc="$(echo "$a" | awk '$2=="Reallocated_Sector_Ct"{print $10; exit}')"
  [[ -z "$realloc" ]] && realloc="$(echo "$a" | sed -nE 's/.*Elements in grown defect list:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  spare="$(echo "$a" | sed -nE 's/^Available Spare:[[:space:]]+([0-9]+)%?.*/\1/p' | head -1)"

  # Strip stray CR/LF (and whitespace from numeric fields) so the line never wraps
  model="$(printf '%s' "$model"   | tr -d '\r\n' | sed 's/[[:space:]]*$//')"
  health="$(printf '%s' "$health" | tr -d '\r\n[:space:]')"
  t="$(printf '%s' "$t"           | tr -cd '0-9')"
  p="$(printf '%s' "$p"           | tr -cd '0-9')"
  w="$(printf '%s' "$w"           | tr -cd '0-9')"
  realloc="$(printf '%s' "$realloc" | tr -cd '0-9')"
  spare="$(printf '%s' "$spare"   | tr -cd '0-9')"
  [[ -z "$health" ]] && health="n/a"

  if [[ -n "$model" ]]; then echo "${label}: ${model}"; else echo "${label}"; fi
  echo "  Health: ${health}"
  local metrics=""
  [[ "$t" =~ ^[0-9]+$ ]] && metrics="${metrics}${metrics:+  }Temp: ${t}°C"
  if [[ "$p" =~ ^[0-9]+$ ]]; then
    pf="$(printf '%s' "$p" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
    metrics="${metrics}${metrics:+  }Power-On: ${pf}h"
  fi
  [[ "$w" =~ ^[0-9]+$ ]]      && metrics="${metrics}${metrics:+  }Wear: ${w}%"
  [[ "$spare" =~ ^[0-9]+$ ]]  && metrics="${metrics}${metrics:+  }Spare: ${spare}%"
  [[ "$realloc" =~ ^[0-9]+$ ]] && metrics="${metrics}${metrics:+  }Realloc/Defects: ${realloc}"
  # Collapse any stray newline so the metrics stay on one line
  metrics="${metrics//$'\r'/}"; metrics="${metrics//$'\n'/ }"
  [[ -n "$metrics" ]] && echo "  ${metrics}"
}

check_smart() {
  if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not found (package: smartmontools). SMART skipped."
    STATUS_SMART="SKIP"; SUM_SMART="smartmontools not installed"; return
  fi
  if [[ "$IS_ROOT" -ne 1 ]]; then
    echo "Root required for SMART, skipping."
    STATUS_SMART="SKIP"; SUM_SMART="root required - skipped"; return
  fi

  # Collect targets: "dev|dtype" (dtype may be empty)
  local targets=() bare=() mega=() base="" n out b t
  while read -r d; do bare+=("/dev/$d"); done \
    < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

  # Scan physical disks behind a hardware RAID via megaraid passthrough
  if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'raid'; then
    base="${bare[0]:-}"
    if [[ -n "$base" ]]; then
      echo "Hardware RAID detected; scanning physical disks via megaraid passthrough..."
      for n in $(seq 0 31); do
        out="$(smartctl -i -d "megaraid,$n" "$base" 2>/dev/null)"
        echo "$out" | grep -qiE "Serial Number|Device Model|Product:|Vendor:" && mega+=("${base}|megaraid,$n")
      done
    fi
    # If megaraid disks were found, exclude the virtual disk (base) from the count
    [[ "${#mega[@]}" -gt 0 ]] && bare=("${bare[@]:1}")
  fi

  for b in "${bare[@]}"; do targets+=("${b}|"); done
  [[ "${#mega[@]}" -gt 0 ]] && targets+=("${mega[@]}")

  local total=0 ok=0 fail=0 failed_dev="" idx=0 diskblocks=""
  local dev dtype a health block dlabel
  for t in "${targets[@]}"; do
    dev="${t%%|*}"; dtype="${t##*|}"
    local dopt=(); [[ -n "$dtype" ]] && dopt=(-d "$dtype")
    a="$(smartctl -a "${dopt[@]}" "$dev" 2>/dev/null)"
    [[ -z "$a" ]] && continue
    echo "$a" | grep -qiE "Unable to detect|No such device" && continue
    health="$(echo "$a" | grep -iE 'overall-health|SMART Health Status|test result' | head -1)"
    [[ -z "$health" ]] && continue
    idx=$((idx+1)); total=$((total+1))
    if echo "$health" | grep -qiE "FAILED|FAILING_NOW"; then
      fail=$((fail+1)); failed_dev="$failed_dev ${dev}${dtype:+/$dtype}"; add_warn "SMART failure: $dev ${dtype:+($dtype)}"
    else
      ok=$((ok+1))
    fi
    if [[ -n "$dtype" ]]; then dlabel="Disk ${idx} (${dtype})"; else dlabel="Disk ${idx} (${dev})"; fi
    block="$(smart_disk_block "$a" "$dlabel")"
    echo "--- $dev ${dtype:+($dtype)} ---"
    echo "$block"
    diskblocks="${diskblocks}${diskblocks:+$'\n'}${block}"
  done

  local base_line
  if   [[ "$fail" -gt 0 ]]; then STATUS_SMART="FAIL"; base_line="FAILED disk(s):${failed_dev}"
  elif [[ "$total" -gt 0 ]]; then STATUS_SMART="PASS"; base_line="${ok}/${total} disk(s) PASSED"
  else STATUS_SMART="SKIP"; base_line="No SMART-capable disks (virtual?)"; fi

  if [[ -n "$diskblocks" ]]; then
    SUM_SMART="${base_line}"$'\n'"${diskblocks}"
  else
    SUM_SMART="${base_line}"
  fi
}

find_raid_tool() {
  local t p hit
  for t in storcli2 storcli storcli64 perccli2 perccli perccli64; do
    command -v "$t" >/dev/null 2>&1 && { printf '%s' "$t"; return 0; }
  done
  for p in \
    /opt/MegaRAID/storcli2/storcli2 \
    /opt/MegaRAID/storcli/storcli64 /opt/MegaRAID/storcli/storcli \
    /opt/MegaRAID/perccli2/perccli2 \
    /opt/MegaRAID/perccli/perccli64 /opt/MegaRAID/perccli/perccli \
    /opt/lsi/storcli/storcli64 /opt/lsi/storcli/storcli \
    /usr/local/sbin/storcli2 /usr/local/sbin/storcli64 \
    /usr/local/bin/storcli2  /usr/local/bin/storcli64 \
    /usr/sbin/storcli2 /usr/sbin/storcli64 \
    /usr/bin/storcli2  /usr/bin/storcli64 \
    /opt/storcli/storcli64 /root/storcli2 /root/storcli64; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  # Bounded search of common trees (fast: shallow, limited dirs)
  hit="$(find /opt /usr/local /root /usr/sbin -maxdepth 4 -type f \
            \( -name 'storcli2' -o -name 'storcli64' -o -name 'storcli' \
               -o -name 'perccli2' -o -name 'perccli64' -o -name 'perccli' \) \
            -perm -u+x 2>/dev/null | head -1)"
  [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
  return 1
}

infer_raid_level() {
  command -v smartctl >/dev/null 2>&1 || return 1
  [[ "$IS_ROOT" -eq 1 ]] || return 1
  local base n out cnt=0 per_gb="" usable_b usable_gb b
  base="$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
  [[ -n "$base" ]] || return 1
  for n in $(seq 0 31); do
    out="$(smartctl -i -d "megaraid,$n" "/dev/$base" 2>/dev/null)"
    echo "$out" | grep -qiE "Device Model|Model Number|Product:" || continue
    echo "$out" | grep -qiE 'SES|Enclosure|Expander|Virtual.*SES' && continue
    cnt=$((cnt+1))
    if [[ -z "$per_gb" ]]; then
      b="$(echo "$out" | sed -nE 's/.*User Capacity:[[:space:]]*([0-9,]+) bytes.*/\1/p' | head -1 | tr -d ,)"
      [[ -z "$b" ]] && b="$(echo "$out" | sed -nE 's/.*Total NVM Capacity:[[:space:]]*([0-9,]+) bytes.*/\1/p' | head -1 | tr -d ,)"
      [[ -n "$b" ]] && per_gb=$(( b / 1000000000 ))
    fi
  done
  [[ "$cnt" -ge 1 && -n "$per_gb" && "$per_gb" -gt 0 ]] || return 1
  usable_b="$(lsblk -bdno SIZE "/dev/$base" 2>/dev/null | head -1)"
  [[ "$usable_b" =~ ^[0-9]+$ ]] || return 1
  usable_gb=$(( usable_b / 1000000000 ))
  awk -v n="$cnt" -v per="$per_gb" -v use="$usable_gb" '
    function near(a,b,  t){t=0.15; return (a>=b*(1-t) && a<=b*(1+t))}
    BEGIN{
      if(per<=0) exit 1; r=use/per;
      if(near(r,1)   && n>=2)                {print "RAID 1"; exit}
      if(near(r,n))                          {print "RAID 0"; exit}
      if(n>=3 && near(r,n-1))                {print "RAID 5"; exit}
      if(n>=4 && (n%2)==0 && near(r,n/2))    {print "RAID 10"; exit}
      if(n>=4 && near(r,n-2))                {print "RAID 6"; exit}
      exit 1
    }'
}

# Download <url> to <dest> using curl or wget. Returns 0 only if a non-empty file results.
_dl() {
  local url="$1" dest="$2"
  if   command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 -o "$dest" "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then wget -q --timeout=60 -O "$dest" "$url" 2>/dev/null
  else return 2; fi
  [[ -s "$dest" ]]
}

# Verify <file> against a .sha256 file <src> (accepts "hash  name" or a bare hash).
#   0 = match | 1 = MISMATCH | 2 = missing file | 3 = no hashing tool | 4 = no hash in src
verify_sha256() {
  local file="$1" src="$2" want got tool
  [[ -s "$file" ]] || return 2
  if   command -v sha256sum >/dev/null 2>&1; then tool="sha256sum"
  elif command -v shasum    >/dev/null 2>&1; then tool="shasum"
  elif command -v openssl   >/dev/null 2>&1; then tool="openssl"
  else return 3; fi
  want="$(grep -oiE '[0-9a-f]{64}' "$src" 2>/dev/null | head -1 | tr 'A-F' 'a-f')"
  [[ -n "$want" ]] || return 4
  case "$tool" in
    sha256sum) got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" ;;
    shasum)    got="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')" ;;
    openssl)   got="$(openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}')" ;;
  esac
  got="$(printf '%s' "$got" | tr 'A-F' 'a-f')"
  [[ -n "$got" ]] || return 5
  [[ "$want" == "$got" ]]
}

install_storcli() {
  [[ "${NO_INSTALL:-0}" == "1" ]] && return
  [[ "$IS_ROOT" -eq 1 ]] || return
  find_raid_tool >/dev/null 2>&1 && return        # already have storcli/perccli
  local has_raid=0
  command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'raid' && has_raid=1
  [[ "$has_raid" -eq 1 ]] || return               # only bother on RAID hosts

  if ! command -v dpkg >/dev/null 2>&1; then
    echo "StorCLI auto-install needs a .deb/dpkg system; install storcli manually on this OS."
    return
  fi

  local deb="/tmp/storcli_install.$$.deb"
  local sum="/tmp/storcli_install.$$.deb.sha256"
  local rc

  echo "RAID CLI not found - downloading Broadcom StorCLI..."
  if ! _dl "$STORCLI_DEB_URL" "$deb"; then
    echo "StorCLI download failed (check network/URL)."; rm -f "$deb"; return
  fi

  # --- Integrity gate: verify the .deb against its published SHA-256 BEFORE installing. ---
  # If the checksum can't be fetched or doesn't match, we abort and never touch dpkg.
  echo "Verifying StorCLI package checksum (SHA-256)..."
  if ! _dl "$STORCLI_SHA256_URL" "$sum"; then
    echo "Checksum file could not be downloaded: $STORCLI_SHA256_URL"
    echo "Aborting - StorCLI NOT installed (unverified package removed)."
    add_warn "StorCLI checksum unavailable - install skipped"
    rm -f "$deb" "$sum"; return
  fi

  verify_sha256 "$deb" "$sum"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    case "$rc" in
      1) echo "CHECKSUM MISMATCH - package is corrupt or has been tampered with." ;;
      3) echo "No SHA-256 tool (sha256sum/shasum/openssl) found - cannot verify." ;;
      4) echo "Checksum file has no valid SHA-256 value." ;;
      *) echo "Checksum verification error (code $rc)." ;;
    esac
    echo "Aborting - StorCLI NOT installed (unverified package removed)."
    add_warn "StorCLI checksum verification failed - install skipped"
    rm -f "$deb" "$sum"; return
  fi
  echo "Checksum OK - package verified; proceeding with install."
  rm -f "$sum"

  if dpkg -i "$deb" >/dev/null 2>&1; then
    echo "StorCLI installed: $(find_raid_tool 2>/dev/null || echo /opt/MegaRAID/storcli/storcli64)"
  else
    apt-get -f install -y >/dev/null 2>&1
    if dpkg -i "$deb" >/dev/null 2>&1; then
      echo "StorCLI installed: $(find_raid_tool 2>/dev/null)"
    else
      echo "StorCLI install failed (dpkg)."
    fi
  fi
  rm -f "$deb"
}

# Read the hardware RAID controller's own version info (model / firmware / BIOS /
# driver / serial). Handles storcli, storcli2 and megacli label variants.
raid_controller_version() {
  local tool="$1" out
  [[ -n "$tool" ]] || return 1

  case "$tool" in
    *megacli*|*MegaCli*)
      out="$("$tool" -AdpAllInfo -aAll -NoLog 2>/dev/null)"
      [[ -z "$out" ]] && return 1
      RAID_CTRL_MODEL="$(printf '%s\n' "$out" | sed -nE 's/.*Product Name[[:space:]]*:[[:space:]]*(.+)/\1/Ip'       | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_FW="$(printf '%s\n' "$out"    | sed -nE 's/.*FW Version[[:space:]]*:[[:space:]]*(.+)/\1/Ip'         | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_PKG="$(printf '%s\n' "$out"   | sed -nE 's/.*FW Package Build[[:space:]]*:[[:space:]]*(.+)/\1/Ip'   | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_BIOS="$(printf '%s\n' "$out"  | sed -nE 's/.*BIOS Version[[:space:]]*:[[:space:]]*(.+)/\1/Ip'       | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_SN="$(printf '%s\n' "$out"    | sed -nE 's/.*Serial No[[:space:]]*:[[:space:]]*(.+)/\1/Ip'          | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      ;;
    *)
      # storcli / storcli2 / perccli - try c0 first, then any controller
      out="$("$tool" /c0 show all nolog 2>/dev/null)"
      [[ -z "$out" ]] && out="$("$tool" /c0 show all 2>/dev/null)"
      [[ -z "$out" ]] && out="$("$tool" /call show all nolog 2>/dev/null)"
      [[ -z "$out" ]] && return 1
      # Version section uses "Key = Value"; PD list is tabular, so key=value stays controller-scoped.
      RAID_CTRL_MODEL="$(printf '%s\n' "$out" | sed -nE 's/.*(Product Name|Model)[[:space:]]*=[[:space:]]*(.+)/\2/Ip'                 | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_FW="$(printf '%s\n' "$out"    | sed -nE 's/.*(FW Version|Firmware Version)[[:space:]]*=[[:space:]]*(.+)/\2/Ip'         | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_PKG="$(printf '%s\n' "$out"   | sed -nE 's/.*(FW Package Build|Firmware Package Build)[[:space:]]*=[[:space:]]*(.+)/\2/Ip' | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_BIOS="$(printf '%s\n' "$out"  | sed -nE 's/.*(BIOS Version|Bios Version)[[:space:]]*=[[:space:]]*(.+)/\2/Ip'           | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_DRV="$(printf '%s\n' "$out"   | sed -nE 's/.*Driver Version[[:space:]]*=[[:space:]]*(.+)/\1/Ip'                        | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      RAID_CTRL_SN="$(printf '%s\n' "$out"    | sed -nE 's/.*Serial Number[[:space:]]*=[[:space:]]*(.+)/\1/Ip'                         | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
      ;;
  esac
  return 0
}

check_raid() {
  # 1) Check Software RAID (mdadm) first
  if [[ -e /proc/mdstat ]] && grep -qE '^md[0-9]' /proc/mdstat; then
    cat /proc/mdstat
    local detail degraded=0 md_lvl
    detail="$(awk '
      /^md[0-9]/ { dev=$1; lvl=$4 }
      /\[[U_]+\]/ {
        for (i=1;i<=NF;i++) if ($i ~ /^\[[U_]+\]$/) st=$i
        if (dev!="") { printf "%s: %s %s\n", dev, lvl, st; dev="" }
      }' /proc/mdstat)"
    [[ -z "$detail" ]] && detail="$(grep -E '^md[0-9]' /proc/mdstat | awk '{print $1": "$4}')"
    echo "$detail" | grep -q '_' && degraded=1
    grep -qiE 'recovery|resync|rebuild' /proc/mdstat && degraded=1

    RAID_KIND="Software RAID (mdadm)"; RAID_CTRL="Linux md (kernel)"
    md_lvl="$(printf '%s\n' "$detail" | awk 'NR==1{print $2}')"
    case "$md_lvl" in
      raid0)  RAID_LEVEL="RAID 0";;  raid1)  RAID_LEVEL="RAID 1";;
      raid5)  RAID_LEVEL="RAID 5";;  raid6)  RAID_LEVEL="RAID 6";;
      raid10) RAID_LEVEL="RAID 10";; linear) RAID_LEVEL="Linear / JBOD";;
      "")     RAID_LEVEL="unknown";; *)      RAID_LEVEL="${md_lvl}";;
    esac

    if (( degraded )); then
      STATUS_RAID="WARN"; add_warn "Software RAID degraded / rebuilding"
      printf -v SUM_RAID 'Type: Software RAID (mdadm)\nLevel: %s\nStatus: DEGRADED / rebuilding\n%s' "$RAID_LEVEL" "$detail"
    else
      STATUS_RAID="PASS"
      printf -v SUM_RAID 'Type: Software RAID (mdadm)\nLevel: %s\nStatus: healthy\n%s' "$RAID_LEVEL" "$detail"
    fi
    return
  fi

  # 2) If no software RAID, check the hardware RAID controller
  local ctrl=""
  if command -v lspci >/dev/null 2>&1; then
    ctrl="$(lspci 2>/dev/null | grep -i 'raid' | sed -E 's/^[0-9a-fA-F:.]+ //; s/.*RAID bus controller: //I' | head -1)"
  fi
  if [[ -n "$ctrl" ]]; then
    echo "Hardware RAID controller detected: $ctrl"
    RAID_KIND="Hardware RAID"; RAID_CTRL="$ctrl"
    local raidtool="" vdout="" deg=0 lvl="" spec inferred
    local -a try
    raidtool="$(find_raid_tool)"
    if [[ -n "$raidtool" ]]; then
      echo "Using RAID CLI: $raidtool"
      raid_controller_version "$raidtool"    # model / FW / BIOS / driver version
      # storcli vs storcli2 accept slightly different scopes - try a few
      for spec in "/call/vall show nolog" "/c0/vall show nolog" "/call/vall show" "/c0/vall show"; do
        read -r -a try <<< "$spec"
        vdout="$("$raidtool" "${try[@]}" 2>/dev/null)"
        printf '%s\n' "$vdout" | grep -qiE '^[0-9]+/[0-9]+|RAID[0-9]' && break
        vdout=""
      done
    elif command -v megacli >/dev/null 2>&1 || command -v MegaCli64 >/dev/null 2>&1; then
      raidtool="$(command -v megacli || command -v MegaCli64)"
      raid_controller_version "$raidtool"    # model / FW / BIOS version
      vdout="$("$raidtool" -LDInfo -Lall -aAll -NoLog 2>/dev/null)"
    fi

    # RAID level from the VD table (storcli: "0/0 RAID0 Optl ..."; megacli: "Primary-1, Secondary-0")
    if [[ -n "$vdout" ]]; then
      lvl="$(printf '%s\n' "$vdout" | awk '$1 ~ /^[0-9]+\/[0-9]+$/ {print $2; exit}')"
      [[ -z "$lvl" ]] && lvl="$(printf '%s\n' "$vdout" | sed -nE 's/.*Primary-([0-9]+), Secondary-([0-9]+).*/RAID\1\2/p' | head -1)"
    fi
    # No VD? Check for JBOD / pass-through drives
    if [[ -z "$lvl" && "$raidtool" =~ storcli|perccli ]]; then
      for spec in "/call/eall/sall show nolog" "/c0/eall/sall show nolog"; do
        read -r -a try <<< "$spec"
        printf '%s\n' "$("$raidtool" "${try[@]}" 2>/dev/null)" | grep -qiE '\bJBOD\b' && { lvl="JBOD"; break; }
      done
    fi
    case "$lvl" in
      RAID0)  RAID_LEVEL="RAID 0";;  RAID1)  RAID_LEVEL="RAID 1";;
      RAID5)  RAID_LEVEL="RAID 5";;  RAID6)  RAID_LEVEL="RAID 6";;
      RAID10) RAID_LEVEL="RAID 10";; RAID00) RAID_LEVEL="RAID 00";;
      RAID50) RAID_LEVEL="RAID 50";; RAID60) RAID_LEVEL="RAID 60";;
      JBOD)   RAID_LEVEL="JBOD";;
      "")     RAID_LEVEL="";;
      *)      RAID_LEVEL="$lvl";;
    esac
    # Fallback: no vendor tool / no level -> infer from disk count vs usable capacity
    if [[ -z "$RAID_LEVEL" ]]; then
      inferred="$(infer_raid_level)"
      if [[ -n "$inferred" ]]; then
        RAID_LEVEL="${inferred} (inferred from capacity)"
      elif [[ -z "$raidtool" ]]; then
        RAID_LEVEL="unknown (storcli not found; install storcli2 for SAS38xx cards)"
      else
        RAID_LEVEL="unknown (vendor tool returned no virtual drive)"
      fi
    fi

    if [[ -n "$vdout" ]]; then
      echo "$vdout"
      # Read the VD's State column ONLY (storcli prints a legend that contains the words
      # "Degraded/OffLine/..." which must NOT be mistaken for the actual state).
      local vstate
      vstate="$(printf '%s\n' "$vdout" | awk '$1 ~ /^[0-9]+\/[0-9]+$/ {print $3; exit}')"
      [[ -z "$vstate" ]] && vstate="$(printf '%s\n' "$vdout" | sed -nE 's/.*State[[:space:]]*:[[:space:]]*([A-Za-z]+).*/\1/p' | head -1)"
      case "$vstate" in
        Optl|Optimal|"")                                     deg=0;;
        Dgrd|Pdgd|OfLn|Offln|Rec|Degraded|Offline|Partially*|Failed|Fld) deg=1;;
        *)                                                   deg=0;;
      esac
      if (( deg )); then
        STATUS_RAID="WARN"; add_warn "Hardware RAID: virtual drive degraded/offline"
        printf -v SUM_RAID 'Type: Hardware RAID\nController: %s\nLevel: %s\nVirtual drive(s): DEGRADED / OFFLINE' "$ctrl" "$RAID_LEVEL"
      else
        STATUS_RAID="PASS"
        printf -v SUM_RAID 'Type: Hardware RAID\nController: %s\nLevel: %s\nVirtual drive(s): Optimal' "$ctrl" "$RAID_LEVEL"
      fi
    else
      echo "(Vendor tool not found: storcli / megacli / perccli - detailed status unavailable)"
      STATUS_RAID="PASS"
      printf -v SUM_RAID 'Type: Hardware RAID\nController: %s\nLevel: %s' "$ctrl" "$RAID_LEVEL"
    fi
    return
  fi

  # 3) None present
  echo "No RAID detected (software or hardware)."
  STATUS_RAID="SKIP"; RAID_KIND="None"; RAID_LEVEL="n/a"
  SUM_RAID="No RAID detected (software or hardware)"
}

dmi_field() {
  local type="$1" key="$2"
  dmidecode -t "$type" 2>/dev/null | awk -v k="$key" '
    { s=$0; sub(/^[ \t]+/,"",s) }
    index(s, k ": ")==1 { v=substr(s, length(k)+3); sub(/[ \t]+$/,"",v); print v; exit }'
}

inventory_disks() {
  local raid=0 base="" n out model sn size tran name serial phys=0 rev fw

  command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'raid' && raid=1

  # Disks visible to the OS (bare disks or the RAID virtual disk)
  if command -v lsblk >/dev/null 2>&1; then
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="$(sed -nE 's/.*(^| )NAME="([^"]*)".*/\2/p'     <<<"$line")"
      model="$(sed -nE 's/.*(^| )MODEL="([^"]*)".*/\2/p'   <<<"$line")"
      size="$(sed -nE 's/.*(^| )SIZE="([^"]*)".*/\2/p'     <<<"$line")"
      serial="$(sed -nE 's/.*(^| )SERIAL="([^"]*)".*/\2/p' <<<"$line")"
      tran="$(sed -nE 's/.*(^| )TRAN="([^"]*)".*/\2/p'     <<<"$line")"
      rev="$(sed -nE 's/.*(^| )REV="([^"]*)".*/\2/p'       <<<"$line")"
      [[ -z "$name" ]] && continue
      printf '    %-10s %-26s %-9s %-6s FW: %-10s SN: %s\n' \
        "/dev/$name" "${model:-n/a}" "${size:-n/a}" "${tran:-?}" "${rev:-n/a}" "${serial:-n/a}"
    done < <(lsblk -dno NAME,MODEL,SIZE,SERIAL,TRAN,REV -P 2>/dev/null)
  fi

  # Physical member disks behind a hardware RAID controller (needs smartctl + root)
  if (( raid )) && command -v smartctl >/dev/null 2>&1 && [[ "$IS_ROOT" -eq 1 ]]; then
    base="$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
    if [[ -n "$base" ]]; then
      echo "    -- physical disks behind RAID controller --"
      for n in $(seq 0 31); do
        out="$(smartctl -i -d "megaraid,$n" "/dev/$base" 2>/dev/null)"
        echo "$out" | grep -qiE "Serial Number|Device Model|Model Number|Product:" || continue
        model="$(echo "$out" | sed -nE 's/^(Device Model|Model Number|Product):[[:space:]]+(.+)/\2/p' | head -1 | sed 's/[[:space:]]*$//')"
        [[ -z "$model" ]] && model="$(echo "$out" | sed -nE 's/^Vendor:[[:space:]]+(.+)/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
        # Skip SAS expanders / SES enclosures - they answer to passthrough but are not disks
        echo "$model" | grep -qiE 'SES|Enclosure|Expander|Virtual.*SES' && continue
        echo "$out"   | grep -qiE 'Enclosure (Services|Device)|SCSI Enclosure' && continue
        sn="$(echo "$out" | sed -nE 's/^Serial [Nn]umber:[[:space:]]+(.+)/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
        size="$(echo "$out" | sed -nE 's/.*\[([0-9.]+ [KMGT]B)\].*/\1/p' | head -1)"
        # Firmware: ATA/NVMe report "Firmware Version:", SAS/SCSI report "Revision:"
        fw="$(echo "$out" | sed -nE 's/^Firmware Version:[[:space:]]+(.+)/\1/p' | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
        [[ -z "$fw" ]] && fw="$(echo "$out" | sed -nE 's/^Revision:[[:space:]]+(.+)/\1/p' | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
        phys=$((phys+1))
        printf '    %-10s %-26s %-9s %-6s FW: %-10s SN: %s\n' \
          "slot $n" "${model:-n/a}" "${size:-n/a}" "raid" "${fw:-n/a}" "${sn:-n/a}"
      done
      echo "    Physical disks detected: ${phys}"
    fi
  fi
}

inventory_power() {
  local printed=0 psu pssdr watts

  # 1) SMBIOS "System Power Supply" (type 39) - model / capacity / status per PSU
  if command -v dmidecode >/dev/null 2>&1 && [[ "$IS_ROOT" -eq 1 ]]; then
    psu="$(dmidecode -t 39 2>/dev/null)"
    if [[ -n "$psu" ]] && echo "$psu" | grep -q 'System Power Supply'; then
      echo "$psu" | awk '
        function out() {
          if (have) printf "  %-8s %-20s %-8s %s\n",
            (loc!=""?loc:"PSU"),
            (model!=""?model:(name!=""?name:"n/a")),
            (cap!=""?cap:"-"),
            (st!=""?st:"-")
          have=0; loc=""; name=""; model=""; cap=""; st=""
        }
        /System Power Supply/ { out(); have=1; next }
        { s=$0; sub(/^[ \t]+/,"",s)
          if      (s ~ /^Location:/)           { loc=s;   sub(/^Location:[ \t]*/,"",loc) }
          else if (s ~ /^Name:/)               { name=s;  sub(/^Name:[ \t]*/,"",name) }
          else if (s ~ /^Model Part Number:/)  { model=s; sub(/^Model Part Number:[ \t]*/,"",model) }
          else if (s ~ /^Max Power Capacity:/) { cap=s;   sub(/^Max Power Capacity:[ \t]*/,"",cap) }
          else if (s ~ /^Status:/)             { st=s;    sub(/^Status:[ \t]*/,"",st) }
        }
        END { out() }'
      printed=1
    fi
  fi

  # 2) Live PSU status + power draw via IPMI (BMC), if ipmitool is available
  if command -v ipmitool >/dev/null 2>&1; then
    pssdr="$(ipmitool sdr type 'Power Supply' 2>/dev/null)"
    if [[ -n "$pssdr" ]]; then
      echo "  Live status (IPMI):"
      printf '%s\n' "$pssdr" | sed 's/^/    /'
      printed=1
    fi
    watts="$(ipmitool dcmi power reading 2>/dev/null | sed -nE 's/.*Instantaneous power reading:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
    [[ -n "$watts" ]] && { printf '  %-8s %s\n' 'Draw:' "${watts} W"; printed=1; }
  fi

  if (( ! printed )); then
    if [[ "$IS_ROOT" -ne 1 ]]; then
      echo "  (PSU info needs root + IPMI 'ipmitool' or SMBIOS type 39)"
    elif ! command -v ipmitool >/dev/null 2>&1; then
      echo "  (no PSU data - install 'ipmitool' for BMC power-supply health, or board exposes none)"
    else
      echo "  (no power-supply sensors reported - common on single-PSU / desktop boards)"
    fi
  fi
}

print_inventory() {
  echo
  echo "============================================================"
  echo "                  SERVER INVENTORY (hardware)"
  echo "============================================================"

  local have_dmi=1 dmi=0
  command -v dmidecode >/dev/null 2>&1 || have_dmi=0
  (( have_dmi )) && [[ "$IS_ROOT" -eq 1 ]] && dmi=1
  if (( ! have_dmi )); then
    echo "(dmidecode not installed - install 'dmidecode' for full asset details)"
  elif [[ "$IS_ROOT" -ne 1 ]]; then
    echo "(run as root for full asset details - dmidecode requires root)"
  fi

  # ---- System ----
  echo
  echo "--- System ---"
  if (( dmi )); then
    printf '  %-16s %s\n' 'Manufacturer:'  "$(dmi_field system 'Manufacturer')"
    printf '  %-16s %s\n' 'Product/Model:' "$(dmi_field system 'Product Name')"
    printf '  %-16s %s\n' 'Serial Number:' "$(dmi_field system 'Serial Number')"
    printf '  %-16s %s\n' 'UUID:'          "$(dmi_field system 'UUID')"
  else
    printf '  %-16s %s\n' 'Hostname:' "$(hostname -f 2>/dev/null || hostname)"
  fi

  # ---- Operating System ----
  echo
  echo "--- Operating System ---"
  printf '  %-16s %s\n' 'OS:'      "${Q_OS:-unknown}"
  printf '  %-16s %s\n' 'Kernel:'  "$(uname -r)"
  printf '  %-16s %s\n' 'Updates:' "${OS_UPDATES:-unknown}"

  # ---- Motherboard ----
  echo
  echo "--- Motherboard (baseboard) ---"
  if (( dmi )); then
    printf '  %-16s %s\n' 'Manufacturer:'  "$(dmi_field baseboard 'Manufacturer')"
    printf '  %-16s %s\n' 'Model:'         "$(dmi_field baseboard 'Product Name')"
    printf '  %-16s %s\n' 'Serial Number:' "$(dmi_field baseboard 'Serial Number')"
  else
    echo "  (needs root + dmidecode)"
  fi

  # ---- BIOS / Firmware ----
  echo
  echo "--- BIOS / Firmware ---"
  local fw_mode brev
  [[ -d /sys/firmware/efi ]] && fw_mode="UEFI" || fw_mode="Legacy BIOS"
  if (( dmi )); then
    printf '  %-16s %s\n' 'Vendor:'       "$(dmi_field bios 'Vendor')"
    printf '  %-16s %s\n' 'BIOS Version:' "$(dmi_field bios 'Version')"
    printf '  %-16s %s\n' 'Release Date:' "$(dmi_field bios 'Release Date')"
    brev="$(dmi_field bios 'BIOS Revision')"
    [[ -n "$brev" ]] && printf '  %-16s %s\n' 'BIOS Revision:' "$brev"
  fi
  printf '  %-16s %s\n' 'Firmware Mode:' "$fw_mode"

  # ---- Chassis ----
  if (( dmi )); then
    echo
    echo "--- Chassis ---"
    printf '  %-16s %s\n' 'Type:'         "$(dmi_field chassis 'Type')"
    printf '  %-16s %s\n' 'Serial Number:' "$(dmi_field chassis 'Serial Number')"
    printf '  %-16s %s\n' 'Asset Tag:'    "$(dmi_field chassis 'Asset Tag')"
  fi

  # ---- CPU ----
  echo
  echo "--- CPU ---"
  local cpu_model sockets cps cpus cores threads microcode maxspeed
  cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
  [[ -z "$cpu_model" ]] && cpu_model="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null)"
  sockets="$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')"
  cps="$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')"
  cpus="$(nproc 2>/dev/null)"
  cores=$(( ${sockets:-1} * ${cps:-1} ))
  threads="${cpus:-0}"
  microcode="$(awk '/microcode/{print $3; exit}' /proc/cpuinfo 2>/dev/null)"
  printf '  %-16s %s\n' 'Model:'         "${cpu_model:-n/a}"
  printf '  %-16s %s\n' 'Sockets:'       "${sockets:-1}"
  printf '  %-16s %s\n' 'Cores/Threads:' "${cores} / ${threads}"
  [[ -n "$microcode" ]] && printf '  %-16s %s\n' 'Microcode:' "$microcode"
  if (( dmi )); then
    maxspeed="$(dmidecode -t processor 2>/dev/null | awk -F: '/Max Speed/{gsub(/^[ \t]+/,"",$2);print $2; exit}')"
    [[ -n "$maxspeed" ]] && printf '  %-16s %s\n' 'Max Speed:' "$maxspeed"
  fi

  # ---- Memory ----
  echo
  echo "--- Memory (RAM) ---"
  local mem_kb mem_gb slots populated
  mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  mem_gb=$(( ( ${mem_kb:-0} + 524288 ) / 1048576 ))
  printf '  %-16s %s\n' 'Total (OS):' "${mem_gb} GB"
  if (( dmi )); then
    slots="$(dmidecode -t memory 2>/dev/null | grep -c '^Memory Device')"
    populated="$(dmidecode -t memory 2>/dev/null | awk '
      /^Memory Device/{d=1; next}
      d && /^[ \t]*Size:/{ s=$0; sub(/^[ \t]+/,"",s); sub(/^Size:[ \t]*/,"",s);
                           if (s !~ /No Module Installed/ && s !~ /Unknown/ && s+0>0) c++; d=0 }
      END{print c+0}')"
    printf '  %-16s %s\n' 'DIMM slots:' "${populated} populated / ${slots} total"
    echo "  Installed modules:"
    dmidecode -t memory 2>/dev/null | awk '
      function out() {
        if (have && size!="" && size !~ /No Module Installed/ && size !~ /Unknown/)
          printf "    %-9s %-8s %-7s %-11s PN: %-20s SN: %s\n",
                 loc, size, type, speed, (pn==""?"n/a":pn), (sn==""?"n/a":sn)
        have=0; loc=""; size=""; type=""; speed=""; pn=""; sn=""
      }
      /^Memory Device/ { out(); have=1; next }
      {
        s=$0; sub(/^[ \t]+/,"",s)
        if      (s ~ /^Size:/)               { size=s; sub(/^Size:[ \t]*/,"",size) }
        else if (s ~ /^Locator:/)            { loc=s;  sub(/^Locator:[ \t]*/,"",loc) }
        else if (s ~ /^Type:/ && type=="")   { type=s; sub(/^Type:[ \t]*/,"",type) }
        else if (s ~ /^Speed:/ && speed=="") { speed=s; sub(/^Speed:[ \t]*/,"",speed) }
        else if (s ~ /^Part Number:/)        { pn=s;  sub(/^Part Number:[ \t]*/,"",pn); sub(/[ \t]+$/,"",pn) }
        else if (s ~ /^Serial Number:/)      { sn=s;  sub(/^Serial Number:[ \t]*/,"",sn) }
      }
      END { out() }'
  else
    echo "  (per-DIMM serials / part numbers need root + dmidecode)"
  fi

  # ---- Storage / RAID ----
  echo
  echo "--- Storage / RAID ---"
  printf '  %-16s %s\n' 'RAID type:'  "${RAID_KIND:-None}"
  if [[ -n "$RAID_CTRL" && "$RAID_KIND" == "Hardware RAID" ]]; then
    printf '  %-16s %s\n' 'Controller:' "$RAID_CTRL"
    [[ -n "$RAID_CTRL_MODEL" ]] && printf '  %-16s %s\n' 'Ctrl model:'    "$RAID_CTRL_MODEL"
    [[ -n "$RAID_CTRL_FW"    ]] && printf '  %-16s %s\n' 'Ctrl FW:'       "$RAID_CTRL_FW"
    [[ -n "$RAID_CTRL_PKG"   ]] && printf '  %-16s %s\n' 'Ctrl FW pkg:'   "$RAID_CTRL_PKG"
    [[ -n "$RAID_CTRL_BIOS"  ]] && printf '  %-16s %s\n' 'Ctrl BIOS:'     "$RAID_CTRL_BIOS"
    [[ -n "$RAID_CTRL_DRV"   ]] && printf '  %-16s %s\n' 'Ctrl driver:'   "$RAID_CTRL_DRV"
    [[ -n "$RAID_CTRL_SN"    ]] && printf '  %-16s %s\n' 'Ctrl serial:'   "$RAID_CTRL_SN"
  fi
  printf '  %-16s %s\n' 'RAID level:' "${RAID_LEVEL:-n/a}"
  printf '  %-16s %s\n' 'RAID state:' "$(
    case "$STATUS_RAID" in
      PASS) echo "Optimal / healthy";;
      WARN) echo "Degraded / rebuilding";;
      SKIP) echo "n/a";;
      *)    echo "$STATUS_RAID";;
    esac)"

  # ---- Disks ----
  echo
  echo "--- Disks ---"
  inventory_disks

  # ---- Disk health (SMART) ----
  echo
  echo "--- Disk health (SMART) ---"
  if [[ -n "$SUM_SMART" ]]; then
    printf '%s\n' "$SUM_SMART" | sed 's/^/  /'
  else
    echo "  (no SMART data)"
  fi

  # ---- Network ----
  echo
  echo "--- Network ---"
  printf '  %-16s %s\n' 'IPv4:'    "${NET_IPV4:-n/a}"
  printf '  %-16s %s\n' 'Gateway:' "${NET_GW:-n/a}"
  printf '  %-16s %s\n' 'DNS:'     "${NET_DNS:-n/a}"

  # ---- Power supplies ----
  echo
  echo "--- Power supply ---"
  inventory_power

  echo
  echo "============================================================"
}

# ---- gather data quietly, then print the inventory ----
if [[ -r /etc/os-release ]]; then . /etc/os-release; Q_OS="${PRETTY_NAME:-${NAME:-} ${VERSION:-}}"; fi
[[ -z "${Q_OS// }" ]] && Q_OS="unknown"

os_update_status
install_storcli                 # visible on first run (downloads/install line), silent after
check_smart   >/dev/null 2>&1   # sets SUM_SMART
check_raid    >/dev/null 2>&1   # sets RAID_KIND / RAID_LEVEL / STATUS_RAID
gather_net_info

print_inventory
