# Bookwise Native KOReader Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Bookwise library, authentication, and reading sync directly into the KOReader fork — not as a plugin — so Bookwise is the default experience on launch.

**Architecture:** Three new Lua modules under `frontend/bookwise/`: API client, library grid UI, and reader sync. Startup flow modified to show Bookwise library as default home with login prompt on first launch. File manager accessible via toggle button. Existing plugin code extracted and adapted.

**Tech Stack:** Lua, KOReader widget system (InputContainer, Menu, HorizontalGroup/VerticalGroup), LuaSocket HTTP, LuaSettings persistence.

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `frontend/bookwise/bookwiseapi.lua` | HTTP API client (auth, library fetch, download, sync) |
| `frontend/bookwise/bookwiselibrary.lua` | Library grid screen with text covers, download flow |
| `frontend/bookwise/bookwisesync.lua` | ReaderUI module: progress sync, XP tracking, position restore |

### Modified Files
| File | Change |
|------|--------|
| `reader.lua` | Startup: check session → show library or login; add `"bookwise"` to start_with options |
| `frontend/apps/filemanager/filemanager.lua` | Add "Bookwise" button in title bar to switch back to library |
| `frontend/apps/filemanager/filemanagermenu.lua` | Add "Bookwise library" to start_with menu |
| `frontend/apps/reader/readerui.lua` | Register BookwiseSync module when opening a Bookwise book |

---

### Task 1: Create BookwiseApi

**Files:**
- Create: `frontend/bookwise/bookwiseapi.lua`

- [ ] **Step 1: Create the API client module**

Extract from `bookwise-koplugin/BookwiseApi.lua`, adapted for core integration. Must include:
- `BookwiseApi:new(o)` constructor
- `BookwiseApi:_request(method, path, body, callback)` — HTTP/HTTPS with MOBILESESSION header
- `BookwiseApi:login(email, password, callback)` — POST `/bookwise/api/login/`
- `BookwiseApi:getLibrary(callback)` — GET `/bookwise/api/tracked_books/pull/` with sort/filter
- `BookwiseApi:getDocument(document_id, callback)` — GET `/reader/api/get_document/`
- `BookwiseApi:getRawContent(parsed_doc_id, dest_path, callback)` — download EPUB
- `BookwiseApi:getExperience(callback)` — GET `/reader/api/state/`
- `BookwiseApi:syncReadingProgress(document_id, scroll_depth, prev, xp_total, xp_prev, callback)` — POST `/reader/api/state/update/`

Key differences from plugin version:
- Use `require("json")` directly (available in core)
- Import socketutil for timeout management
- Agent string: `"bookwise-koreader"` instead of `"koreader-plugin"`

- [ ] **Step 2: Commit**

---

### Task 2: Create BookwiseLibrary Grid Screen

**Files:**
- Create: `frontend/bookwise/bookwiselibrary.lua`

- [ ] **Step 1: Create library screen with text-cover grid**

This is the main Bookwise home screen. Architecture:
- Extends `InputContainer`
- Contains a `Menu` widget showing books in grid layout
- Each book cell: colored rectangle + title text + author + status badge + progress bar
- Title bar with "Local Files" button and "Refresh" button
- Handles book selection: if downloaded → open; if not → download dialog → download → open

Key methods:
- `BookwiseLibrary:init()` — build item_table from books, create Menu
- `BookwiseLibrary:buildItemTable()` — convert API books to menu items with text covers
- `BookwiseLibrary:onSelectBook(book)` — handle tap: check local, download or open
- `BookwiseLibrary:getLocalPath(book)` — compute local EPUB path
- `BookwiseLibrary:downloadBook(book)` — resolve doc → download raw content → save metadata → open
- `BookwiseLibrary:openBook(path, book)` — close library, open ReaderUI
- `BookwiseLibrary:switchToFileManager()` — close library, show FileManager
- `BookwiseLibrary:show(books, api, settings)` — class method to create and display

Item table entry format:
```lua
{
    text = book.title,
    mandatory = book.author or "",
    bold = (book.status == "currently_reading"),
    dim = (book.status == "finished"),
    book = book,  -- full book object reference
}
```

Status display in item text: prefix with status emoji/text
Progress: shown in mandatory field as "Author  42%"

- [ ] **Step 2: Commit**

---

### Task 3: Create BookwiseSync Reader Module

**Files:**
- Create: `frontend/bookwise/bookwisesync.lua`

