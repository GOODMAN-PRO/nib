# Nib — Feature inventory (Goodnotes 6 parity + Nib-only)

This is the canonical list. Every Goodnotes item from the research inventory (493 items) has a stable ID and the build feature(s) that implement it (`F###`, defined in `forge-spec.json` and ARCHITECTURE.md §3). Nothing is dropped: items that cannot exist in a sideloaded app with no backend and no paid Apple account are marked **n/a** or **substitute**, and the note says what Nib does instead.

**ID scheme.** `T-###` tools, ink & objects · `D-###` documents, pages & library · `S-###` smart features, AI, audio, study & collaboration · `P-###` platform · `N-###` Nib-only. IDs follow the order of the research inventory within each area and never change; new items get the next free number.

**Status.** `parity` = matches Goodnotes · `parity+` = matches and goes further (note says how) · `partial` = core behaviour present, the note names the gap · `substitute` = Goodnotes' mechanism is replaced by an equivalent that works without a backend/paid account · `n/a` = tied to Goodnotes' business (accounts, plans, store, publishers), with the Nib stand-in noted.

| Status | Items |
|---|---|
| parity | 355 |
| parity+ | 36 |
| partial | 34 |
| substitute | 39 |
| n/a | 29 |
| **total** | **493** |

Why things are substituted: CloudKit/iCloud sync, APNs push and Sign in with Apple need a paid Apple Developer account, and App Groups (data widgets, share-extension hand-off) are available only when the sideloading tool registers one, so Nib uses them as a progressive enhancement; Goodnotes Cloud, public web links, Email-to-Goodnotes, the Marketplace store, accounts/plans/credits, education admin/roster servers and publisher DRM need Goodnotes' servers. Nib's substitutes: a user-chosen library folder in any Files provider (iCloud Drive, OneDrive, Dropbox, Google Drive) with conflict-free per-device files, WebDAV, local-network/relay live collaboration, local notifications, a free plugin/content gallery from JSON indexes, and bring-your-own AI.

## Tools, ink & objects (T-###)

