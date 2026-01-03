#!/bin/bash
################################################################################
# Setup Example Environment for Mapping Conflict Resolution Practice
# Purpose: Create data streams with intentional mapping conflicts, ILM policies,
#          and sample data to practice the reindexing workflow
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

print_header "Mapping Conflict Example Environment Setup"
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
CLUSTER_INFO=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" "$ELASTICSEARCH_URL")
CLUSTER_VERSION=$(echo "$CLUSTER_INFO" | grep -o '"number":"[^"]*"' | head -1 | cut -d'"' -f4)
print_info "  Cluster version: $CLUSTER_VERSION"
echo ""

################################################################################
# Create ILM Policy
################################################################################
print_header "Creating ILM Policy"

echo "Creating 'logs' ILM policy with hot/warm/cold phases..."

curl -s -X PUT -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_ilm/policy/logs" \
  -H "Content-Type: application/json" \
  -d '{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "30d"
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          },
          "forcemerge": {
            "max_num_segments": 1
          },
          "set_priority": {
            "priority": 50
          }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "set_priority": {
            "priority": 0
          }
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}' >/dev/null

print_info "✓ ILM policy 'logs' created"
echo ""

################################################################################
# Create Component Template for @package Mappings
################################################################################
print_header "Creating @package Component Template"

echo "Creating logs@package component template with ECS mappings..."

curl -s -X PUT -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_component_template/logs@package" \
  -H "Content-Type: application/json" \
  -d '{
  "template": {
    "settings": {
      "index.lifecycle.name": "logs"
    },
    "mappings": {
      "properties": {
        "@timestamp": {
          "type": "date"
        },
        "message": {
          "type": "text"
        },
        "host": {
          "properties": {
            "name": {
              "type": "keyword"
            }
          }
        },
        "event": {
          "properties": {
            "dataset": {
              "type": "keyword"
            }
          }
        }
      }
    }
  },
  "version": 1,
  "_meta": {
    "description": "Package mappings for filestream logs"
  }
}' >/dev/null

print_info "✓ Component template 'logs@package' created"
echo ""

################################################################################
# Create Index Template for Data Stream
################################################################################
print_header "Creating Index Template"

echo "Creating 'logs-filestream.generic-default' index template..."

curl -s -X PUT -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_index_template/logs-filestream.generic-default" \
  -H "Content-Type: application/json" \
  -d '{
  "index_patterns": ["logs-filestream.generic-default*"],
  "data_stream": {},
  "composed_of": ["logs@package"],
  "priority": 200,
  "_meta": {
    "description": "Index template for generic filestream logs"
  }
}' >/dev/null

print_info "✓ Index template 'logs-filestream.generic-default' created"
echo ""

################################################################################
# Create First Backing Index with Incorrect Mapping (keyword)
################################################################################
print_header "Creating Data Stream with Mapping Conflict"

echo "Step 1: Ingesting documents with log.offset as keyword (incorrect)..."

# Ingest documents that will cause log.offset to be mapped as keyword
for i in {1..5}; do
  curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/logs-filestream.generic-default/_doc" \
    -H "Content-Type: application/json" \
    -d "{
    \"@timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",
    \"message\": \"Log message $i from first batch\",
    \"log\": {
      \"offset\": \"offset_$i\"
    },
    \"host\": {
      \"name\": \"server-01\"
    },
    \"event\": {
      \"dataset\": \"generic.log\"
    }
  }" >/dev/null
  sleep 0.1
done

print_info "✓ Ingested 5 documents with log.offset as keyword"
echo ""

# Rollover to create second backing index
echo "Step 2: Rolling over to create second backing index..."

curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/logs-filestream.generic-default/_rollover" >/dev/null

sleep 2
print_info "✓ Data stream rolled over"
echo ""

################################################################################
# Create Second Backing Index with Incorrect Mapping (still keyword from dynamic)
################################################################################
echo "Step 3: Ingesting more documents with log.offset as keyword..."

for i in {6..10}; do
  curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/logs-filestream.generic-default/_doc" \
    -H "Content-Type: application/json" \
    -d "{
    \"@timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",
    \"message\": \"Log message $i from second batch\",
    \"log\": {
      \"offset\": \"offset_$i\"
    },
    \"host\": {
      \"name\": \"server-02\"
    },
    \"event\": {
      \"dataset\": \"generic.log\"
    }
  }" >/dev/null
  sleep 0.1
