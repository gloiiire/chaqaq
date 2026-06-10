# pinkha-mcp

Model Context Protocol server exposing a local pinkha SQLite store to AI agents (Claude Desktop, Claude Code, Cursor, …).

Reuses the same `PinkhaApi` the iOS / macOS apps ship — no logic duplication. The server is a thin JSON-RPC adapter over stdio.

## Build

```bash
cargo build --release -p pinkha-mcp
# binary lands at ../../target/release/pinkha-mcp
```

## Run

```bash
pinkha-mcp <path/to/pinkha.db>
```

The DB path is mandatory. The file is created on first write if it doesn't exist (lets you point at a fresh sandbox for testing).

## Wire it into an MCP client

`~/Library/Application Support/Claude/claude_desktop_config.json` (Claude Desktop) or `mcp.json` (Claude Code):

```json
{
  "mcpServers": {
    "pinkha": {
      "command": "/absolute/path/to/pinkha-mcp",
      "args": ["/absolute/path/to/your/pinkha.db"]
    }
  }
}
```

Restart the client and the `pinkha` tools should appear in the tool picker.

## Tool catalogue

The server exposes the full `PinkhaApi` surface — ~65 tools across:

- **Documents** — `list_documents`, `list_root_documents`, `list_child_documents`, `get_document`, `create_document`, `delete_document`, `delete_all_documents`, `update_document_*`
- **Blocks** — `add_block`, `add_child_block`, `update_block`, `delete_block`, `duplicate_block`, `reorder_blocks`, `reorder_child_blocks`, `move_block`, `indent_block`, `outdent_block`, `set_block_color`, `set_block_background_color`, `set_block_text_direction`
- **Trash** — `list_deleted_documents`, `restore_document`, `purge_document` (and the folder / database / entry equivalents)
- **Search** — `search_documents`, `search_in_blocks`, `search_in_blocks_with_snippets`, `search_databases`, `search_folders`
- **Folders** — `create_folder`, `list_folders`, `get_folder`, `rename_folder`, `update_folder_icon`, `delete_folder`, `move_folder_to`, `move_document_to_folder`, `list_documents_in_folder`
- **Databases** — `list_databases`, `get_database`, `create_database`, `delete_database`, `delete_all_databases`
- **Database entries** — `add_entry`, `update_entry`, `delete_entry`, `restore_entry`, `purge_entry`, `list_deleted_entries`
- **Database properties + views** — `add_property`, `rename_property`, `delete_property`, `add_view`, `update_view`, `set_view_sort`, `delete_view`
- **Database queries** — `query_database`, `query_database_with_rollups`, `grouped_query_database`, `column_aggregate_database`, `search_database_entries`

Each tool's full input schema lives in `tools/list`; the binary advertises it on startup.

## Notes

- iOS sandbox DB is unreachable from the host process. Until iCloud / CRDT sync ships, the MCP only sees data created on the same machine (either by a macOS build of the app, or by the agent itself).
- The server is single-threaded over stdio. For multi-agent setups, run multiple instances pointing at separate SQLite files.
