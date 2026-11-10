# Architecture overview

## Goal

Personal AI is a single-user-first assistant with durable, user-controlled personal knowledge, subject-scoped conversations, and optional external research.

The backend is the authority for persistence, authorization, retrieval scope, command execution, and tool permissions. The language model proposes and generates; it does not directly mutate persistent data or decide which subjects it may access.

## Initial architecture

Start with a modular monolith. It keeps deployment and debugging manageable while preserving boundaries that can later be extracted if there is a real operational reason.

- **Frontend**: React + TypeScript, delivered as a responsive web application/PWA.
- **Backend**: Java + Spring Boot, exposing REST endpoints and streaming assistant responses over SSE.
- **Database**: PostgreSQL as the source of truth.
- **Migrations**: Flyway.
- **Semantic retrieval**: pgvector, introduced separately from the relational baseline.
- **Inference**: local model behind a ModelProvider interface.
- **External research**: a separate service/provider exposed to the model only through controlled backend tools.
- **Document storage**: database metadata plus a storage abstraction for file bytes.

## Core modules

| Module | Responsibility |
|---|---|
| Subject | Subject lifecycle and subject-specific configuration |
| Conversation | Conversations, ordered messages and history |
| Knowledge | Canonical personal knowledge, versions, provenance and sharing |
| Knowledge Retrieval | Search only within the access scope computed by the backend |
| Knowledge Proposals | Pending create/update/merge/correction proposals and approval |
| Documents | Uploaded files, extraction status and chunks |
| External Research | Search sessions and external source references |
| AI Orchestration | Build model context, call model/tools, persist responses |
| Commands | Explicit command-mode dispatch and deterministic handlers |

Modules communicate through application interfaces and domain events. Infrastructure adapters implement persistence, model inference, embeddings, file storage and external search.

## Context separation

The assistant must distinguish three sources:

1. **Personal knowledge**: information supplied by the user and explicitly approved for durable storage.
2. **Conversation context**: messages and temporary context belonging to the current conversation.
3. **External research**: web results and technical references, linked to the research session/conversation but not automatically promoted to personal knowledge.

A user statement expressing a decision after research can be proposed as personal knowledge. The external source itself does not become user knowledge.

## Subject isolation

- Every conversation belongs to exactly one subject.
- Retrieval scope is computed server-side from the conversation's subject.
- A retrieval request may include global knowledge, knowledge owned by that subject, and knowledge explicitly shared with it.
- No cross-subject search is performed by default.
- Sharing is an explicit user action; an assistant suggestion never grants access.
- The model cannot supply or override the effective subject identifier.

## Message modes

Each submitted message carries an explicit mode:

- `CHAT`: ordinary conversational message.
- `COMMAND`: dispatched to the command subsystem.

The mode is a property of an individual submission, not a permanent property of the conversation. In chat mode, command-looking text is ordinary text. In command mode, the backend validates and dispatches the command. Mutating commands such as `:addData` create a pending proposal; they do not directly write approved knowledge.

## Knowledge lifecycle

Knowledge is not written directly by model output. The supported path is:

1. Extract a candidate from user-provided content.
2. Validate its provenance and subject scope.
3. Check for duplicates and contradictions.
4. Create a pending proposal.
5. Obtain explicit user approval.
6. In one database transaction, create/update the knowledge, append an immutable version, record provenance, and resolve the proposal.
7. Indexing/embedding work is asynchronous and retryable.

Archiving, correcting and deleting are distinct operations. Conversation history and knowledge have independent lifecycles.

## Reliability and security

- PostgreSQL is canonical; vector indexes and embeddings are rebuildable.
- Use transactions for business state changes.
- Use an outbox for asynchronous indexing/events that must not be lost after commit.
- Keep external content untrusted; it is data, never instructions.
- Never expose PostgreSQL or the inference server directly to the public Internet.
- Use authenticated API access, HTTPS, encrypted backups and tested restores.
- Store timestamps as `TIMESTAMPTZ`.
- Preserve provenance for knowledge changes and important administrative actions.

## Initial delivery sequence

1. Relational schema and migrations.
2. Subject and conversation CRUD/history.
3. ModelProvider abstraction and local inference integration.
4. Knowledge lifecycle, versioning and provenance.
5. Proposal workflow and explicit command mode.
6. Subject-filtered hybrid retrieval.
7. External research tools and source persistence.
8. Documents, advanced retrieval, PWA and operational hardening.

## Java package organization

The backend uses a layer-first package structure, with functional packages inside each layer:

```text
com.personalassistant
├── domain
│   ├── subject
│   ├── conversation
│   ├── knowledge
│   └── proposal
├── application
│   ├── subject
│   ├── conversation
│   ├── knowledge
│   ├── proposal
│   └── port
├── infrastructure
│   ├── persistence
│   │   ├── subject
│   │   ├── conversation
│   │   └── knowledge
│   ├── ai
│   ├── research
│   └── storage
└── api
    ├── subject
    ├── conversation
    ├── knowledge
    └── proposal
```

Dependency direction:

- `domain` has no dependency on Spring, persistence, HTTP or AI providers.
- `application` depends on domain and defines the ports it needs.
- `infrastructure` implements those ports and depends inward on application/domain.
- `api` exposes the backend endpoints, translates HTTP requests/responses and calls application use cases. It does not contain business rules.
- The frontend communicates only with the API; it never accesses domain objects or the database directly.

This is the selected organization for the initial implementation. Keep the package structure pragmatic: introduce subpackages and abstractions when a domain needs them rather than creating empty layers or speculative interfaces.