- [ ] **Step 1: Create reader sync module**

ReaderUI module that handles:
- Position restore on book open (with 0.5s, 1.5s, 3.0s retry delays)
- XP tracking on page turns
- Periodic sync every 30 seconds
- Final sync on document close

Class structure:
- Extends `InputContainer` (same pattern as other ReaderUI modules)
- Constructor receives `{ ui, document }` from ReaderUI
- Reads book metadata from settings (`book_map_<path>`)
- If not a Bookwise book, becomes a no-op

Key event handlers:
- `onReaderReady` — fetch XP, restore position
- `onPageUpdate` — calculate words read, show XP notification, accumulate session XP
- `onCloseDocument` — final sync

Sync logic:
- Threshold: only sync if progress changed > 0.5%
- Payload: position (scroll_depth) + XP events via `/reader/api/state/update/`
- Timer: `UIManager:scheduleIn(30, sync_function)` recurring

- [ ] **Step 2: Commit**

---

### Task 4: Modify Startup Flow

**Files:**
- Modify: `reader.lua` (lines 252-302)
- Modify: `frontend/apps/filemanager/filemanagermenu.lua` (lines 976-1008)

- [ ] **Step 1: Add Bookwise startup option to settings menu**

In `filemanagermenu.lua`, add to `start_withs` table:
```lua
{ _("Bookwise library"), "bookwise" },
```

- [ ] **Step 2: Modify reader.lua startup logic**

After the existing `start_with` handling, add Bookwise library launch:

When `start_with == "bookwise"` OR no start_with is set and session exists:
1. Load settings from `bookwise.lua`
2. If `session_id` exists → fetch library → show BookwiseLibrary
3. If no `session_id` → show login dialog → on success → fetch library → show BookwiseLibrary

When Bookwise is the default:
- Still create FileManager in background (needed for module infrastructure)
- Show BookwiseLibrary on top

Login dialog:
- MultiInputDialog with email + password fields
- On success: save session_id, fetch library, show grid
- On cancel: fall through to file manager

- [ ] **Step 3: Set Bookwise as default start_with for new installations**

In `reader.lua`, change the default:
```lua
local start_with = G_reader_settings:readSetting("start_with") or "bookwise"
```

- [ ] **Step 4: Commit**

---

### Task 5: Add File Manager Toggle

**Files:**
- Modify: `frontend/apps/filemanager/filemanager.lua`

- [ ] **Step 1: Add "Bookwise" button to FileManager title bar**

Add a left-side button or menu item that switches back to the Bookwise library screen. Pattern: similar to how History/Collections are shown as overlays.

Method: `FileManager:switchToBookwise()` — close file manager, show BookwiseLibrary

- [ ] **Step 2: Commit**

---

### Task 6: Register BookwiseSync in ReaderUI

**Files:**
- Modify: `frontend/apps/reader/readerui.lua`

- [ ] **Step 1: Register BookwiseSync module**

After existing module registrations in `ReaderUI:init()`, add:
```lua
self:registerModule("bookwise_sync", require("bookwise/bookwisesync"):new{
    dialog = self.dialog,
    view = self.view,
    ui = self,
    document = self.document,
})
```

This registers for ALL books — BookwiseSync's init will check if the current book is a Bookwise book and become a no-op if not.

- [ ] **Step 2: Commit**

---

### Task 7: Fix Logo and Deploy

**Files:**
- Modify: `resources/koreader.svg` (improve logo)
- Modify: `resources/koreader.png` (regenerate)

- [ ] **Step 1: Create a proper Bookwise logo**

Generate a clean, high-contrast logo that works well on e-ink (grayscale). Open book icon with "B" lettermark.

- [ ] **Step 2: Deploy all changes to Kindle via SSH**

Copy modified files to `/mnt/us/koreader/` on the Kindle device:
- `frontend/bookwise/` (new directory with 3 files)
- Modified `reader.lua`, `frontend/apps/filemanager/filemanager.lua`, `frontend/apps/filemanager/filemanagermenu.lua`, `frontend/apps/reader/readerui.lua`
- Updated resources

- [ ] **Step 3: Test on Kindle**

Restart Bookwise via KUAL and verify:
- Login prompt appears on first launch
- Library shows with text covers after login
- Tapping a book downloads and opens it
- Progress syncs during reading
- "Local Files" button switches to file manager
- "Bookwise" button switches back

- [ ] **Step 4: Commit**
