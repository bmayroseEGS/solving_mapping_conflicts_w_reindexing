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
# Create First Backing Index with CORRECT Mapping (long)
################################################################################
print_header "Creating Data Stream with Mapping Conflict"

echo "Step 1: Ingesting documents with log.offset as long (correct per ECS)..."

# Ingest documents with numeric values - Elasticsearch will map as long
for i in {1..5}; do
  OFFSET=$((1000 + i * 100))
  curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/logs-filestream.generic-default/_doc" \
    -H "Content-Type: application/json" \
    -d "{
    \"@timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",
    \"message\": \"Log message $i from first batch\",
    \"log\": {
      \"offset\": $OFFSET
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

print_info "✓ Ingested 5 documents with log.offset as long (numeric values)"
echo ""

# Create second backing index manually with keyword mapping
echo "Step 2: Creating second backing index with keyword mapping..."

# Get the current backing index name to generate the next one
FIRST_INDEX=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" | \
  grep -o '"name":"\.ds-logs-filestream\.generic-default-[^"]*"' | head -1 | cut -d'"' -f4)

# Extract the date part and increment the index number
INDEX_BASE=$(echo "$FIRST_INDEX" | sed 's/-[0-9]*$//')
SECOND_INDEX="${INDEX_BASE}-000002"

echo "Creating backing index: $SECOND_INDEX"

# Create the second backing index with explicit keyword mapping for log.offset
curl -s -X PUT -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/$SECOND_INDEX" \
  -H "Content-Type: application/json" \
  -d "{
  \"mappings\": {
    \"properties\": {
      \"@timestamp\": { \"type\": \"date\" },
      \"message\": { \"type\": \"text\" },
      \"host\": {
        \"properties\": {
          \"name\": { \"type\": \"keyword\" }
        }
      },
      \"event\": {
        \"properties\": {
          \"dataset\": { \"type\": \"keyword\" }
        }
      },
      \"log\": {
        \"properties\": {
          \"offset\": { \"type\": \"keyword\" }
        }
      }
    }
  }
}" >/dev/null

# Add the new backing index to the data stream
curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_data_stream/_modify" \
  -H "Content-Type: application/json" \
  -d "{
  \"actions\": [
    {
      \"add_backing_index\": {
        \"data_stream\": \"logs-filestream.generic-default\",
        \"index\": \"$SECOND_INDEX\"
      }
    }
  ]
}" >/dev/null

print_info "✓ Second backing index created with keyword mapping"
echo ""

################################################################################
# Ingest data into second backing index
################################################################################
echo "Step 3: Ingesting documents into second backing index..."

# Ingest directly into the second backing index with string values
for i in {6..10}; do
  curl -s -X POST -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
    "$ELASTICSEARCH_URL/$SECOND_INDEX/_doc" \
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

print_info "✓ Ingested 5 documents with log.offset as keyword (string values)"
print_warning "  MAPPING CONFLICT CREATED!"
print_warning "  First backing index: log.offset is 'long'"
print_warning "  Second backing index: log.offset is 'keyword'"
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

echo ""
echo "Checking second backing index..."

SECOND_INDEX=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/_data_stream/logs-filestream.generic-default" | \
  grep -o '"name":"\.ds-logs-filestream\.generic-default[^"]*"' | tail -1 | cut -d'"' -f4)

echo "Second backing index: $SECOND_INDEX"

SECOND_MAPPING=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" \
  "$ELASTICSEARCH_URL/$SECOND_INDEX/_mapping")

SECOND_LOG_OFFSET_TYPE=$(echo "$SECOND_MAPPING" | grep -A 5 '"offset"' | grep '"type"' | head -1 | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

echo "  log.offset type: $SECOND_LOG_OFFSET_TYPE"
echo ""

if [ "$LOG_OFFSET_TYPE" != "$SECOND_LOG_OFFSET_TYPE" ]; then
    print_warning "MAPPING CONFLICT DETECTED!"
    echo ""
    echo "  First index ($FIRST_INDEX):"
    echo "    log.offset type: $LOG_OFFSET_TYPE"
    echo ""
    echo "  Second index ($SECOND_INDEX):"
    echo "    log.offset type: $SECOND_LOG_OFFSET_TYPE"
    echo ""
    echo "This conflict will cause issues with:"
    echo "  • Kibana data views showing a warning icon"
    echo "  • Aggregations on log.offset field"
    echo "  • Visualizations using this field"
    echo "  • The Security app if using this field"
else
    print_info "Both indices have matching type: $LOG_OFFSET_TYPE"
    print_warning "Note: For ECS compliance, log.offset should be 'long'"
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
echo "  • Mapping conflict: log.offset has different types across indices"
echo "    - First index: 'long' (correct per ECS)"
echo "    - Second index: 'keyword' (incorrect)"
echo ""
echo "Access Kibana to view the conflict:"
echo ""
echo -e "  ${GREEN}http://localhost:5601${NC}"
echo ""
echo "Steps to see the conflict:"
echo "  1. Go to: Stack Management → Data Views"
echo "  2. Create data view for pattern: logs-filestream.generic-default*"
echo "  3. Look for the warning icon (⚠️) on 'log.offset' field"
echo "  4. Click the field to see the type conflict across indices"
echo ""
echo "Practice the resolution workflow:"
echo "  1. Review: ../README.md for the complete reindexing procedure"
echo "  2. The goal: Make all indices use 'long' type for log.offset (ECS standard)"
echo "  3. Create @custom component template with correct mapping"
echo "  4. Reindex the second backing index (keyword) to use 'long'"
echo "  5. Verify document counts match"
echo "  6. Delete old backing index with keyword mapping"
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
