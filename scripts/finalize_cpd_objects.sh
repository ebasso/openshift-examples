#!/usr/bin/env bash
#
# finalize_cpd_objects.sh
#
# Script to remove finalizers from stuck / pending objects and namespaces
# in IBM Cloud Pak for Data (ibm-cpd, ibm-cpd-operators).
#
# Usage:
#   ./finalize_cpd_objects.sh [OPTIONS] [NAMESPACE_1 NAMESPACE_2 ...]
#
# Options:
#   -d, --dry-run       Show resources that would be patched without modifying them
#   -a, --all-objects   Remove finalizers from ALL resources, not just those with deletionTimestamp
#   -f, --force-ns      Also finalize and clear stuck namespace-level finalizers
#   -h, --help          Show this help message

set -euo pipefail

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
DEFAULT_NAMESPACES=("ibm-cpd" "ibm-cpd-operators")
NAMESPACES=()
DRY_RUN=false
ALL_OBJECTS=false
FORCE_NS=true
OC_BIN="oc"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [NAMESPACE ...]

Remove finalizers from pending / terminating objects in OpenShift namespaces using 'oc'.

Target namespaces by default:
  - ibm-cpd
  - ibm-cpd-operators

Options:
  -d, --dry-run       Inspect resources without removing finalizers
  -a, --all-objects   Target all objects with finalizers (not just deletionTimestamp != null)
  -n, --no-force-ns   Do not finalize the namespace resource itself
  -h, --help          Show this help message

Examples:
  # Finalize pending objects in default namespaces (ibm-cpd, ibm-cpd-operators)
  ./finalize_cpd_objects.sh

  # Dry-run mode
  ./finalize_cpd_objects.sh --dry-run

  # Specify custom namespaces
  ./finalize_cpd_objects.sh ibm-cpd ibm-cpd-operators ibm-cpd-opertaros
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -a|--all-objects)
            ALL_OBJECTS=true
            shift
            ;;
        -n|--no-force-ns)
            FORCE_NS=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            NAMESPACES+=("$1")
            shift
            ;;
    esac
done

