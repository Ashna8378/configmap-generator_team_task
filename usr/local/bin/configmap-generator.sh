#!/bin/bash

# ===============================
# CONFIGMAP-GENERATOR (v1.0)
# Bash-based YAML generator from XML input
# Logging, systemd compatible, RPM/DEB packaging ready
# ===============================

# Load configuration file
CONFIG_FILE="/usr/local/etc/configmap-generator/config-paths.cfg"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

# Define paths (override if given as arguments)
XML_DIR="${1:-$BLUEPRINT_DIR}"
CONFIG_DIR="${2:-$PROPERTY_DIR}"
OUTPUT_DIR="${3:-$OUTPUT_DIR}"
TEMPLATE_FILE="/usr/local/etc/configmap-generator/configmap.template.yaml"
LOG_FILE="/var/log/configmap-generator/output.log"
PROCESSED_DIR="$XML_DIR/processed-xml"

mkdir -p "$OUTPUT_DIR" "$PROCESSED_DIR"

log_event() {
  local msg="$1"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
}

CFG_FILE=$(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.cfg" | head -n 1)
[[ -z "$CFG_FILE" ]] && { echo "No .cfg file found in '$CONFIG_DIR'."; exit 1; }

# Load raw config
declare -A raw_config
while IFS='=' read -r raw_key raw_val; do
  [[ -z "$raw_key" || "$raw_key" =~ ^[[:space:]]*# ]] && continue
  key=$(echo "$raw_key" | xargs)
  val=$(echo "$raw_val" | xargs)
  raw_config["$key"]="$val"
done < "$CFG_FILE"

# Nested placeholder resolver
resolve() {
  local input="$1"
  local max_depth=10
  local depth=0
  local pattern='\{\{([^{}]+)\}\}'

  while [[ $depth -lt $max_depth && "$input" =~ $pattern ]]; do
    while [[ "$input" =~ $pattern ]]; do
      local placeholder="${BASH_REMATCH[1]}"
      local replacement="${raw_config[$placeholder]}"
      input="${input//\{\{$placeholder\}\}/$replacement}"
    done
    ((depth++))
  done

  echo "$input"
}

# Store resolved config
declare -A resolved_config
CURRENT_SETUP_VALUE="${raw_config[currentSetUp]}"

for k in "${!raw_config[@]}"; do
  resolved_k=$(resolve "$k")
  [[ "$resolved_k" == *_currentSetUp ]] && resolved_k="${resolved_k/_currentSetUp/_$CURRENT_SETUP_VALUE}"
  resolved_v=$(resolve "${raw_config[$k]}")
  resolved_config["$resolved_k"]="$resolved_v"
done

# ================================
# Continuous Watch Loop Starts Here
# ================================
while true; do
  find "$XML_DIR" -maxdepth 1 -type f -name "*.xml" | while read -r XML_FILE; do
    FILENAME=$(basename "$XML_FILE")
    OUT_FILE="$OUTPUT_DIR/configMap-${FILENAME%.xml}.yaml"

    if [[ -f "$OUT_FILE" ]]; then
      continue
    fi

    declare -A used_keys

    uris=$(grep -oP '<(from|to)\s+[^>]*?uri="\K[^"]+' "$XML_FILE")
    for uri in $uris; do
      while [[ "$uri" =~ \{\{([^{}]+)\}\} ]]; do
        raw_key="${BASH_REMATCH[1]}"
        resolved_key=$(resolve "$raw_key")
        used_keys["$raw_key"]=1
        used_keys["$resolved_key"]=1
        uri="${uri//\{\{$raw_key\}\}/${resolved_config[$resolved_key]}}"
      done
    done

    value_keys=$(grep -oP 'value="\$\{[^}]+\}"' "$XML_FILE" | grep -oP '\$\{\K[^}]+' )
    for raw_key in $value_keys; do
      resolved_key=$(resolve "$raw_key")
      used_keys["$raw_key"]=1
      used_keys["$resolved_key"]=1
    done

    double_brace_keys=$(grep -oP '\{\{[^{}]+\}\}' "$XML_FILE" | sed 's/[{}]//g')
    for raw_key in $double_brace_keys; do
      resolved_key=$(resolve "$raw_key")
      used_keys["$raw_key"]=1
      used_keys["$resolved_key"]=1
    done

    address_keys=$(grep -oP 'address="\K\{\{.*?\}\}' "$XML_FILE" | sed 's/["{}]//g')
    for raw_key in $address_keys; do
      nested_keys=$(echo "$raw_key" | grep -oP '\{\{[^{}]+\}\}' | sed 's/[{}]//g')
      resolved_key=$(resolve "$raw_key")
      used_keys["$raw_key"]=1
      used_keys["$resolved_key"]=1
      for nested in $nested_keys; do
        nested_resolved=$(resolve "$nested")
        used_keys["$nested"]=1
        used_keys["$nested_resolved"]=1
      done
    done

    # Build CONFIG_DATA
    CONFIG_DATA=""
    for key in "${!used_keys[@]}"; do
      resolved_key=$(resolve "$key")
      [[ "$resolved_key" == *_currentSetUp ]] && resolved_key="${resolved_key/_currentSetUp/_$CURRENT_SETUP_VALUE}"
      resolved_val="${resolved_config[$resolved_key]}"
      [[ -z "$resolved_val" ]] && resolved_val=""
      [[ "$resolved_val" =~ [:#{}[,[:space:]]|^$ ]] && resolved_val="\"$resolved_val\""
      CONFIG_DATA+="  $resolved_key: $resolved_val\\n"
    done

    # Replace template
    awk -v data="$CONFIG_DATA" '
      {
        if ($0 ~ /{{CONFIG_DATA}}/) {
          sub(/{{CONFIG_DATA}}/, data)
          print
        } else {
          print
        }
      }
    ' "$TEMPLATE_FILE" > "$OUT_FILE"

    mv "$XML_FILE" "$PROCESSED_DIR/"
    log_event "New YAML generated: $OUT_FILE from $FILENAME"
  done

  sleep 5
done