done

print_info "✓ Ingested 5 more documents with log.offset as keyword"
print_warning "  Mapping conflict created: log.offset is 'keyword' but should be 'long' per ECS"
echo ""

################################################################################
# Verify Data Stream
################################################################################
print_header "Verifying Data Stream"

DATA_STREAM_INFO=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default")

BACKING_INDICES=$(echo "$DATA_STREAM_INFO" | grep -o '"name":"\.ds-[^"]*"' | wc -l)
TOTAL_DOCS=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/logs-filestream.generic-default/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2)

print_info "✓ Data stream created: logs-filestream.generic-default"
print_info "  Backing indices: $BACKING_INDICES"
print_info "  Total documents: $TOTAL_DOCS"
echo ""

################################################################################
# Display Mapping Conflict
################################################################################
print_header "Mapping Conflict Details"

echo "Checking field mappings across backing indices..."
echo ""

FIRST_INDEX=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" | \
  grep -o '"name":"\.ds-logs-filestream\.generic-default[^"]*"' | head -1 | cut -d'"' -f4)

echo "First backing index: $FIRST_INDEX"

MAPPING=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/$FIRST_INDEX/_mapping")

LOG_OFFSET_TYPE=$(echo "$MAPPING" | grep -A 5 '"offset"' | grep '"type"' | head -1 | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

echo "  log.offset type: $LOG_OFFSET_TYPE"
echo ""

if [ "$LOG_OFFSET_TYPE" = "keyword" ]; then
    print_warning "CONFLICT DETECTED!"
    echo ""
    echo "  Current mapping: log.offset is 'keyword'"
    echo "  Expected (ECS):  log.offset should be 'long'"
    echo ""
    echo "This is the mapping conflict you will practice resolving!"
else
    print_info "log.offset type: $LOG_OFFSET_TYPE"
fi

echo ""

################################################################################
# Display Next Steps
################################################################################
print_header "Environment Setup Complete!"

echo ""
echo -e "${GREEN}✓ Practice environment is ready!${NC}"
echo ""
echo "What was created:"
echo "  • ILM policy: 'logs' (hot/warm/cold/delete phases)"
echo "  • Component template: 'logs@package'"
echo "  • Index template: 'logs-filestream.generic-default'"
echo "  • Data stream: 'logs-filestream.generic-default'"
echo "  • $BACKING_INDICES backing indices with $TOTAL_DOCS total documents"
echo "  • Mapping conflict: log.offset is 'keyword' (should be 'long')"
echo ""
echo "Access Kibana to view the conflict:"
echo ""
echo -e "  ${GREEN}http://localhost:5601${NC}"
echo ""
echo "Steps to see the conflict:"
echo "  1. Go to: Stack Management → Data Views"
echo "  2. Create data view for pattern: logs-filestream.generic-default*"
echo "  3. Look for the warning icon on 'log.offset' field"
echo "  4. Click the field to see the type conflict across indices"
echo ""
echo "Practice the resolution workflow:"
echo "  1. Review: ../README.md for the complete reindexing procedure"
echo "  2. Check ECS: log.offset should be type 'long'"
echo "  3. Create @custom component template with correct mapping"
echo "  4. Reindex each backing index with corrected mapping"
echo "  5. Verify document counts match"
echo "  6. Delete old backing indices"
echo ""
echo "Useful commands:"
echo ""
echo "  # View data stream"
echo "  GET _data_stream/logs-filestream.generic-default"
echo ""
echo "  # View backing indices"
echo "  GET logs-filestream.generic-default/_search"
echo ""
echo "  # Check mapping conflict"
echo "  GET .ds-logs-filestream.generic-default*/_mapping/field/log.offset"
echo ""
echo "  # Count documents"
echo "  GET logs-filestream.generic-default/_count"
echo ""

################################################################################
# Cleanup Instructions
################################################################################
echo "To clean up this environment:"
echo ""
echo "  # Delete data stream and backing indices"
echo "  DELETE _data_stream/logs-filestream.generic-default"
echo ""
echo "  # Delete index template"
echo "  DELETE _index_template/logs-filestream.generic-default"
echo ""
echo "  # Delete component template"
echo "  DELETE _component_template/logs@package"
echo ""
echo "  # Delete ILM policy"
echo "  DELETE _ilm/policy/logs"
echo ""