# If no namespaces were provided, use default namespaces
if [ ${#NAMESPACES[@]} -eq 0 ]; then
    NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
fi

# Pre-flight checks
check_prerequisites() {
    log_info "Verifying tools and OpenShift cluster connectivity..."

    if ! command -v "$OC_BIN" &>/dev/null; then
        log_error "'oc' command not found. Please install the OpenShift CLI and ensure it is in your PATH."
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "'jq' command not found. Please install jq (e.g. yum/dnf/apt install jq)."
        exit 1
    fi

    local oc_user
    if ! oc_user=$("$OC_BIN" whoami 2>/dev/null); then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi

    log_success "Connected to OpenShift cluster as: ${CYAN}${oc_user}${NC}"
    if [ "$DRY_RUN" = true ]; then
        log_warn "Running in DRY-RUN mode. No changes will be applied."
    fi
}

# Process resources in a namespace
finalize_namespace_resources() {
    local ns="$1"
    local total_patched=0

    echo ""
    echo "======================================================================"
    log_info "Processing namespace: ${CYAN}${ns}${NC}"
    echo "======================================================================"

    # Check if namespace exists
    if ! "$OC_BIN" get namespace "$ns" &>/dev/null; then
        log_warn "Namespace '${ns}' does not exist on the cluster. Skipping."
        return 0
    fi

    # Retrieve all namespaced resource types that support get/delete
    log_info "Discovering namespaced API resource types..."
    local api_resources
    api_resources=$("$OC_BIN" api-resources --namespaced=true --verbs=get,delete -o name 2>/dev/null || true)

    if [ -z "$api_resources" ]; then
        log_warn "Could not list API resources for namespace ${ns}."
        return 0
    fi

    for resource_type in $api_resources; do
        # Retrieve all objects of this type in the namespace
        local objects_json
        objects_json=$("$OC_BIN" get "$resource_type" -n "$ns" -o json 2>/dev/null || true)

        if [ -z "$objects_json" ]; then
            continue
        fi

        # Filter objects with finalizers
        local jq_filter
        if [ "$ALL_OBJECTS" = true ]; then
            jq_filter='.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length) > 0) | {name: .metadata.name, finalizers: .metadata.finalizers, deleting: (.metadata.deletionTimestamp != null)}'
        else
            # Only objects stuck with deletionTimestamp
            jq_filter='.items[] | select(.metadata.deletionTimestamp != null and .metadata.finalizers != null and (.metadata.finalizers | length) > 0) | {name: .metadata.name, finalizers: .metadata.finalizers, deleting: true}'
        fi

        local pending_items
        pending_items=$(echo "$objects_json" | jq -c "$jq_filter" 2>/dev/null || true)

        if [ -n "$pending_items" ]; then
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                local item_name finalizers is_deleting
                item_name=$(echo "$item" | jq -r '.name')
                finalizers=$(echo "$item" | jq -r '.finalizers | join(", ")')
                is_deleting=$(echo "$item" | jq -r '.deleting')

                if [ "$is_deleting" = "true" ]; then
                    log_warn "Found stuck object: ${CYAN}${resource_type}/${item_name}${NC} [Finalizers: ${finalizers}] (Terminating)"
                else
                    log_info "Found object with finalizers: ${CYAN}${resource_type}/${item_name}${NC} [Finalizers: ${finalizers}]"
                fi

                if [ "$DRY_RUN" = true ]; then
                    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would patch: ${OC_BIN} patch ${resource_type} ${item_name} -n ${ns} --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
                else
                    if "$OC_BIN" patch "$resource_type" "$item_name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null; then
                        log_success "Patched and removed finalizers: ${resource_type}/${item_name}"
                        total_patched=$((total_patched + 1))
                    else
                        # Attempt JSON patch fallback
                        if "$OC_BIN" patch "$resource_type" "$item_name" -n "$ns" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' &>/dev/null; then
                            log_success "Patched (JSON) and removed finalizers: ${resource_type}/${item_name}"
                            total_patched=$((total_patched + 1))
                        else
                            log_error "Failed to remove finalizers from ${resource_type}/${item_name}"
                        fi
                    fi
                fi
            done <<< "$pending_items"
        fi
    done

    # Check if the namespace itself is stuck in Terminating
    if [ "$FORCE_NS" = true ]; then
        local ns_json
        ns_json=$("$OC_BIN" get namespace "$ns" -o json 2>/dev/null || true)

        if [ -n "$ns_json" ]; then
            local ns_status ns_finalizers
            ns_status=$(echo "$ns_json" | jq -r '.status.phase // ""')
            ns_finalizers=$(echo "$ns_json" | jq -r '(.spec.finalizers // []) + (.metadata.finalizers // []) | unique | join(", ")')

            if [ "$ns_status" = "Terminating" ] || [ -n "$ns_finalizers" ]; then
                log_warn "Namespace '${ns}' phase: ${ns_status}, Finalizers: [${ns_finalizers}]"

                if [ "$DRY_RUN" = true ]; then
                    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would finalize namespace '${ns}' via /api/v1/namespaces/${ns}/finalize"
                else
                    log_info "Finalizing namespace '${ns}'..."
                    # 1. Clear metadata.finalizers if present
                    "$OC_BIN" patch namespace "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true

                    # 2. Clear spec.finalizers via raw /finalize API endpoint
                    local clean_ns_json
                    clean_ns_json=$(echo "$ns_json" | jq '.spec.finalizers = [] | .metadata.finalizers = []')
                    if echo "$clean_ns_json" | "$OC_BIN" replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null; then
                        log_success "Successfully finalized namespace '${ns}'"
                        total_patched=$((total_patched + 1))
                    else
                        log_error "Could not finalize namespace '${ns}' via API endpoint"
                    fi
                fi
            fi
        fi
    fi

    log_info "Completed namespace ${CYAN}${ns}${NC}. Total objects finalized: ${GREEN}${total_patched}${NC}"
}

# Main execution
main() {
    check_prerequisites

    log_info "Target namespaces: ${CYAN}${NAMESPACES[*]}${NC}"

    for ns in "${NAMESPACES[@]}"; do
        finalize_namespace_resources "$ns"
    done

    echo ""
    echo "======================================================================"
    log_success "All targeted namespaces processed successfully."
    echo "======================================================================"
}

main
