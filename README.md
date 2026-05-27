Rules for Documentation and LLM Agents
======================================

This repository stores cross‑product and platform documentation for Tofu projects.
All files here should be written in English to avoid encoding problems and to
make them easy to consume by humans and LLM tools.

General Principles
------------------

1. Keep documents short, structured, and focused on one topic.
2. Prefer incremental changes: improve and extend existing docs instead of rewriting everything.
3. Do not invent domain knowledge; describe only behaviour that is implemented or clearly planned.
4. Do not move or rename files unless it clearly improves navigation or follows an agreed structure.
5. Low‑level code details belong in the main product repositories, not in `Tofu.Docs`.
6. Use this repo for product‑level concepts, flows, APIs, decisions, and examples.
7. Avoid duplication; if duplication is unavoidable, pick a single source of truth and link to it.

Folder Index Files
------------------

1. Each folder should have a short `README.md` that explains:
   - what lives in this folder;
   - how documents are grouped;
   - where to start reading.
2. Keep folder READMEs focused on navigation, not deep explanations.

Platforms and Services
----------------------

1. Platform documentation lives under platform roots: `Backend`, `Android`, `IOS`, etc.
2. Inside each platform, use the `Services` folder for per‑service or bounded‑context docs.
3. Do not put deep service documentation directly in the platform root; keep it under `Services`.
4. Cross‑product topics (permissions, invitations, billing, etc.) live under the `features` folder.
5. When adding a new document:
   - first choose the platform (`Backend`, `Android`, `IOS`, etc.);
   - then choose between `Services` (for specific services) or `features` (for cross‑product topics);
   - avoid new top‑level folders unless explicitly agreed.
6. Platforms may also have a `HowTo` folder for task‑based guides
   (for example: `Backend/HowTo/Authorization.md`, `Backend/HowTo/Deploy.md`).

The `features` Folder
---------------------

1. Cross‑product features live under `features/<feature>/`.
2. Put shared, high‑level materials for a feature in `features/<feature>/`.
3. Platform‑specific details go into subfolders like
   `features/<feature>/Backend`, `features/<feature>/Android`, `features/<feature>/IOS`.
4. Do not create `Services` folders under `features`, and do not copy platform `HowTo` docs here.
5. For each feature:
   - describe general behaviour in `features/<feature>/`;
   - document platform specifics only where needed;
   - avoid mixing platform details into the shared overview.

Choosing Where to Put New Docs
------------------------------

1. Before creating a new doc, check what already exists for this platform or feature.
2. For backend‑driven topics, start from the `Backend` section.
3. For topics like authentication and permissions it is normal to have several entry points:
   - overview in `Backend/README.md`;
   - scenario‑based guides in `Backend/HowTo/*`;
   - cross‑product description in `features/<feature>`.
4. If a topic has both cross‑product and platform‑specific parts:
   - put the shared description into `features/<feature>`;
   - put platform details into the relevant platform folders (`Backend/HowTo`, `Backend/Services`, etc.).
5. If unclear, use this heuristic:
   - `Backend/HowTo` for “how to do X” guides;
   - `features/<feature>` for cross‑product concepts;
   - `Services` for deep technical details of a specific service.

Working with Tofu.Docs and Git
------------------------------

1. Make changes to `Tofu.Docs` from the root of the main repo.
2. After editing documentation, run the helper script with a short description:
   - `pwsh Tofu.Docs/scripts/commit-docs.ps1 -ShortDescription "Update docs (English)"`
3. The script will:
   - detect modified files in `Tofu.Docs`;
   - create a commit with message `<branch | repo | description>`;
   - run `git add`, `git commit`, and `git push` inside `Tofu.Docs`.
4. When other submodules or repos also have changes, double‑check which files belong to `Tofu.Docs/`.

About This File
---------------

This `README.md` defines where and how to store domain and product documentation
(for example, authentication, billing, onboarding) inside `Tofu.Docs`.
