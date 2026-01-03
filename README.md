# Solving Mapping Conflicts with Reindexing

A practical guide and toolset for resolving Elasticsearch mapping conflicts through reindexing, based on real-world implementations and best practices.

## Overview

This repository provides scripts, documentation, and examples for resolving mapping conflicts in Elasticsearch data streams. Mapping conflicts occur when fields are mapped with incompatible types across different backing indices, causing issues with visualizations, dashboards, the Security app, and aggregations.

## Background

Based on the blog post **"Reindexing Data Streams Due to Mapping Conflicts"** by **Lisa Larribas**, Consulting Architect at Elastic, this repository demonstrates the complete workflow for:

- Identifying mapping conflicts in data views
- Preparing correct mappings using component templates
- Creating new backing indices with proper field types
- Reindexing data while preserving document integrity
- Managing ILM policies for reindexed data
- Verifying conflict resolution

## What This Repository Contains

- **Step-by-step reindexing scripts** for Elasticsearch Dev Tools
- **Component template examples** for @custom mappings
- **Automated conflict detection queries**
- **Validation scripts** to verify reindex success
- **ILM policy management** for reindexed indices
- **Best practices documentation** for preventing future conflicts

## Prerequisites

Before using this repository, you need a running Elasticsearch and Kibana deployment. See [PREREQUISITES.md](PREREQUISITES.md) for detailed setup instructions.

### Quick Prerequisites Summary

- **Elasticsearch 8.x or 9.x** with proper cluster configuration
- **Kibana** for Dev Tools access
- **Sufficient storage** in Hot tier for temporary index copies
- **Access to Stack Management** for component template management

## Key Concepts

### Mapping Conflicts

Mapping conflicts typically occur when:
- Data is ingested before specific mappings are defined
- Elasticsearch uses dynamic templates to infer types
- A field is mapped as different types (e.g., `keyword` vs `long`) across indices

### Resolution Process

1. **Identify conflicts** via Data Views in Kibana
2. **Verify correct mapping** against ECS field reference
3. **Create/update @custom component template** with correct mappings
4. **Create new backing index** with corrected mapping
5. **Reindex data** from old to new backing index
6. **Update data stream** to include new backing index
7. **Apply ILM policy** to manage index lifecycle
8. **Delete old backing index** after verification

## Quick Start

### Setup Practice Environment

To quickly create a practice environment with intentional mapping conflicts:

```bash
cd scripts
./setup-example-environment.sh
```

This script will:
- Create an ILM policy for log data
- Set up component templates and index templates
- Create a data stream with mapping conflicts
- Ingest sample documents
- Verify the environment is ready

**What gets created:**
- Data stream: `logs-filestream.generic-default`
- Mapping conflict: `log.offset` has different types across backing indices
  - First backing index: `log.offset` as `keyword` (incorrect - from dynamic mapping)
  - Second backing index: `log.offset` as `long` (correct per ECS)
- 10 sample documents (5 in each backing index)

**Why this scenario?**
This matches the blog's real-world scenario where data was ingested BEFORE proper mappings were defined in a @custom component template. Elasticsearch used dynamic templates and incorrectly mapped `log.offset` as `keyword`. Later, when correct mappings were added, newer backing indices got the proper `long` type.

After running the setup script, follow the **Basic Reindexing Workflow** below to practice resolving the conflict.

### Reset Practice Environment

To reset the environment back to the initial conflicted state (useful for practicing multiple times):

```bash
cd scripts
./reset-example-environment.sh
```

This script will:
- Delete the data stream and all backing indices
- Clean up any reindexed indices you created during practice
- Remove any @custom component templates you added
- Preserve the base @package template and ILM policy
- Recreate the initial conflicted state automatically

## Usage

### Basic Reindexing Workflow