| ID | Goodnotes feature | Status | Built by | Notes |
|---|---|---|---|---|
| T-001 | Pen tool (core handwriting) | parity | F007 F016 |  |
| T-002 | Pen style: Fountain Pen | parity | F007 |  |
| T-003 | Pen style: Ball Pen | parity | F007 |  |
| T-004 | Pen style: Brush Pen | parity | F007 |  |
| T-005 | Tip Flatness | parity | F007 |  |
| T-006 | Dynamic Ink / React to Pen Rotation | parity | F007 F043 | Pencil Pro barrel roll captured per point (StrokePoint.roll). |
| T-007 | Stroke Stabilization | parity | F007 F009 |  |
| T-008 | Reduce Latency | parity | F007 F101 |  |
| T-009 | Stroke pattern: Solid / Dashed / Dotted | parity | F007 F008 F004 |  |
| T-010 | Thickness presets | parity | F008 |  |
| T-011 | Color presets per tool | parity | F008 |  |
| T-012 | Eyedropper color picker | parity | F008 |  |
| T-013 | Draw and Hold (shape snapping while writing) | parity | F030 F007 |  |
| T-014 | Snap to Other Shapes | parity | F030 |  |
| T-015 | Pencil tool (graphite) | parity | F007 |  |
| T-016 | Highlighter tool | parity | F009 F004 |  |
| T-017 | PDF text highlight via long-press | parity | F042 |  |
| T-018 | Eraser tool and eraser styles | parity | F010 |  |
| T-019 | Erase Filter / Erase Highlighter Only | parity | F010 |  |
| T-020 | Clear Page | parity | F010 |  |
| T-021 | Eraser Auto-Deselect | parity | F010 |  |
| T-022 | Delete Specific Items | parity | F010 |  |
| T-023 | Scribble to Erase (pen gesture) | parity | F007 F010 |  |
| T-024 | Circle to Lasso (pen gesture) | parity | F007 F011 |  |
| T-025 | Lasso tool (freehand and rectangular) | parity | F011 |  |
| T-026 | Lasso 'Included in Selection' filter | parity | F011 |  |
| T-027 | Move selection, including across pages | parity | F012 |  |
| T-028 | Object Alignment guides and grid snapping | parity | F012 |  |
| T-029 | Scale / resize / rotate handles | parity | F012 |  |
| T-030 | Universal Object Menu | parity | F013 |  |
| T-031 | Recolor selection | parity | F013 |  |
| T-032 | Take Screenshot (lasso) | parity | F013 |  |
| T-033 | Arrange (Bring to Front / Send to Back) | parity+ | F013 | Also step forward/backward (item.arrange to: forward\|backward). |
| T-034 | Universal Object Selection / Quick Selection | parity | F011 F101 |  |
| T-035 | Sticky vs non-sticky tools; Pin Text Tool; last-tool memory | parity | F016 F026 |  |
| T-036 | Lock Objects | parity | F013 |  |
| T-037 | Layers (experimental) | parity+ | F041 | Free (no Pro gate); items can also be moved between layers. |
| T-038 | Edit Handwriting (Lasso Edit Mode / reflow) | partial | F058 | Reflow works for any Vision-recognised language, not only English; cursive/rotated lines still reflow poorly. |
| T-039 | Restyle handwriting (Smart Ink) | partial | F105 | No generative handwriting model on iOS: Restyle regularises baseline/size/slant, or re-synthesises the recognised text with a skeletonised handwriting-style system font (ink.writeText). |
| T-040 | Convert handwriting to text | parity | F057 |  |
| T-041 | Drag handwriting to other apps as text | parity | F014 |  |
| T-042 | Convert handwritten math | partial | F060 | Handwritten-math recognition uses the user's own vision-capable AI model; offline fallback handles simple arithmetic/algebra via Vision text recognition. |
| T-043 | Handwriting spellcheck | partial | F104 | Detection via Vision + UITextChecker; corrections are synthesised ink matched to word size/slant/colour, not a personalised handwriting model. |
| T-044 | Word Complete (discontinued) | substitute | F082 F059 | Discontinued in Goodnotes; shipped as the example plugin 'word-complete' (uses the user's AI). |
| T-045 | Shape tool (predefined shapes and diagrams) | parity | F031 |  |
| T-046 | AutoShape and Draw Shape | parity | F030 |  |
| T-047 | Shape fill color | parity+ | F031 | Fill-only (no border) shapes supported. |
| T-048 | Connectors (elbow and curved) | parity | F032 |  |
| T-049 | Quick Diagramming | parity | F032 |  |
| T-050 | Text inside shapes; shapes as containers | parity | F031 F012 |  |
| T-051 | Shape editing via control points | parity | F031 |  |
| T-052 | Tape tool (hide/reveal for active recall) | parity | F033 |  |
| T-053 | Tape colors and patterns (washi) | partial | F033 F008 | Marketplace patterns replaced by built-in generated patterns, custom images and gallery content packs. |
| T-054 | Laser Pointer | parity+ | F040 | Colour choice in addition to red. |
| T-055 | Text tool (movable text boxes) | parity | F026 |  |
| T-056 | Text formatting and Textbox Style | parity | F026 |  |
| T-057 | Auto lists in text | parity | F026 |  |
| T-058 | Full-page typing | parity | F028 |  |
| T-059 | Fonts, including custom fonts | parity | F026 |  |
| T-060 | Paste and Match Style | parity | F014 |  |
| T-061 | Text box auto-size and clipping | parity | F026 |  |
| T-062 | Links (internal and external) | parity | F029 |  |
| T-063 | PDF hyperlink navigation | parity+ | F029 F024 | Back ('Return to page') also available in edit mode. |
| T-064 | Images tool | parity | F034 |  |
| T-065 | Image crop (rectangle and freehand) | parity | F034 |  |
| T-066 | Image object actions | parity+ | F034 F013 | Adds flip/mirror and replace image. |
| T-067 | Camera capture | parity | F034 |  |
| T-068 | Elements tool (stickers and GIFs) | parity | F035 |  |
| T-069 | Custom elements and collections | parity | F035 |  |
| T-070 | GIPHY GIFs and animated stickers | partial | F035 | GIPHY search needs the user's own GIPHY API key (Settings); GIFs from Files/URL always work. |
| T-071 | Sticky Notes tool | parity | F036 |  |
| T-072 | Comments on page and objects | parity+ | F037 | Comments are items, so they are included in backups and exports. |
| T-073 | Zoom Window | parity | F038 |  |
| T-074 | Ruler tool | parity | F039 |  |
| T-075 | Apple Pencil Hover preview | parity | F043 |  |
| T-076 | Apple Pencil Pro squeeze Palette | parity+ | F043 | Palette contents follow the customised toolbar. |
| T-077 | Apple Pencil double-tap | parity | F043 |  |
| T-078 | Apple Scribble in text fields | parity | F026 F047 | Native UITextField/UITextView everywhere, including Text Documents. |
| T-079 | Finger drawing / Disconnect Apple Pencil | parity | F007 F101 F027 |  |
| T-080 | Palm rejection settings | parity | F027 F101 |  |
| T-081 | Undo / Redo buttons | parity | F015 |  |
| T-082 | Undo/Redo touch gestures | parity | F015 |  |
| T-083 | Copy / cut / paste content | parity | F014 |  |
| T-084 | Page long-press context menu | parity | F013 |  |
| T-085 | Tool keyboard shortcuts | parity | F016 F073 |  |
| T-086 | Toolbar structure and customization | parity+ | F016 | Saved layouts; plugin tools appear in the same customisation sheet. |
| T-087 | Read-Only Mode | parity | F042 |  |
| T-088 | Page zoom and pan gestures | parity | F006 |  |
| T-089 | Pen Tip Sharpness | parity | F007 |  |
| T-090 | Pressure Sensitivity slider | parity | F007 |  |
| T-091 | Highlighter 'Draw in Straight Line' setting | parity | F009 |  |
| T-092 | Highlighter renders beneath ink | parity | F009 F004 |  |
| T-093 | Eraser size presets | parity+ | F010 | Custom size slider in addition to 3 presets. |
| T-094 | Custom color picker (palette, color wheel, HEX) and 12-slot palettes | parity | F008 |  |
| T-095 | Tape settings: Straight Tape, Remove All Tape, pattern History | parity | F033 |  |
| T-096 | Save text style as default | parity+ | F026 | Multiple named text styles. |
| T-097 | Nested list indent/outdent and list styles | parity | F026 |  |
| T-098 | Full-page text style presets and constraints | parity | F028 |  |
| T-099 | Shape style editing: change shape type, corner style, stroke 'None' | parity | F031 |  |
| T-100 | Connector path editing (control points and bends) | parity | F032 |  |
| T-101 | Draw and Hold live adjustment | parity | F030 |  |
| T-102 | Hand-drawn arrow recognition | parity | F030 |  |
| T-103 | Ruler options (angle, position, units, digits) | parity | F039 |  |
| T-104 | Zoom Window controls (zoom box, margin, return height, New Line) | parity | F038 |  |
| T-105 | Snapping toggles (Align Objects / Snap to Grid) | parity | F012 |  |
| T-106 | Resize modifier keys | parity | F012 |  |
| T-107 | Sticky note author name and thread resolve | parity | F036 |  |
| T-108 | Math object share/copy (LaTeX, image, original handwriting) | parity | F060 |  |
| T-109 | Pull page down to close the secondary toolbar | parity | F016 |  |
| T-110 | Smart spacing guides | parity | F012 |  |
| T-111 | Keyboard nudge and object keys | parity | F012 F073 |  |
| T-112 | Parenthesis-style numbered lists | parity | F026 |  |
| T-113 | Smart Ink insert space between lines | parity | F058 |  |
| T-114 | Duplicate objects (menu, shortcut and drag-to-duplicate gestures) | parity | F014 F012 |  |
| T-115 | Shift-constrained axis movement | parity | F012 |  |
| T-116 | Object Selection setting (turn off finger-tap selection) | parity | F011 F027 |  |
| T-117 | Apple Pencil Pro haptic feedback | parity | F043 F012 F030 |  |
| T-118 | Tape orientation setting (horizontal vs follows pen rotation) | parity | F033 |  |
| T-119 | Audio Links (link text to an audio timestamp) | parity | F029 F052 |  |
| T-120 | Layers: active-layer scoping and per-viewer visibility | parity | F041 |  |

## Documents, pages & library (D-###)

| ID | Goodnotes feature | Status | Built by | Notes |
|---|---|---|---|---|
| D-001 | Library View navigation tabs | partial | F019 | Marketplace tab replaced by the plugin/content Gallery tab; Shared lists collaboration sessions. |
| D-002 | Grid / List library view | parity | F019 |  |
| D-003 | Library sorting | parity+ | F019 | Sort order remembered per folder. |
| D-004 | Library filter | parity | F019 |  |
| D-005 | New (+) creation menu | parity | F021 F019 F064 |  |
| D-006 | Create Notebook flow | parity | F021 F045 |  |
| D-007 | Auto-suggested notebook titles | parity | F087 F021 | AI suggestion when a provider is configured, otherwise the first recognised line. |
| D-008 | QuickNote | parity | F021 |  |
| D-009 | Folders and subfolders | parity+ | F002 F020 | No 3-folder limit. |
| D-010 | Folder color and icon/emoji | parity | F020 |  |
| D-011 | Library item action menu | parity | F019 |  |
| D-012 | Rename document or folder | parity | F002 F019 |  |
| D-013 | Duplicate document | parity | F002 F019 |  |
| D-014 | Move documents and folders | parity | F002 F019 |  |
| D-015 | Multi-select in library | parity | F019 |  |
| D-016 | Merge notebooks | parity | F002 |  |
| D-017 | Favorites (starred documents and folders) | parity | F020 F002 |  |
| D-018 | Home-screen widgets | partial | F096 F074 | QuickNote widget ships. A Favorites widget appears only when the sideloading tool provides an App Group (AltStore/SideStore can register one even for free Apple IDs; it depends on the tool); otherwise favourites are offered as dynamic Home Screen quick actions. |
| D-019 | Trash Bin (soft delete) | parity | F020 F002 |  |
| D-020 | Recover / move from Trash | parity | F020 F002 |  |
| D-021 | Empty Trash / Delete permanently | parity | F020 F002 |  |
| D-022 | Plan-based document limits | n/a | F098 | No plans: everything is unlimited and free. |
| D-023 | Document sync status indicators | parity | F070 F002 |  |
| D-024 | Password Protection setup | parity | F071 |  |
| D-025 | Lock / unlock a document | parity | F071 |  |
| D-026 | Whiteboard document (infinite canvas) | parity | F044 F006 |  |
| D-027 | Whiteboard boards management | parity | F044 |  |
| D-028 | Whiteboard minimap and zoom | parity | F044 |  |
| D-029 | Zoom-adaptive dot-grid background | parity | F005 F044 |  |
| D-030 | Board content limits | parity | F044 | Limit NibLimits.boardItemLimit (100k items) with warning at 80%. |
| D-031 | Whiteboard templates | partial | F044 | Built-in set of 8 frameworks plus gallery packs instead of 200+ Marketplace templates. |
| D-032 | Export whiteboard board | parity | F066 F067 |  |
| D-033 | Convert notebook to Whiteboard | parity | F044 |  |
| D-034 | Text Document (pageless typed document) | parity | F047 F048 |  |
| D-035 | Smart Textbooks | n/a | F098 F065 | Publisher DRM textbooks need Goodnotes' store. Substitutes: PDFs + outline + study sets; QR reader in Scan; audio speed in audio playback. |
| D-036 | Calendar-integrated Planner | substitute | F075 | EventKit (Google/Outlook accounts added in iOS Settings) instead of Google OAuth; planner template draws events. |
| D-037 | External AI document creation (ChatGPT app / Claude connector) | substitute | F090 | Superseded by the MCP/HTTP bridge: external agents can also read and edit existing documents. |
| D-038 | Notebook cover | parity | F005 F022 F021 |  |
| D-039 | Change cover | parity | F045 F005 |  |
| D-040 | Built-in paper templates | parity | F005 |  |
| D-041 | Dynamic template customization (size and color) | parity | F005 |  |
| D-042 | Paper colors | parity+ | F005 | Any paper colour, not only White/Yellow/Dark. |
| D-043 | Page sizes and dimensions | parity+ | F005 | Adds B5, Legal, Square and custom sizes. |
| D-044 | Change page template | parity+ | F045 F005 | Apply to selected pages or all pages. |
| D-045 | Default notebook template | parity | F045 F021 |  |
| D-046 | Import custom templates | parity | F045 |  |
| D-047 | Template groups | parity | F045 |  |
| D-048 | Delete custom templates / restore built-ins | parity | F045 |  |
| D-049 | Create template from an existing page | parity | F045 F066 |  |
| D-050 | Marketplace templates, covers and planners | substitute | F080 F045 | Marketplace replaced by gallery JSON indexes of free content packs (plugins contributing templates/covers/planners/elements/tape). |
| D-051 | AI-generated templates | parity | F087 |  |
| D-052 | Add Page menu | parity | F022 |  |
| D-053 | Other ways to add pages | parity | F022 F023 F006 |  |
| D-054 | Duplicate page | parity | F022 |  |
| D-055 | Copy and paste pages | parity | F022 F023 |  |
| D-056 | Move pages to another document | parity | F022 |  |
| D-057 | Drag pages between windows | parity | F023 |  |
| D-058 | Reorder pages | parity | F023 F022 |  |
| D-059 | Multi-page selection and batch actions | parity | F023 |  |
| D-060 | Rotate pages | parity+ | F022 | Rotate all pages command. |
| D-061 | Delete pages | parity | F022 F020 |  |
| D-062 | Clear page | parity | F010 |  |
| D-063 | Page-level undo/redo | parity | F022 F015 |  |
| D-064 | Go to / jump to page | parity | F022 F006 |  |
| D-065 | Document Sidebar (thumbnails panel) | parity | F023 F017 |  |
| D-066 | Page bookmarks | parity | F046 |  |
| D-067 | Custom outline (table of contents) | parity | F046 |  |
| D-068 | AI-generated outline | parity | F087 |  |
| D-069 | Imported PDF outlines | parity | F024 F046 |  |
| D-070 | Internal and external links | parity+ | F029 | Return-to-page history in every mode. |
| D-071 | Document tabs | parity | F018 |  |
| D-072 | Multiple windows / Split View with two documents | parity | F018 |  |
| D-073 | Drag content between windows | parity | F014 F023 |  |
| D-074 | Scrolling direction | parity | F006 F017 F027 |  |
| D-075 | Zoom and pan | parity | F006 |  |
| D-076 | Page layout: single page (no two-page spread) | parity | F006 |  |
| D-077 | Read Only Mode | parity | F042 |  |
| D-078 | Dark mode vs page backgrounds | parity | F094 F004 |  |
| D-079 | Document nav bar layout | parity | F017 |  |
| D-080 | Document More (…) menu | parity | F017 |  |
| D-081 | Document Editing settings | parity | F027 |  |
| D-082 | Document and library keyboard shortcuts | parity | F073 |  |
| D-083 | Presentation Mode (external display) | parity | F063 |  |
| D-084 | Mac-specific document behaviors | n/a | F098 | Nib is an iPhone/iPad app (no Mac Catalyst build). Pointer, right-click and keyboard behaviours are implemented on iPad (F073). |
| D-085 | PDF import and annotation | parity | F024 |  |
| D-086 | PDF hyperlinks | parity | F029 F024 |  |
| D-087 | PDF text context actions | parity | F042 |  |
| D-088 | PDF form fields (not supported) | parity | F024 | Same as Goodnotes: form fields are flattened; write/type over them. (Fillable forms are a candidate plugin.) |
| D-089 | Supported import formats | parity+ | F064 | Adds Anki/Quizlet text, .nibplugin, .nibcollection; Excel still unsupported. |
| D-090 | Import as new document | parity | F064 |  |
| D-091 | Import into an existing document | parity | F064 F022 |  |
| D-092 | Import from a computer | parity | F064 |  |
| D-093 | Cloud storage integration (Pro) | substitute | F064 F025 | No OAuth backends: Google Drive/OneDrive/Dropbox/Box are reached through their Files providers; import-in-place keeps a bookmark so 'Save changes to source' writes the annotated PDF back. |
| D-094 | Email to Goodnotes | n/a | F064 | Needs an inbound mail server. Substitute: share PDFs from Mail/Outlook with 'Open in Nib'. |
| D-095 | Web page import (Safari Reader PDF) | parity | F064 |  |
| D-096 | Scan Documents (with OCR) | parity | F065 |  |
| D-097 | Photos and images as pages or documents | parity | F034 F022 |  |
| D-098 | Import size limits | parity+ | F064 | No import size limit. |
| D-099 | Export scopes | parity | F067 F066 |  |
| D-100 | Export formats | parity+ | F066 | PNG and JPEG image export. |
| D-101 | Export options dialog | parity | F067 F066 |  |
| D-102 | Editable vs Flattened PDF | parity | F066 |  |
| D-103 | Export destinations and sharing to non-Apple devices | parity | F067 |  |
| D-104 | Printing | parity+ | F067 | Print selected pages directly. |
| D-105 | Manual library backup and restore | parity | F068 |  |
| D-106 | Auto Backup to cloud storage | substitute | F068 F069 | Targets any Files-provider folder (Google Drive, Dropbox, OneDrive, iCloud Drive) or WebDAV instead of OAuth APIs. |
| D-107 | Global library search | parity | F055 F056 |  |
| D-108 | In-document search | parity | F056 F055 |  |
| D-109 | Search indexing rules and OCR limits | parity+ | F055 | Optional OCR of image-only PDF pages and inserted images (setting search.ocrImages). |
| D-110 | Per-document recognition language | parity | F057 |  |
| D-111 | Share link (public collaboration link) | substitute | F072 | No web backend: sharing is a live session (join code over Multipeer or a self-hosted relay) or sending the .nibnote package; no browser viewer. |
| D-112 | Shared tab management | parity | F108 |  |
| D-113 | Text Document slash block menu and block handles | parity | F102 |  |
| D-114 | Text Document table editing | parity | F048 |  |
| D-115 | Auto-linking pasted URLs | parity | F029 F103 |  |
| D-116 | Whiteboard creation options and minimap controls | parity | F044 |  |
| D-117 | Document navigation as Sidebar or Window | parity | F023 F017 |  |
| D-118 | Page scrubber scrollbar | parity | F006 |  |
| D-119 | QuickNote exit prompt (Save / Combine / Delete) | parity | F021 |  |
| D-120 | Quick Record | parity | F052 |  |
| D-121 | Recently opened documents in Search | parity | F056 |  |
| D-122 | Swipe-to-select page thumbnails | parity | F023 |  |
| D-123 | Comment resolve/unresolve, Show Resolved, comment links, export with comments | parity | F037 |  |
| D-124 | Smart Textbook QR Reader and textbook audio speed | substitute | F065 F052 | General QR reader in Scan; playback speed in audio. |
| D-125 | Page number indicator | parity | F006 |  |
| D-126 | Drag a page thumbnail onto a page to insert it as an image | parity | F023 |  |
| D-127 | Open a specific page or tab in a new window | parity | F018 |  |
| D-128 | Outline 'Add Page to Outline' and Sort by Page Number | parity | F046 |  |
| D-129 | Text Document auto-outline from headings | parity | F103 |  |
| D-130 | Text Document inline formatting and Turn Into menu | parity | F102 |  |
| D-131 | Text Document inline comments on selections | parity | F103 |  |
| D-132 | Text Document title from first line | parity | F047 |  |
| D-133 | Text Document table column resize and drag reorder | parity | F048 |  |
| D-134 | Text Document image and media captions | parity | F047 |  |
| D-135 | CSV export in Share & Export menu | parity | F067 F048 F051 |  |
| D-136 | Sidebar Position (left or right) | parity+ | F017 | Per-panel positions (left, right or floating). |
| D-137 | 'Return To Page' after following links in Read-Only Mode | parity | F029 |  |
| D-138 | Double-tap + New to create a QuickNote | parity | F019 F021 |  |
| D-139 | DRM-protected publisher and partner content | n/a | F098 | No publisher partnerships; Nib never blocks export of the user's own files. |
| D-140 | Marketplace search and creator storefronts | substitute | F080 | Gallery search and author pages from index metadata. |

## Smart features, AI, audio, study & collaboration (S-###)

| ID | Goodnotes feature | Status | Built by | Notes |
|---|---|---|---|---|
| S-001 | Goodnotes AI assistant (entry points) | parity | F085 F084 |  |
| S-002 | AI panel display modes: Floating / Sidebar / Window | parity | F085 |  |
| S-003 | Create Mode toggle | parity | F085 F084 | Ask (read-only tools) vs Edit mode; no 'locked' plan state. |
| S-004 | Quick Actions | parity | F085 F087 |  |
| S-005 | AI Q&A over your notes with citations | parity+ | F084 F085 | Can also answer across the whole library (library scope). |
| S-006 | AI Summarize (text summary and visual summary to a new page) | parity | F087 |  |
| S-007 | AI Quiz generator | parity | F087 |  |
| S-008 | AI Translate | parity | F087 |  |
| S-009 | AI Generate Diagram (mind maps, flowcharts, timelines) | parity | F087 F032 |  |
| S-010 | AI Image Generation plus the Modify/Insert/Discard flow | partial | F085 F087 | Needs a provider with an image endpoint or Apple Image Playground. |
| S-011 | AI template, table and draft generation | parity | F087 |  |
| S-012 | AI in Text Documents (whole-document and per-block editing) | parity | F087 F047 |  |
| S-013 | AI Generate Outline (notebooks) | parity | F087 |  |
| S-014 | AI conversation management and feedback | parity | F085 F084 |  |
| S-015 | AI Credits system | n/a | F085 F098 | No credits: the user pays their own provider; the chat footer shows token usage. |
| S-016 | AI plan gating (Free / Special Edition / Essential / Pro / AI Pass) | n/a | F098 | No plans; every AI feature is available with any configured provider. |
| S-017 | AI regional availability | n/a | F098 | No geo-blocking; availability is up to the user's provider. |
| S-018 | AI privacy model | substitute | F086 F098 | Data goes only to the provider the user configured (or stays local with Ollama/LM Studio). |
| S-019 | AI language support | parity | F084 |  |
| S-020 | Goodnotes app in ChatGPT and connector in Claude | substitute | F090 | MCP bridge lets Claude Code / any MCP client read and edit the library. |
| S-021 | Ask Goodnotes in publisher AI Textbooks | n/a | F098 | No publisher DRM content. |
| S-022 | Math Assist (inline handwritten calculation) | parity | F106 F059 |  |
| S-023 | Math Assist variables, substitution and functions | parity | F061 |  |
| S-024 | Math Assist supported topics and limits | partial | F061 F088 | On-device evaluator covers arithmetic, algebraic equations, systems, matrices and numeric calculus; symbolic calculus/limits go to the user's AI. |
| S-025 | Math Assist answer formats and LaTeX correction | parity | F106 |  |
| S-026 | Matrix operations in Math Assist | parity | F061 |  |
| S-027 | Math graph generation (2D) | parity | F107 |  |
| S-028 | Goodnotes AI for Math: Solve | substitute | F088 | Uses the user's AI model instead of Wolfram\|Alpha; numeric answers are checked with the on-device evaluator. |
| S-029 | Goodnotes AI for Math: Teach Me | parity | F088 |  |
| S-030 | Math Conversion (handwriting to typeset math and LaTeX) | partial | F060 | See 'Convert handwritten math'. |
| S-031 | Interactive Exam Practice with AI Math Assistance (legacy) | substitute | F088 F099 | Retired in Goodnotes; substitute: Teach Me + Study Sets + answer zones. |
| S-032 | Handwriting Spellcheck | partial | F104 | See 'Handwriting spellcheck'. |
| S-033 | Personal Dictionary (custom words) | parity | F104 |  |
| S-034 | Word Complete (discontinued) | substitute | F082 F059 | Example plugin 'word-complete'. |
| S-035 | Smart Ink: Edit Handwriting and reflow | parity | F058 |  |
| S-036 | Smart Ink word-level selection and editing | parity | F058 |  |
| S-037 | Line Straightening (auto-straighten) | parity | F058 |  |
| S-038 | Handwriting Restyle (beautification) | partial | F105 | See 'Restyle handwriting (Smart Ink)'. |
| S-039 | Convert handwriting to text | parity | F057 |  |
| S-040 | Scribble to Erase gesture | parity | F007 F010 |  |
| S-041 | Circle to Lasso gesture | parity | F007 F011 |  |
| S-042 | Handwriting search and recognition languages | partial | F055 | Languages = Vision's supported recognition languages on the device. |
| S-043 | Shape recognition (Draw and Hold, AutoShape) | parity | F030 |  |
| S-044 | Notebook title suggestions | parity | F087 F021 |  |
| S-045 | Audio Recording ('Record & Summarize') | parity+ | F052 F089 | No 20-minute cap. |
| S-046 | Note Replay and Replay modes (stroke replay) | parity+ | F053 | Also in whiteboards. |
| S-047 | Audio playback controls and clip management | parity | F052 |  |
| S-048 | Background and cross-document recording | parity | F052 |  |
| S-049 | Live audio transcription (on-device vs cloud) | partial | F054 F089 | On-device = Apple Speech (languages per device); cloud = the user's Whisper-compatible endpoint. |
| S-050 | Transcript and Summary tabs with linked timestamps | parity | F054 F089 |  |
| S-051 | Transcript and summary search | parity | F054 F055 |  |
| S-052 | Live Summary (real-time meeting summarization) | parity | F089 |  |
| S-053 | Automated note-taking: Generate Notes and Enhance Notes | parity | F089 |  |
| S-054 | Regenerate transcription and summaries | parity | F054 F089 |  |
| S-055 | Recording Settings (cloud vs on-device toggles) | parity | F054 F089 |  |
| S-056 | Audio Noise Reduction | partial | F052 | Playback noise gate + high-pass (AVAudioEngine); not Apple's ML voice isolation. |
| S-057 | Audio export, sharing, backup and crash behaviour | parity+ | F052 F066 | Audio is written continuously (CAF), so a crash keeps what was recorded. |
| S-058 | Calendar Connection (Google, Outlook) for meetings | substitute | F075 | EventKit instead of OAuth. |
| S-059 | Goodnotes Planner with Google Calendar events | substitute | F075 | EventKit-backed planner template. |
| S-060 | Study Sets (flashcard document type) | parity | F049 |  |
| S-061 | Practice Mode | parity | F050 |  |
| S-062 | Smart Learn (spaced repetition) | parity | F050 |  |
| S-063 | Smart Learn review notifications | parity | F050 | Local notifications (no APNs). |
| S-064 | Study Set appearance and voice support | parity | F050 |  |
| S-065 | Study Set import and export (CSV/TSV/TXT, Quizlet, Anki) | parity | F051 |  |
| S-066 | Study Set keyboard shortcuts (edit mode) | parity | F049 |  |
| S-067 | Tape Tool (active-recall masking) | parity | F033 |  |
| S-068 | Time Keeper (study timer and stopwatch) | parity | F062 |  |
| S-069 | Smart Textbooks | n/a | F098 | See docs 'Smart Textbooks'. |
| S-070 | Education: teacher-approved AI hints | partial | F099 F088 | Local teacher toolkit; hints stored in answer zones. |
| S-071 | Presentation Mode (external display) | parity | F063 |  |
| S-072 | Laser Pointer (Dot / Trail) | parity | F040 |  |
| S-073 | Flipbook-style presentation | parity | F063 |  |
| S-074 | Public share link collaboration | substitute | F072 | Join codes over Multipeer/relay; no public web link or browser viewer. |
| S-075 | Private sharing with invited collaborators and access control | partial | F072 | Per-session join codes with host approval and read-only/edit roles; no account-based invites. |
| S-076 | Real-time collaboration and Live Cursor | parity | F072 F108 F092 |  |
| S-077 | Turbo Sync | n/a | F072 | No paid tiers; live sessions always stream changes immediately. |
| S-078 | Follow a collaborator | parity | F108 |  |
| S-079 | Unseen-change badges and Mark as Seen | parity | F108 |  |
| S-080 | Shared tab in the Library | parity | F108 |  |
| S-081 | Comments (object-anchored threads) | parity | F037 |  |
| S-082 | Google Drive integration (Pro) | substitute | F064 F025 | Files provider instead of OAuth. |
| S-083 | Goodnotes Marketplace (browse, buy, restore) | substitute | F080 | Free gallery of plugins/content packs from user-added JSON indexes; no purchases. |
| S-084 | Marketplace discovery: Saved Lists, recommendations, subscriber specials | partial | F080 | Gallery search, categories and saved items; no recommendations or subscriber specials. |
| S-085 | Marketplace offer codes (web checkout) | n/a | F098 | No store. |
| S-086 | Elements (stickers) and GIPHY GIFs | parity | F035 |  |
| S-087 | Marketplace tape patterns and whiteboard templates | substitute | F033 F044 F080 | Generated patterns, custom images, built-in whiteboard templates and gallery packs. |
| S-088 | Audio playback speed and Skip Silence | parity | F052 |  |
| S-089 | Tap handwriting to seek audio | parity | F053 |  |
| S-090 | Transcript interactions (drag to page, line actions, editing) | parity | F054 |  |
| S-091 | Transcription language picker and on-device model download | partial | F054 | Apple Speech manages on-device models; Nib shows availability and how to download. |
| S-092 | Mid-meeting language switch with translated summaries | parity | F089 |  |
| S-093 | Study Set card input modes and grading | parity | F049 F050 |  |
| S-094 | Education: School folder and Class Folders | substitute | F109 | A shared synced folder acts as the class folder; no roster server. |
| S-095 | Education: Lessons with Prep Mode and Teach Mode | partial | F109 | Prep/Present/Feedback via layers and per-student copies in a shared folder. |
| S-096 | Education: Answer Zones with score widgets | parity | F099 |  |
| S-097 | Education: Assignments (publish, submit, return, resubmit) | partial | F109 | State flags on per-student copies in a shared folder; no Google Classroom link. |
| S-098 | Education: Smart Clusters AI grading | partial | F110 | Uses the teacher's own AI model. |
| S-099 | Education: Quick Lesson | parity | F109 F072 |  |
| S-100 | Shared-document feature gating by oldest app version | parity | F072 |  |
| S-101 | Real-time participant cap with sync fallback | partial | F072 F092 | Multipeer caps at 8 peers per session; the relay transport raises it to 50; beyond that, folder sync. |
| S-102 | Collaboration activity notifications | partial | F108 | Local notifications only while background audio recording keeps the app alive (iOS suspends live sessions ~30 s after backgrounding; no APNs); otherwise unseen-change badges on return, and peers auto-rejoin with the same code. |
| S-103 | Transcript follow-along highlighting during playback | parity | F054 |  |
| S-104 | Live Summary timeline and quality flags | parity | F089 |  |
| S-105 | Timestamp jumps to most-edited page | parity | F054 |  |
| S-106 | Time Keeper preset modes and stopwatch laps | parity | F062 |  |
| S-107 | Study session keyboard shortcuts | parity | F050 |  |
| S-108 | Legacy Flashcards to Study Set conversion | substitute | F051 | No legacy decks exist; Anki/Quizlet/CSV import covers migration. |
| S-109 | Education: Teaching Mode Class Navigator (Present / Feedback) | parity | F110 |  |
| S-110 | Education: Smart Views (By Page / By Question) | parity | F110 |  |
| S-111 | Education: Compare to Model Answer and manual clusters | parity | F110 |  |
| S-112 | Education: Co-teaching in Class Folders | substitute | F109 | Co-teachers share the class folder; no role server. |
| S-113 | Education: Follow Me (teacher-led viewport) | parity | F109 F108 |  |
| S-114 | Education: Class Folder archive, filters and sorting | substitute | F109 | Archive = move the class folder into an Archive folder; library filters/sorting apply. |
| S-115 | Education: roster sync and Sample Lesson onboarding | partial | F109 | Sample lesson ships; ClassLink/Eduplaces roster sync is not applicable (no backend); rosters import from CSV. |
| S-116 | Export an individual audio clip as an audio file | parity | F052 |  |
| S-117 | Study Set card management and Scratchpaper | parity | F049 F050 |  |

## Platform, sync, settings & system (P-###)

| ID | Goodnotes feature | Status | Built by | Notes |
|---|---|---|---|---|
| P-001 | iCloud Sync (Use iCloud to Sync Documents) | substitute | F025 F001 | CloudKit needs a paid entitlement. The library is a user-chosen folder (e.g. iCloud Drive via Files); per-device files merge conflict-free. |
| P-002 | Cloud & Backup Status indicator | parity | F070 |  |
| P-003 | Per-document sync state badges | parity | F070 F002 |  |
| P-004 | Sync schema version gate and iCloud reset | partial | F001 F070 | Format-version gate opens newer documents read-only; 'reset' = library repair. |
| P-005 | iCloud storage model (not browsable in iCloud Drive) | substitute | F001 F025 | Nib's library is intentionally browsable in Files. |
| P-006 | Goodnotes Cloud (cross-platform account sync) | substitute | F025 F069 | Any Files-provider folder or WebDAV; no Nib account or server. |
| P-007 | Auto Backup to third-party cloud | substitute | F068 F069 | Files-provider folders and WebDAV. |
| P-008 | Auto Backup destination folder rules | parity | F068 |  |
| P-009 | Auto Backup change triggers | parity | F068 |  |
| P-010 | Auto Backup frequency and Back Up Now | parity | F068 |  |
| P-011 | Auto Backup Excluded File Names | parity | F068 |  |
| P-012 | Auto Backup multi-device queue and restart | parity | F068 |  |
| P-013 | Manual Backup and restore (.zip) | parity | F068 F064 |  |
| P-014 | Library restore after reinstall | parity+ | F002 F068 F093 F025 | Onboarding puts the library in a folder the user picks outside the app container (On My iPad root, iCloud Drive…), so reinstalling — even with another signer — just re-opens it. Keeping it inside the app is a warned opt-out (a reinstall with a different signer deletes the container; F070 shows a banner). |
| P-015 | Goodnotes account sign-in methods | n/a | F098 | No accounts. |
| P-016 | App Store receipt to account binding | n/a | F098 | Sideloaded, free. |
| P-017 | Account screen (View Account / Account Settings) | substitute | F098 | Local profile (author name) + About. |
| P-018 | Account deletion with a 21-day grace period | substitute | F098 | 'Delete all Nib data' wipes local app data and keys. |
| P-019 | Account session limits | n/a | F098 | No accounts. |
| P-020 | Multiple accounts on one device | substitute | F025 F098 | Switch between known library folders (library.locations / library.switch). |
| P-021 | Plans, paywall and entitlement gating | n/a | F098 | Everything free. |
| P-022 | Apple Family Sharing | n/a | F098 | No purchases. |
| P-023 | Legacy GoodNotes 5 mode switch | n/a | F098 | No legacy app. |
| P-024 | Goodnotes menu (top-level app menu) | parity | F019 F027 |  |
| P-025 | Settings screen sections | parity | F027 |  |
| P-026 | Stylus mode (Smart Stylus / Disconnect Stylus) | parity | F027 F101 |  |
| P-027 | Palm rejection: writing posture and sensitivity | parity | F027 F101 |  |
| P-028 | Scrolling direction (page swiping) | parity | F006 F027 |  |
| P-029 | Document Editing: Auto Advance (Zoom Window) | parity | F038 F027 |  |
| P-030 | Document Editing: Undo and Redo Position | parity | F015 F027 |  |
| P-031 | Toolbar Customization | parity | F016 |  |
| P-032 | Dockable floating tool menu and toolbar hiding | parity | F016 |  |
| P-033 | Document Privacy: Password Protection setup | parity | F071 |  |
| P-034 | Locked-document behaviors | parity | F071 |  |
| P-035 | Document language (handwriting recognition language) | parity | F057 F027 |  |
| P-036 | Handwriting Recognition settings (search indexing) | parity | F055 |  |
| P-037 | Contribute Handwriting / Contribute Math Equations | n/a | F098 | No model training service. |
| P-038 | Writing Aids settings | parity | F105 |  |
| P-039 | Pen gesture toggles (Circle to Lasso, Scribble to Erase) | parity | F007 |  |
| P-040 | Draw and Hold shape snapping toggle | parity | F030 F007 |  |
| P-041 | Multi-finger undo and redo tap gestures | parity+ | F015 | Can be disabled. |
| P-042 | Zoom and pan input handling | parity | F006 |  |
| P-043 | Apple Pencil double-tap integration | parity | F043 |  |
| P-044 | Apple Pencil Hover previews | parity | F043 |  |
| P-045 | Apple Pencil Pro squeeze Palette | parity | F043 |  |
| P-046 | Apple Pencil Pro barrel roll (Dynamic Ink) | parity | F007 F043 |  |
| P-047 | Stylus hardware support matrix | parity | F007 F043 |  |
| P-048 | Low-latency inking (predicted touches) | parity | F007 F101 |  |
| P-049 | Apple Scribble in text fields | parity | F026 |  |
| P-050 | Mouse, trackpad and pointer support | parity | F073 F013 |  |
| P-051 | Keyboard shortcuts: File | parity | F073 |  |
| P-052 | Keyboard shortcuts: Edit and Find | parity | F073 F056 |  |
| P-053 | Keyboard shortcuts: View and navigation | parity | F073 |  |
| P-054 | Keyboard shortcuts: single-key tool switching | parity+ | F016 F073 | Can be disabled. |
| P-055 | Keyboard shortcuts: text formatting | parity | F026 F073 |  |
| P-056 | Keyboard shortcuts: Text Documents and tables | parity | F102 F048 |  |
| P-057 | Shortcut discoverability and hardware keyboard | parity | F073 |  |
| P-058 | Multiple windows (iPadOS multi-scene) | parity | F018 |  |
| P-059 | Document tabs | parity | F018 |  |
| P-060 | Split View, Slide Over and Stage Manager | parity | F018 |  |
| P-061 | Drag and drop between Goodnotes windows | parity | F014 F023 |  |
| P-062 | Drag and drop import from other apps | parity | F064 |  |
| P-063 | Drag out to other apps | parity | F014 |  |
| P-064 | External display Presentation Mode | parity | F063 |  |
| P-065 | Laser Pointer | parity | F040 |  |
| P-066 | Read Only Mode | parity | F042 |  |
| P-067 | Dark mode | parity | F094 |  |
| P-068 | iOS 26 Liquid Glass UI | parity | F094 | Built with the iOS 26 SDK (Xcode 26.6 on CI): real Liquid Glass from the reserved `NibDesign` module (ARCHITECTURE §3) behind `#available(iOS 26, *)`; iOS 17–18 fall back to system materials (.ultraThinMaterial). |
| P-069 | Home Screen and desktop widgets | partial | F096 F074 | See 'Home-screen widgets'. |
| P-070 | Home Screen quick action: QuickNote | parity | F074 |  |
| P-071 | Siri and Shortcuts actions | parity+ | F074 | App Intents for QuickNote, open/create folder, open document, search, append text. |
| P-072 | Deep links / URL handling | parity+ | F074 | Documented nib:// scheme for documents, pages, audio times, search, plugin install, bridge pairing. |
| P-073 | Share Sheet / 'Open in Goodnotes' import | partial | F064 F074 | 'Open in Nib' for files works (document types). Images, text and URLs shared from other apps need the optional NibShare extension: it writes into an App Group inbox when the sideloading tool provides one, otherwise hands small payloads over the pasteboard (nib://import?from=pasteboard); large files go through 'Save to Files → Nib Inbox'. |
| P-074 | Files app / document picker import and supported types | parity | F064 F025 |  |
| P-075 | Direct cloud storage integration (Integrations > Cloud Storage) | substitute | F025 F064 | Files providers + import-in-place with save-back. |
| P-076 | Computer file transfer (Finder/iTunes File Sharing, AirDrop) | parity | F064 |  |
| P-077 | Email to Goodnotes | n/a | F064 | See docs 'Email to Goodnotes'. |
| P-078 | Safari web page import (Reader PDF) | parity | F064 |  |
| P-079 | Export to Files and print | parity | F067 |  |
| P-080 | Calendar integrations (Google Calendar, Outlook) | substitute | F075 | EventKit. |
| P-081 | External AI integration (ChatGPT app / Claude connector) | substitute | F090 | MCP bridge (create, read and edit). |
| P-082 | Apple Intelligence Image Playground insertion | partial | F034 | Only on Apple Intelligence devices (iOS 18.1+). |
| P-083 | System fonts for text | parity+ | F026 | Installed fonts also usable in full-page text. |
| P-084 | Background audio recording | parity | F052 |  |
| P-085 | Supported platforms and minimum OS | partial | F098 | iPhone and iPad, iOS/iPadOS 17+. No Mac, visionOS, Android, Windows or web clients. |
| P-086 | Mac-specific behavior | n/a | F098 | No Mac build. |
| P-087 | UI localization | partial | F095 | String catalog + 15 languages generated by AI translation; right-to-left not supported (same as Goodnotes). |
| P-088 | Accessibility | parity+ | F095 | VoiceOver page-contents panel reading recognised handwriting. |
| P-089 | Onboarding flow | parity | F093 |  |
| P-090 | Push notifications and in-app messages | substitute | F050 F075 F072 | Local notifications only (APNs needs a paid account); no marketing messages. |
| P-091 | Large-PDF and large-library performance handling | parity | F100 F004 F024 |  |
| P-092 | Export Diagnostic Data | parity | F076 |  |
| P-093 | Temporary Diagnostic Mode (iOS Settings bundle) | parity | F076 |  |
| P-094 | Library repair and self-service sync fix | parity | F070 |  |
| P-095 | Battery and background-work profile | parity | F100 F055 F068 |  |
| P-096 | Privacy model and data practices | parity+ | F098 | No telemetry at all. |
| P-097 | Right to erasure requests | substitute | F098 | In-app 'Delete all Nib data'. |
| P-098 | Managed App Configuration (MDM AppConfig) | n/a | F097 | Managed App Configuration reaches only MDM-installed apps; a sideloaded build never receives it. A minimal read-only reader (F097) is kept for MDM-distributed builds. |
| P-099 | Enterprise identity and compliance (Intune, Managed Apple IDs) | n/a | F097 F098 | Intune APP SDK and Managed Apple ID sign-in need Microsoft SDK/entitlements and accounts. |
| P-100 | Report an Issue and feedback channels | parity | F076 |  |
| P-101 | TestFlight beta and remote feature flags | substitute | F076 | Local 'Experimental' toggles; CI artifacts replace TestFlight. |
| P-102 | Regional availability and store variants | n/a | F098 | Not distributed through the App Store. |
| P-103 | Offline, local-first library on Apple | parity | F001 F002 |  |
| P-104 | Teams/Enterprise and Education deployment (Admin Console, SSO) | n/a | F098 | No admin console, SSO or licensing server. |
| P-105 | Session restore of last document | parity | F018 |  |
| P-106 | Hide iOS status bar setting | parity | F017 F027 |  |
| P-107 | Box and Dropbox direct cloud-storage integration | substitute | F064 F025 | Files providers + import-in-place save-back. |
| P-108 | iCloud to Goodnotes Cloud migration and switch-back | substitute | F025 | 'Move Library' copies the library to another folder (e.g. from On My iPad to iCloud Drive) and switches to it; switching back is the same command. |
| P-109 | Free-plan caps: watermark, audio and AI usage | n/a | F098 | No caps, no watermark. |
| P-110 | MDM Auto Backup reminder and WebDAV certificate policy | n/a | F097 | Requires MDM-distributed builds; the WebDAV untrusted-certificate option is an ordinary setting. |
| P-111 | Business Admin Console extras | n/a | F098 | No admin console. |
| P-112 | 'Open Document on Web' share toggle | n/a | F072 | No web viewer; share a PDF export instead. |
| P-113 | Dark and tinted app icon variants | parity | F094 |  |
| P-114 | Send content to Image Playground (outbound) | partial | F034 | Apple Intelligence devices only. |
| P-115 | Siri and Shortcuts App Intents for folders | parity | F074 |  |
| P-116 | System stickers inline in typed text | parity | F026 |  |

## Nib-only features (N-###)

| ID | Feature | Built by |
|---|---|---|
| N-001 | Universal command registry: every UI action, plugin call, AI tool call and bridge call is a registered command (undo, validation, permissions); the few user-only exceptions are listed below | F003 F015 |
| N-002 | Read/query API: whole library and document tree as JSON (query.context/get/find/tree, render, recognize) | F003 F055 |
| N-003 | Raw node API: insert/set/remove/move any record, including plugin `ext` data | F003 |
| N-004 | JavaScript plugin runtime (JavaScriptCore sandbox, one VM per plugin, timers, storage, logs) | F077 |
| N-005 | Plugin manifest & contribution points: commands, toolbar, menus, canvas tools and option bars, tap handlers and canvas decorations, panels, templates and covers, key bindings, settings, AI actions, importers/exporters, custom item types (inspector, searchable text), text-document blocks, stroke processors, Pencil actions, command hooks, content packs (stickers, tape patterns, whiteboard templates) | F078 |
| N-006 | HTML plugin panels (WKWebView) bridged to the same API | F081 |
| N-007 | Plugin install from Files, URL, gallery index; updates with permission diff | F079 F080 |
| N-008 | Permissions, consent sheet, device-local grants bound to the plugin hash | F079 F078 |
| N-009 | Plugin SDK types (nib.d.ts) generated from the live registry | F078 |
| N-010 | Plugin developer console and 'new plugin' template | F080 |
| N-011 | Example plugins: hello, flashcards-from-selection, word-count panel, word-complete, planner template, graph paper | F082 |
| N-012 | Bring-your-own AI providers: Anthropic, OpenAI and OpenAI-compatible (OpenRouter, Ollama, LM Studio, vLLM), custom Nib HTTP endpoint | F083 F086 |
| N-013 | AI agent that reads, adds, edits and deletes anything through the command registry (within the exceptions below, where it asks and the user confirms) | F084 |
| N-014 | Generated AI tool catalogue: fixed meta-tools + configurable direct tools | F084 |
| N-015 | AI vision & OCR context: page renders with Set-of-Mark ids, recognised page text | F084 F055 |
| N-016 | AI safety: confirmations, one undo step per AI turn, selective revert after later edits, provenance on every item | F084 F085 F015 |
| N-017 | AI-authored plugins (write, dry-run, install with consent) | F084 F079 |
| N-018 | User-defined AI quick actions (prompts) alongside built-in and plugin actions | F087 F078 |
| N-019 | In-app MCP/HTTP bridge so external agents (Claude Code over LAN/Tailscale) drive the app with the same tools | F090 |
| N-020 | Bridge pairing: token, QR code, ready-to-paste `claude mcp add` command, status pill | F091 |
| N-021 | Event stream (plugins) and long-poll (bridge) of every change | F090 F077 |
| N-022 | History panel of undo groups with who made them (user / AI / plugin / bridge) | F015 |
| N-023 | Conflict-free folder sync: each device writes only its own files in any Files-provider folder | F001 F025 |
| N-024 | WebDAV sync | F069 |
| N-025 | Self-hosted relay transport for internet collaboration | F092 |
| N-026 | Safe mode & crash-loop protection | F076 |
| N-027 | MDM managed-config support without Intune | F097 |
| N-028 | In-app parity & substitution notes | F098 |

## Exceptions to the modify-anything guarantee

Plugins, the in-app AI and bridge agents can do what the user can do by hand through the command registry — except the classes below. F098 renders this table on the in-app parity page.

| Class | Commands / data | Why | What the AI, a plugin or the bridge can do instead |
|---|---|---|---|
| `security` scope (user only) | Passwords (`lock.setup`), AI API keys, WebDAV and relay secrets, bridge enable/token/port/networks (`bridge.setEnabled`), confirmation policies and every `security.*` setting (read and write), plugin grants | A caller must never widen its own permissions or read secrets | Ask the user; open the settings page (`panel.open`, deep link) |
| User presence | Commands that show system UI: camera and scan, document/folder pickers (`import.pick`, `library.chooseFolder`, `backup.chooseFolder`, `template.choose`), Face ID/password (`doc.unlock`, `doc.setLocked`), print and share sheets, microphone (`audio.record`) | iOS requires a person at the system UI | Call them: the UI appears on the device and the user completes it (bridge requests wait up to 120 s) |
| Locked documents | Every command that touches a locked document; search, backup, WebDAV and collaboration skip them | The password lock is an access gate | Ask the user to unlock (`doc.unlock`) |
| Plugin management | `plugin.install`, `plugin.uninstall`, `plugin.enable` (`plugins:manage`) | Plugins must not install or enable plugins | AI and bridge: call them, always confirmed. Plugins: not possible |
| Plugin opt-outs | Plugin commands with `ai: false` / `bridge: false` | The plugin author hid them | The user can expose them anyway (`security.plugins.exposeHiddenCommands`) |
| Ask mode | Every non-`read` command while "Create mode" is off, including nested calls and plugin handlers | The user asked for a read-only conversation | Propose the change; the user switches to Edit mode |
| Always confirmed | `irreversible` (empty trash, purge, delete audio, overwrite a source file), `sensitive` (WebDAV/backup destinations, collaboration, relay, microphone, calendar, Photos, AI provider endpoints) and `plugins:manage` commands | Cannot be undone, or data leaves the device | Call them; the user answers Allow / Allow for this turn / Deny |
| Protected fields | `createdBy`, `rev`, `deleted`, `id` (on update), `meta.format`, `meta.locked`, `meta.trashedFrom`; read-only `managed.*` settings | Provenance, sync and format integrity | Use the dedicated commands (`node.remove`, `library.trash`, `doc.setLocked`) |

## Build features → inventory

| Feature | Name | Module | Priority | Inventory items |
|---|---|---|---|---|
| F001 | Document package store (persistence + assets) | NibStore | 1 | P-001, P-004, P-005, P-103, N-023 |
| F002 | Library store (folders, documents, trash, prefs) | NibLibrary | 1 | D-009, D-012, D-013, D-014, D-016, D-017, D-019, D-020, D-021, D-023, P-003, P-014, P-103 |
| F003 | Query, node & asset API | FeatQuery | 1 | N-001, N-002, N-003 |
| F004 | Page renderer (tiles, ink compositing, thumbnails) | NibRender | 1 | T-009, T-016, D-078, P-091, T-092 |
| F005 | Templates: paper, covers, sizes, colours | NibTemplates | 1 | D-029, D-038, D-039, D-040, D-041, D-042, D-043, D-044 |
| F006 | Canvas: scroll, zoom, page layout, tiles & whiteboard world | FeatCanvas | 1 | T-088, D-026, D-053, D-064, D-074, D-075, D-076, P-028, P-042, D-118, D-125 |
| F101 | Canvas input: wet ink, touch pipeline, palm rejection & gesture routing | FeatCanvas | 1 | T-008, T-034, T-079, T-080, P-026, P-027, P-048 |
| F007 | Pen & pencil tools, ink command, pen gestures | FeatPen | 1 | T-001, T-002, T-003, T-004, T-005, T-006, T-007, T-008, T-009, T-013, T-015, T-023, T-024, T-079, S-040, S-041, P-039, P-040, P-046, P-047, P-048, T-089, T-090 |
| F008 | Tool presets, colour picker & eyedropper | FeatPresets | 1 | T-009, T-010, T-011, T-012, T-053, T-094 |
| F009 | Highlighter tool | FeatHighlighter | 1 | T-007, T-016, T-091, T-092 |
| F010 | Eraser, clear page, delete specific items | FeatEraser | 1 | T-018, T-019, T-020, T-021, T-022, T-023, D-062, S-040, T-093 |
| F011 | Lasso & selection | FeatLasso | 1 | T-024, T-025, T-026, T-034, S-041, T-116 |
| F012 | Selection transforms, guides & snapping | FeatTransform | 1 | T-027, T-028, T-029, T-050, T-105, T-106, T-110, T-111, T-114, T-115, T-117 |
| F013 | Object menu & page long-press menu | FeatObjectMenu | 1 | T-030, T-031, T-032, T-033, T-036, T-066, T-084, P-050 |
| F014 | Clipboard, duplicate & drag-and-drop | FeatClipboard | 1 | T-041, T-060, T-083, D-073, P-061, P-063, T-114 |
| F015 | Undo/redo UI, gestures & history panel | FeatUndoUI | 1 | T-081, T-082, D-063, P-030, P-041, N-001, N-016, N-022 |
| F016 | Toolbar & tool switching | FeatToolbar | 1 | T-001, T-035, T-085, T-086, P-031, P-032, P-054, T-109 |
| F017 | Document chrome: nav bar, sidebar & panel hosts | FeatDocChrome | 1 | D-065, D-074, D-079, D-080, D-117, P-106, D-136 |
| F018 | Tabs, windows & session restore | FeatWindows | 1 | D-071, D-072, P-058, P-059, P-060, P-105, D-127 |
| F019 | Library browser | FeatLibraryUI | 1 | D-001, D-002, D-003, D-004, D-005, D-011, D-012, D-013, D-014, D-015, P-024, D-138 |
| F020 | Folders, favourites & trash UI | FeatLibraryOrganize | 1 | D-009, D-010, D-017, D-019, D-020, D-021, D-061 |
| F021 | Document creation & QuickNote | FeatCreate | 1 | D-005, D-006, D-007, D-008, D-038, D-045, S-044, D-119, D-138 |
| F022 | Page management | FeatPages | 1 | D-038, D-052, D-053, D-054, D-055, D-056, D-058, D-060, D-061, D-063, D-064, D-091, D-097 |
| F023 | Page sidebar (thumbnails) | FeatSidebar | 1 | D-053, D-055, D-057, D-058, D-059, D-065, D-073, P-061, D-117, D-122, D-126 |
| F024 | PDF engine | NibPDF | 1 | T-063, D-069, D-085, D-086, D-088, P-091 |
| F025 | Folder sync engine & library location | NibSync | 1 | D-093, S-082, P-001, P-005, P-006, P-020, P-074, P-075, P-107, P-108, N-023, P-014 |
| F026 | Text boxes & rich text | FeatTextBox | 1 | T-035, T-055, T-056, T-057, T-059, T-061, T-078, P-049, P-055, P-083, T-096, T-097, T-112, P-116 |
| F027 | Settings screens | FeatSettings | 1 | T-079, T-080, D-074, D-081, P-024, P-025, P-026, P-027, P-028, P-029, P-030, P-035, P-106, T-116 |
| F028 | Full-page typing | FeatPageText | 2 | T-058, T-098 |
| F029 | Links | FeatLinks | 2 | T-062, T-063, D-070, D-086, D-115, T-119, D-137 |
| F030 | Shape recognition & Draw Shape tool | FeatShapeRecognition | 2 | T-013, T-014, T-046, S-043, P-040, T-101, T-102, T-117 |
| F031 | Shapes | FeatShapes | 2 | T-045, T-047, T-050, T-051, T-099 |
| F032 | Connectors & diagrams | FeatDiagrams | 2 | T-048, T-049, S-009, T-100 |
| F033 | Tape | FeatTape | 2 | T-052, T-053, S-067, S-087, T-095, T-118 |
| F034 | Images, camera, GIFs & Image Playground | FeatImages | 2 | T-064, T-065, T-066, T-067, D-097, P-082, P-114 |
| F035 | Elements (stickers) & GIF search | FeatElements | 2 | T-068, T-069, T-070, S-086 |
| F036 | Sticky notes | FeatSticky | 2 | T-071, T-107 |
| F037 | Comments | FeatComments | 2 | T-072, S-081, D-123 |
| F038 | Zoom Window | FeatZoomWindow | 2 | T-073, P-029, T-104 |
| F039 | Ruler | FeatRuler | 2 | T-074, T-103 |
| F040 | Laser pointer | FeatLaser | 2 | T-054, S-072, P-065 |
| F041 | Layers | FeatLayers | 2 | T-037, T-120 |
| F042 | Read-only mode & PDF text actions | FeatReadOnly | 2 | T-017, T-087, D-077, D-087, P-066 |
| F043 | Apple Pencil hardware (hover, double-tap, squeeze, haptics) | FeatPencilHardware | 2 | T-006, T-075, T-076, T-077, P-043, P-044, P-045, P-046, P-047, T-117 |
| F044 | Whiteboards | FeatWhiteboard | 2 | D-026, D-027, D-028, D-029, D-030, D-031, D-033, S-087, D-116 |
| F045 | Template management & pickers | FeatTemplateUI | 2 | D-006, D-039, D-044, D-045, D-046, D-047, D-048, D-049, D-050 |
| F046 | Outline & bookmarks | FeatOutline | 2 | D-066, D-067, D-069, D-128 |
| F047 | Text documents: block model, commands & core editor | FeatTextDoc | 2 | T-078, D-034, S-012, D-132, D-134 |
| F102 | Text documents: slash menu, Turn Into, drag handles & inline formatting | FeatTextDoc | 2 | P-056, D-113, D-130 |
| F103 | Text documents: comments, outline & export | FeatTextDoc | 2 | D-115, D-129, D-131 |
| F048 | Text document tables | FeatTextDocTables | 2 | D-034, P-056, D-114, D-133, D-135 |
| F049 | Study sets: editor | FeatStudyEditor | 2 | S-060, S-066, S-093, S-117 |
| F050 | Study sessions: Practice, Smart Learn, reminders | FeatStudySession | 2 | S-061, S-062, S-063, S-064, P-090, S-093, S-107, S-117 |
| F051 | Study set import & export | FeatStudyIO | 2 | S-065, S-108, D-135 |
| F052 | Audio recording & playback | FeatAudio | 2 | S-045, S-047, S-048, S-056, S-057, P-084, D-120, D-124, S-088, T-119, S-116 |
| F053 | Note replay | FeatReplay | 2 | S-046, S-089 |
| F054 | Transcription & transcript panel | FeatTranscription | 2 | S-049, S-050, S-051, S-054, S-055, S-090, S-091, S-103, S-105 |
| F055 | Search index & handwriting recognition | NibIndex | 2 | D-107, D-108, D-109, S-042, S-051, P-036, P-095, N-002, N-015 |
| F056 | Search UI | FeatSearchUI | 2 | D-107, D-108, P-052, D-121 |
| F057 | Convert handwriting to text & recognition language | FeatConvertText | 2 | T-040, D-110, S-039, P-035 |
| F058 | Smart Ink: edit handwriting | FeatSmartInk | 2 | T-038, S-035, S-036, S-037, T-113 |
| F059 | Ink synthesis & typesetter | FeatInkSynth | 2 | T-044, S-022, S-034 |
| F104 | Handwriting spellcheck & personal dictionary | FeatInkSynth | 2 | T-043, S-032, S-033 |
| F105 | Handwriting restyle & Writing Aids settings | FeatInkSynth | 2 | T-039, S-038, P-038 |
| F060 | Math items, conversion & typesetting | FeatMath | 2 | T-042, S-030, T-108 |
| F061 | Math engine (on-device evaluator) | FeatMathAssist | 2 | S-023, S-024, S-026 |
| F106 | Math Assist overlay | FeatMathAssist | 2 | S-022, S-025 |
| F107 | Math graphs | FeatMathAssist | 2 | S-027 |
| F062 | Time Keeper | FeatTimeKeeper | 2 | S-068, S-106 |
| F063 | Presentation mode | FeatPresentation | 2 | D-083, S-071, S-073, P-064 |
| F064 | Import | FeatImport | 2 | D-005, D-089, D-090, D-091, D-092, D-093, D-094, D-095, D-098, S-082, P-013, P-062, P-073, P-074, P-075, P-076, P-077, P-078, P-107 |
| F065 | Scan documents & QR | FeatScan | 2 | D-035, D-096, D-124 |
| F066 | Export engine (PDF, images, packages) | NibExport | 2 | D-032, D-049, D-099, D-100, D-101, D-102, S-057 |
| F067 | Export UI, share, print & save-back | FeatExportUI | 2 | D-032, D-099, D-101, D-103, D-104, P-079, D-135 |
| F068 | Backup (manual & automatic) | FeatBackup | 2 | D-105, D-106, P-007, P-008, P-009, P-010, P-011, P-012, P-013, P-014, P-095 |
| F069 | WebDAV sync | FeatWebDAV | 2 | D-106, P-006, P-007, N-024 |
| F070 | Sync status & repair UI | FeatSyncUI | 2 | D-023, P-002, P-003, P-004, P-094 |
| F071 | Password lock | FeatLock | 2 | D-024, D-025, P-033, P-034 |
| F072 | Collaboration: transport, session, sync & approval | FeatCollab | 2 | D-111, S-074, S-075, S-076, S-077, P-090, S-099, S-100, S-101, P-112 |
| F108 | Collaboration: presence, follow, unseen changes & Shared tab | FeatCollab | 2 | D-112, S-076, S-078, S-079, S-080, S-102, S-113 |
| F073 | Keyboard shortcuts & pointer | FeatKeyboard | 2 | T-085, D-082, P-050, P-051, P-052, P-053, P-054, P-055, P-057, T-111 |
| F074 | System integration: App Intents, quick actions, deep links | FeatSystemIntegration | 2 | D-018, P-069, P-070, P-071, P-072, P-115, P-073 |
| F075 | Calendar (EventKit) & event notes | FeatCalendar | 2 | D-036, S-058, S-059, P-080, P-090 |
| F076 | Diagnostics, troubleshooting & safe mode | FeatDiagnostics | 2 | P-092, P-093, P-100, P-101, N-026 |
| F077 | Plugin runtime (JavaScriptCore) | NibPluginRuntime | 3 | N-004, N-021 |
| F078 | Plugin host & contribution mapping | NibPluginHost | 3 | N-005, N-008, N-009, N-018 |
| F079 | Plugin install & trust | FeatPluginInstall | 3 | N-007, N-008, N-017 |
| F080 | Plugin manager, gallery & developer console | FeatPluginManager | 3 | D-050, S-083, S-084, S-087, D-140, N-007, N-010 |
| F081 | Plugin HTML panels | FeatPluginPanels | 3 | N-006 |
| F082 | Example plugins & plugin test fixtures | ExamplePlugins | 3 | T-044, S-034, N-011 |
| F083 | AI providers (bring your own model) | NibAIProviders | 3 | N-012 |
| F084 | AI agent, tool catalogue & AIService | NibAIAgent | 3 | S-001, S-003, S-005, S-014, S-019, N-013, N-014, N-015, N-016, N-017 |
| F085 | AI chat panel | FeatAIChat | 3 | S-001, S-002, S-003, S-004, S-005, S-010, S-014, S-015, N-016 |
| F086 | AI provider settings | FeatAISettings | 3 | S-018, N-012 |
| F087 | AI actions (summaries, quiz, translate, diagrams, outline, titles) | FeatAIActions | 3 | D-007, D-051, D-068, S-004, S-006, S-007, S-008, S-009, S-010, S-011, S-012, S-013, S-044, N-018 |
| F088 | AI math: Solve & Teach Me | FeatAIMath | 3 | S-024, S-028, S-029, S-031, S-070 |
| F089 | Meeting AI: live summary, notes, cloud transcription | FeatMeetingAI | 3 | S-045, S-049, S-050, S-052, S-053, S-054, S-055, S-092, S-104 |
| F090 | MCP / HTTP bridge server | NibBridge | 1 | D-037, S-020, P-081, N-019, N-021 |
| F091 | Bridge settings & pairing | FeatBridgeUI | 1 | N-020 |
| F092 | Collaboration relay transport | FeatRelay | 3 | S-076, S-101, N-025 |
| F093 | Onboarding | FeatOnboarding | 4 | P-089, P-014 |
| F094 | Appearance & app icons | FeatAppearance | 4 | D-078, P-067, P-068, P-113 |
| F095 | Localisation & accessibility | FeatA11y | 4 | P-087, P-088 |
| F096 | Widgets & Control Center | NibWidgets | 4 | D-018, P-069 |
| F097 | Managed app configuration (MDM) | FeatManagedConfig | 4 | P-098, P-099, P-110, N-027 |
| F098 | About, parity notes, privacy & data deletion | FeatAbout | 4 | D-022, D-035, D-084, S-015, S-016, S-017, S-018, S-021, S-069, S-085, P-015, P-016, P-017, P-018, P-019, P-020, P-021, P-022, P-023, P-037, P-085, P-086, P-096, P-097, P-099, P-102, P-104, P-109, P-111, D-139, N-028 |
| F099 | Teacher toolkit: answer zones & scoring | FeatTeacher | 4 | S-031, S-070, S-096 |
| F109 | Teacher toolkit: lessons, assignments & roster | FeatTeacher | 4 | S-094, S-095, S-097, S-099, S-112, S-113, S-114, S-115 |
| F110 | Teacher toolkit: smart views, clusters & class navigator | FeatTeacher | 4 | S-098, S-109, S-110, S-111 |
| F100 | Performance, memory & metrics | FeatPerformance | 4 | P-091, P-095 |
| F111 | Integration tests & device smoke scripts | IntegrationTests | 4 | — |
