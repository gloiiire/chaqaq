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

- **Leaves** — `list_leaves`, `list_root_leaves`, `list_child_leaves`, `get_leaf`, `create_leaf`, `delete_leaf`, `delete_all_leaves`, `update_leaf_*`
- **Blocks** — `add_block`, `add_child_block`, `update_block`, `delete_block`, `duplicate_block`, `reorder_blocks`, `reorder_child_blocks`, `move_block`, `indent_block`, `outdent_block`, `set_block_color`, `set_block_background_color`, `set_block_text_direction`
- **Trash** — `list_deleted_leaves`, `restore_leaf`, `purge_leaf` (and the shelf / book / entry equivalents)
- **Search** — `search_leaves`, `search_in_blocks`, `search_in_blocks_with_snippets`, `search_books`, `search_shelves`
- **Shelves** — `create_shelf`, `list_shelves`, `get_shelf`, `rename_shelf`, `update_shelf_icon`, `delete_shelf`, `move_shelf_to`, `move_leaf_to_shelf`, `list_leaves_in_shelf`
- **Books** — `list_books`, `get_book`, `create_book`, `delete_book`, `delete_all_books`
- **Book entries** — `add_entry`, `update_entry`, `delete_entry`, `restore_entry`, `purge_entry`, `list_deleted_entries`
- **Book properties + views** — `add_property`, `rename_property`, `delete_property`, `add_view`, `update_view`, `set_view_sort`, `delete_view`
- **Book queries** — `query_book`, `query_book_with_rollups`, `grouped_query_book`, `column_aggregate_book`, `search_book_entries`

Each tool's full input schema lives in `tools/list`; the binary advertises it on startup.

## Notes

- iOS sandbox DB is unreachable from the host process. Until iCloud / CRDT sync ships, the MCP only sees data created on the same machine (either by a macOS build of the app, or by the agent itself).
- The server is single-threaded over stdio. For multi-agent setups, run multiple instances pointing at separate SQLite files.
