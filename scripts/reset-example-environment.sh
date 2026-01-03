#!/bin/bash
################################################################################
# Reset Example Environment for Mapping Conflict Resolution Practice
# Purpose: Clean up all changes made during practice and recreate the initial
#          conflicted state by running the setup script again
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
ELASTICSEARCH_USER="${ELASTICSEARCH_USER:-elastic}"
ELASTICSEARCH_PASSWORD="${ELASTICSEARCH_PASSWORD:-elastic}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Print functions
print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header "Reset Mapping Conflict Example Environment"
echo ""
echo "Configuration:"
echo "  Elasticsearch URL: $ELASTICSEARCH_URL"
echo "  Username: $ELASTICSEARCH_USER"
echo ""

################################################################################
# Check Elasticsearch Connectivity
################################################################################
print_header "Checking Elasticsearch Connectivity"

if ! curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" "$ELASTICSEARCH_URL" >/dev/null 2>&1; then
    print_error "Cannot connect to Elasticsearch at $ELASTICSEARCH_URL"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Ensure Elasticsearch is running:"
    echo "     kubectl get pods -n elastic -l app=elasticsearch"
    echo ""
    echo "  2. Port-forward if needed:"
    echo "     kubectl port-forward -n elastic svc/elasticsearch-master 9200:9200"
    echo ""
    echo "  3. Check credentials (default: elastic/elastic)"
    echo ""
    exit 1
fi

print_info "✓ Connected to Elasticsearch"
CLUSTER_VERSION=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" "$ELASTICSEARCH_URL" | grep -o '"number":"[^"]*"' | head -1 | cut -d'"' -f4)
print_info "  Cluster version: $CLUSTER_VERSION"
echo ""

################################################################################
# Confirm Reset
################################################################################
print_header "Confirm Reset"

echo "This will:"
echo "  • Delete the data stream: logs-filestream.generic-default"
echo "  • Delete all backing indices and documents"
echo "  • Delete @custom component templates (if created)"
echo "  • Keep the base @package template and index template"
echo "  • Keep the ILM policy"
echo "  • Recreate the initial conflicted state"
echo ""
print_warning "All practice changes will be lost!"
echo ""
read -p "Continue with reset? (y/n): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Reset cancelled"
    exit 0
fi

echo ""

################################################################################
# Delete Data Stream and Backing Indices
################################################################################
print_header "Cleaning Up Data Stream"

echo "Checking for existing data stream..."

if curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" >/dev/null 2>&1; then

    print_info "Found data stream: logs-filestream.generic-default"

    # Get document count before deletion
    DOC_COUNT=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
        "$ELASTICSEARCH_URL/logs-filestream.generic-default/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2)

    print_info "  Current document count: $DOC_COUNT"

    echo "Deleting data stream and all backing indices..."
    curl -s -X DELETE -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
        "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" >/dev/null

    print_info "✓ Data stream deleted"
else
    print_info "No existing data stream found"
fi

echo ""

################################################################################
# Delete Any Reindexed Backing Indices
################################################################################
print_header "Cleaning Up Reindexed Indices"

echo "Checking for reindexed backing indices (with -1, -2 suffix)..."

REINDEXED_INDICES=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_cat/indices/.ds-logs-filestream.generic-default*" 2>/dev/null | awk '{print $3}' || echo "")

if [ -n "$REINDEXED_INDICES" ]; then
    echo "$REINDEXED_INDICES" | while read -r index; do
        if [ -n "$index" ]; then
            print_info "Deleting reindexed index: $index"
            curl -s -X DELETE -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
                "$ELASTICSEARCH_URL/$index" >/dev/null 2>&1 || true
        fi
    done
    print_info "✓ Reindexed indices cleaned up"
else
    print_info "No reindexed indices found"
fi

echo ""

################################################################################
# Delete @custom Component Templates
################################################################################
print_header "Cleaning Up @custom Component Templates"

echo "Checking for @custom component templates..."

CUSTOM_TEMPLATES=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_component_template" | grep -o '"logs@custom[^"]*"' | tr -d '"' || echo "")

if [ -n "$CUSTOM_TEMPLATES" ]; then
    echo "$CUSTOM_TEMPLATES" | while read -r template; do
        if [ -n "$template" ]; then
            print_info "Deleting component template: $template"
            curl -s -X DELETE -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
                "$ELASTICSEARCH_URL/_component_template/$template" >/dev/null
        fi
    done
    print_info "✓ @custom component templates deleted"
else
    print_info "No @custom component templates found"
fi

echo ""

################################################################################
# Verify Cleanup
################################################################################
print_header "Verifying Cleanup"

# Check data stream is gone
if curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" >/dev/null 2>&1; then
    print_warning "Data stream still exists (this shouldn't happen)"
else
    print_info "✓ Data stream removed"
fi

# Check backing indices are gone
REMAINING_INDICES=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_cat/indices/.ds-logs-filestream.generic-default*" 2>/dev/null | wc -l)

if [ "$REMAINING_INDICES" -eq 0 ]; then
    print_info "✓ All backing indices removed"
else
    print_warning "Found $REMAINING_INDICES remaining backing indices"
fi

# Verify @package template still exists
if curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_component_template/logs@package" >/dev/null 2>&1; then
    print_info "✓ Base @package template preserved"
else
    print_warning "Base @package template not found (will be recreated)"
fi

# Verify index template still exists
if curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_index_template/logs-filestream.generic-default" >/dev/null 2>&1; then
    print_info "✓ Index template preserved"
else
    print_warning "Index template not found (will be recreated)"
fi

# Verify ILM policy still exists
if curl -sf -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/_ilm/policy/logs" >/dev/null 2>&1; then
    print_info "✓ ILM policy preserved"
else
    print_warning "ILM policy not found (will be recreated)"
fi

echo ""

################################################################################
# Recreate Initial State
################################################################################
print_header "Recreating Initial Conflicted State"

echo "Running setup-example-environment.sh to recreate the practice environment..."
echo ""

if [ -f "$SCRIPT_DIR/setup-example-environment.sh" ]; then
    # Run the setup script
    bash "$SCRIPT_DIR/setup-example-environment.sh"
else
    print_error "Cannot find setup-example-environment.sh"
    echo ""
    echo "Expected location: $SCRIPT_DIR/setup-example-environment.sh"
    echo ""
    echo "Please ensure the setup script exists and try again."
    exit 1
fi

################################################################################
# Display Success Message
################################################################################
echo ""
print_header "Reset Complete!"

echo ""
echo -e "${GREEN}✓ Environment has been reset to initial state!${NC}"
echo ""
echo "The practice environment now has:"
echo "  • Fresh data stream: logs-filestream.generic-default"
echo "  • Mapping conflict: log.offset is 'keyword' (should be 'long')"
echo "  • 10 sample documents across 2 backing indices"
echo "  • ILM policy, component templates, and index template"
echo ""
echo "You can now practice the reindexing workflow again!"
echo ""
echo "Next steps:"
echo "  1. Open Kibana: http://localhost:5601"
echo "  2. Review the README.md for the reindexing procedure"
echo "  3. Practice resolving the log.offset mapping conflict"
echo ""
