JSON_URL="https://ip-ranges.amazonaws.com/ip-ranges.json"

if [[ -z $DEBUG ]]; then
    DEBUG=0
fi


function log() {
    if [[ $DEBUG == 1 ]]; then
        echo $* >&2
    fi
}


##
# Retrieves AWS JSON data
#
function get_aws_json() {
    # Retrieve IP ranges definition
    # Either from an URL or file input (e.g. "< ranges.json")
    if [[ -f $1 ]]; then
        log "Loading IP ranges from file"
        local json=$(<$1)
    else
        log "Downloading IP ranges via curl"
        local json=$(curl -s -L $JSON_URL)
    fi

    if [[ -z $json ]]; then
        echo "JSON definition empty" >&2
        exit 1
    fi

    echo "$json"
}


##
# Builds region filters based on CLI arguments
#
# Arguments: CLI arguments as passed by $*
#
function build_filters() {
    for arg in ${@:1}; do
        if [[ -n $filters ]]; then
            filters=$filters", "
        fi

        filters=$filters"select(.region | contains(\"$arg\"))"
    done

    if [[ -n $filters ]]; then
        filters=" | "$filters
    fi

    log "Built filters ('$filters')"
    echo "$filters"
}


##
# Extracts IP ranges from an Amazon JSON file
#
# Arguments:
#     $1 AWS JSON content
#     $2 Prepared filter string
#     $3 Group to extract IP ranges from (e.g. prefixes)
#     $4 Object key for IP ranges (e.g ip_prefix)
#
function extract_ip_ranges() {
    local json=$1
    local filters=$2
    local array=$3
    local prefix=$4

    log "Extracting IP ranges ($4)"

    local group='group_by(.'$prefix')'
    local map='map({ "ip": .[0].'$prefix', "regions": map(.region) | unique, "services": map(.service) | unique })'

    local to_string='.ip + " \"" + (.regions | sort | join (", ")) + "\" \"" + (.services | sort | join (", ")) + "\""'
    local process='[ .'$array"[]$filters ] | $group | $map | .[] | $to_string"

    local ranges=$(echo "$json" | jq -r "$process" | sort -Vu)
    echo "$ranges"
}


##
# Creates the AWS iptables chain if it doesn't exist, then flushes it
#
# Arguments:
#     $1 Version to use. Omit for v4
#     $2 Position to insert chain statement at
#
function create_and_flush_chain() {
    local version=$1
    local position=$2
    local cmd=ip${version}tables

    log "Creating and flushing chain $version"

    $cmd -n --list AWS >/dev/null 2>&1 \
        || ($cmd -N AWS && $cmd -I INPUT $position -j AWS)

    $cmd -F AWS
}


##
# Adds an iptables rule for each line in ranges
#
# Arguments:
#     $1 Version to use. Omit for v4
#     $2 Prepared lines
#
function add_iptables_rules() {
    local version=$1
    local cmd=ip${version}tables
    local lines
    local data

    log "Adding iptables rules $version"

    IFS=$'\n' lines=($2)
    unset IFS

    for line in "${lines[@]}"; do
        eval local data=($line)
        local ip=${data[0]}
        local regions=$(echo ${data[1]} | tr '[:upper:]' '[:lower:]')
        local services=$(echo ${data[2]} | tr '[:upper:]' '[:lower:]')

        $cmd -A AWS -s "$ip" -j REJECT -m comment --comment "$regions = $services"
    done
}


##
# Creates a ferm IP definition ruleset.
#
# Arguments:
#     $1 Version to use
#     $2 Prepared lines
#
function create_ferm_array() {
    local version=$1
    shift

    echo '@def $AWS_IPS_V'$version' = ('

    IFS=$'\n' lines=($1)
    unset IFS

    for line in "${lines[@]}"; do
        eval local data=($line)
        local ip=${data[0]}
        local regions=$(echo ${data[1]} | tr '[:upper:]' '[:lower:]')
        local services=$(echo ${data[2]} | tr '[:upper:]' '[:lower:]')

        echo -e "    $ip\t\t\t# $regions = $services"
    done

    echo ');'
}