```elasticsearch
# 1. Create new backing index with corrected mapping
PUT .ds-logs-filestream.generic-default-2025.04.30-000001-1
{
  "settings": {
    "index.codec": "best_compression"
  },
  "mappings": {
    "properties": {
      "log": {
        "properties": {
          "offset": {
            "type": "long"  // Corrected from keyword
          }
        }
      }
    }
  }
}

# 2. Start reindex
POST _reindex?wait_for_completion=false
{
  "source": {
    "index": ".ds-logs-filestream.generic-default-2025.04.30-000001"
  },
  "dest": {
    "index": ".ds-logs-filestream.generic-default-2025.04.30-000001-1"
  }
}

# 3. Monitor progress
GET _tasks/<task_id>

# 4. Verify document count
GET .ds-logs-filestream.generic-default-2025.04.30-000001/_count
GET .ds-logs-filestream.generic-default-2025.04.30-000001-1/_count

# 5. Add new backing index to data stream
POST _data_stream/_modify
{
  "actions": [
    {
      "add_backing_index": {
        "data_stream": "logs-filestream.generic-default",
        "index": ".ds-logs-filestream.generic-default-2025.04.30-000001-1"
      }
    }
  ]
}

# 6. Move to appropriate tier
POST _ilm/move/.ds-logs-filestream.generic-default-2025.04.30-000001-1
{
  "current_step": {
    "phase": "hot",
    "action": "rollover",
    "name": "check-rollover-ready"
  },
  "next_step": {
    "phase": "warm"
  }
}

# 7. Delete old backing index
DELETE .ds-logs-filestream.generic-default-2025.04.30-000001
```

## Project Structure

```
solving_mapping_conflicts_w_reindexing/
├── README.md                          # This file
├── PREREQUISITES.md                   # Setup requirements
├── scripts/                           # Setup and automation scripts
│   ├── setup-example-environment.sh  # Create practice environment
│   └── reset-example-environment.sh  # Reset to initial state
├── examples/                          # Example scenarios (planned)
│   ├── ecs-field-conflict/           # ECS field mapping conflicts
│   ├── custom-field-conflict/        # Custom field conflicts
│   └── multiple-conflicts/           # Handling multiple fields
└── templates/                         # Component template examples (planned)
    ├── custom-template-examples.json
    └── dynamic-template-examples.json
```

## Common Scenarios

### Scenario 1: ECS Field Mapped Incorrectly
**Problem:** `log.offset` mapped as `keyword` instead of `long`
**Solution:** Update @custom component template, reindex affected indices

### Scenario 2: Custom Field Type Conflict
**Problem:** Application-specific field has mixed types across indices
**Solution:** Determine correct type from majority usage, document in @custom template

### Scenario 3: Multiple Conflicts in Single Data Stream
**Problem:** Several fields have conflicts
**Solution:** Fix all mappings in @custom template simultaneously to avoid multiple reindex operations

## Important Considerations

### Storage Requirements
- Reindexing creates a **temporary copy** of the backing index in the Hot tier
- Ensure sufficient storage before beginning the process
- Plan for approximately 2x the size of the largest affected index

### ILM Policy Management
- New backing indices are created as **Unmanaged**
- Must manually apply ILM policy after creation
- Use `_ilm/move` to transition to appropriate tier

### Data Integrity
- Always verify document counts before and after reindexing
- Check mapping correctness with `_mapping` endpoint
- Test queries against new index before deleting old one

## Best Practices

1. **Plan Ahead**: Identify all conflicts before starting reindex
2. **Update @custom Templates**: Ensure future data uses correct mappings
3. **Use Compression**: Apply `best_compression` codec to new indices
4. **Monitor Progress**: Use task API to track long-running reindex operations
5. **Verify Before Delete**: Confirm counts, mappings, and queries before removing old indices
6. **Document Changes**: Keep records of which fields were corrected and why

## References

- [Elastic ECS Field Reference](https://www.elastic.co/docs/reference/ecs/ecs-field-reference)
- [Elasticsearch Reindex API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-reindex)
- Original Blog: "Reindexing Data Streams Due to Mapping Conflicts" by Lisa Larribas

## Contributing

Contributions are welcome! Please:
- Follow existing documentation style
- Test scripts before submitting
- Include examples for new scenarios
- Update this README with new sections

## License

This project is provided as-is for educational and operational purposes.

## Support

For issues or questions:
1. Check the [PREREQUISITES.md](PREREQUISITES.md) for setup help
2. Review examples in the `examples/` directory
3. Consult the official Elastic documentation links above

## Author

Based on work by Lisa Larribas, Consulting Architect, Federal at Elastic

Maintained Brian Mayrose
