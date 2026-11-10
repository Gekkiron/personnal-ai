-- Initial relational schema for Personal AI.
-- PostgreSQL 15+ recommended. UUID generation uses gen_random_uuid().
-- Do not modify this migration after it has been applied; add a new Flyway migration.

CREATE TABLE subjects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(150) NOT NULL,
    description     TEXT,
    icon            VARCHAR(50),
    system_prompt   TEXT,
    preferred_model VARCHAR(150),
    is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_subjects_name UNIQUE (name)
);

CREATE TABLE subject_settings (
    subject_id          UUID PRIMARY KEY REFERENCES subjects(id) ON DELETE CASCADE,
    retrieval_enabled   BOOLEAN NOT NULL DEFAULT TRUE,
    web_search_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
    model_temperature   REAL,
    context_limit       INTEGER,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_subject_settings_temperature
        CHECK (model_temperature IS NULL OR model_temperature BETWEEN 0 AND 2),
    CONSTRAINT ck_subject_settings_context_limit
        CHECK (context_limit IS NULL OR context_limit > 0)
);

CREATE TABLE conversations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id  UUID NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
    title       VARCHAR(255),
    status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    model_used  VARCHAR(150),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_conversations_status CHECK (status IN ('ACTIVE', 'ARCHIVED'))
);

CREATE INDEX ix_conversations_subject_updated
    ON conversations(subject_id, updated_at DESC);

CREATE TABLE messages (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id  UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sequence_number  BIGINT NOT NULL,
    role             VARCHAR(20) NOT NULL,
    message_mode     VARCHAR(20) NOT NULL DEFAULT 'CHAT',
    content          TEXT NOT NULL,
    metadata         JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_messages_conversation_sequence UNIQUE (conversation_id, sequence_number),
    CONSTRAINT ck_messages_role CHECK (role IN ('USER', 'ASSISTANT', 'SYSTEM', 'TOOL')),
    CONSTRAINT ck_messages_mode CHECK (message_mode IN ('CHAT', 'COMMAND'))
);

CREATE INDEX ix_messages_conversation_created
    ON messages(conversation_id, sequence_number);

CREATE TABLE knowledge (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scope             VARCHAR(20) NOT NULL,
    owner_subject_id  UUID REFERENCES subjects(id) ON DELETE RESTRICT,
    title             VARCHAR(255) NOT NULL,
    content           TEXT NOT NULL,
    knowledge_type    VARCHAR(30) NOT NULL,
    status            VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    valid_from        TIMESTAMPTZ,
    valid_until       TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_knowledge_scope_owner CHECK (
        (scope = 'GLOBAL' AND owner_subject_id IS NULL)
        OR (scope = 'SUBJECT' AND owner_subject_id IS NOT NULL)
    ),
    CONSTRAINT ck_knowledge_type CHECK (
        knowledge_type IN ('FACT', 'PREFERENCE', 'GOAL', 'DECISION', 'CONSTRAINT', 'OTHER')
    ),
    CONSTRAINT ck_knowledge_status CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    CONSTRAINT ck_knowledge_validity CHECK (
        valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from
    )
);

CREATE INDEX ix_knowledge_owner_status
    ON knowledge(owner_subject_id, status);
CREATE INDEX ix_knowledge_scope_status
    ON knowledge(scope, status);
CREATE INDEX ix_knowledge_validity
    ON knowledge(valid_from, valid_until);

CREATE TABLE knowledge_versions (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    knowledge_id      UUID NOT NULL REFERENCES knowledge(id) ON DELETE RESTRICT,
    version_number    INTEGER NOT NULL,
    title_snapshot    VARCHAR(255) NOT NULL,
    content_snapshot  TEXT NOT NULL,
    knowledge_type    VARCHAR(30) NOT NULL,
    status_snapshot   VARCHAR(20) NOT NULL,
    change_type       VARCHAR(20) NOT NULL,
    change_reason     TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_knowledge_versions_number UNIQUE (knowledge_id, version_number),
    CONSTRAINT ck_knowledge_versions_number CHECK (version_number > 0),
    CONSTRAINT ck_knowledge_versions_type CHECK (
        knowledge_type IN ('FACT', 'PREFERENCE', 'GOAL', 'DECISION', 'CONSTRAINT', 'OTHER')
    ),
    CONSTRAINT ck_knowledge_versions_status CHECK (status_snapshot IN ('ACTIVE', 'ARCHIVED')),
    CONSTRAINT ck_knowledge_versions_change CHECK (
        change_type IN ('CREATE', 'UPDATE', 'ARCHIVE', 'RESTORE')
    )
);

CREATE INDEX ix_knowledge_versions_knowledge_created
    ON knowledge_versions(knowledge_id, created_at DESC);

CREATE TABLE documents (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename      VARCHAR(512) NOT NULL,
    mime_type     VARCHAR(255) NOT NULL,
    storage_path  TEXT NOT NULL,
    file_hash     VARCHAR(128) NOT NULL,
    size_bytes    BIGINT NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'UPLOADED',
    uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_documents_size CHECK (size_bytes >= 0),
    CONSTRAINT ck_documents_status CHECK (
        status IN ('UPLOADED', 'PROCESSING', 'READY', 'FAILED', 'ARCHIVED')
    )
);

CREATE INDEX ix_documents_file_hash ON documents(file_hash);

CREATE TABLE document_chunks (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id  UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index  INTEGER NOT NULL,
    content      TEXT NOT NULL,
    page_number  INTEGER,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_document_chunks_index UNIQUE (document_id, chunk_index),
    CONSTRAINT ck_document_chunks_index CHECK (chunk_index >= 0),
    CONSTRAINT ck_document_chunks_page CHECK (page_number IS NULL OR page_number > 0)
);

CREATE TABLE knowledge_sources (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    knowledge_id     UUID NOT NULL REFERENCES knowledge(id) ON DELETE RESTRICT,
    source_type      VARCHAR(20) NOT NULL,
    message_id       UUID REFERENCES messages(id) ON DELETE SET NULL,
    document_id      UUID REFERENCES documents(id) ON DELETE SET NULL,
    original_content TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_knowledge_sources_type CHECK (source_type IN ('USER_MESSAGE', 'USER_DOCUMENT')),
    CONSTRAINT ck_knowledge_sources_exactly_one_source CHECK (
        (source_type = 'USER_MESSAGE'
            AND document_id IS NULL
            AND (message_id IS NOT NULL OR original_content IS NOT NULL))
        OR
        (source_type = 'USER_DOCUMENT'
            AND message_id IS NULL
            AND (document_id IS NOT NULL OR original_content IS NOT NULL))
    )
);

CREATE INDEX ix_knowledge_sources_knowledge ON knowledge_sources(knowledge_id);

CREATE TABLE knowledge_subject_access (
    knowledge_id  UUID NOT NULL REFERENCES knowledge(id) ON DELETE CASCADE,
    subject_id    UUID NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
    granted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (knowledge_id, subject_id)
);

CREATE INDEX ix_knowledge_subject_access_subject
    ON knowledge_subject_access(subject_id);

CREATE TABLE knowledge_proposals (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id       UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    subject_id            UUID NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
    message_id            UUID REFERENCES messages(id) ON DELETE SET NULL,
    proposal_type         VARCHAR(20) NOT NULL DEFAULT 'CREATE',
    proposal_origin       VARCHAR(20) NOT NULL,
    target_knowledge_id   UUID REFERENCES knowledge(id) ON DELETE RESTRICT,
    proposed_scope        VARCHAR(20) NOT NULL DEFAULT 'SUBJECT',
    title                 VARCHAR(255) NOT NULL,
    content               TEXT NOT NULL,
    knowledge_type        VARCHAR(30) NOT NULL,
    status                VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at           TIMESTAMPTZ,
    CONSTRAINT ck_knowledge_proposals_type CHECK (
        proposal_type IN ('CREATE', 'UPDATE', 'MERGE', 'CORRECTION')
    ),
    CONSTRAINT ck_knowledge_proposals_origin CHECK (
        proposal_origin IN ('USER_COMMAND', 'AI_SUGGESTION')
    ),
    CONSTRAINT ck_knowledge_proposals_scope CHECK (proposed_scope IN ('GLOBAL', 'SUBJECT')),
    CONSTRAINT ck_knowledge_proposals_knowledge_type CHECK (
        knowledge_type IN ('FACT', 'PREFERENCE', 'GOAL', 'DECISION', 'CONSTRAINT', 'OTHER')
    ),
    CONSTRAINT ck_knowledge_proposals_status CHECK (
        status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')
    ),
    CONSTRAINT ck_knowledge_proposals_resolution CHECK (
        (status = 'PENDING' AND resolved_at IS NULL)
        OR (status <> 'PENDING' AND resolved_at IS NOT NULL)
    ),
    CONSTRAINT ck_knowledge_proposals_target CHECK (
        (proposal_type = 'CREATE' AND target_knowledge_id IS NULL)
        OR (proposal_type <> 'CREATE' AND target_knowledge_id IS NOT NULL)
    )
);

CREATE INDEX ix_knowledge_proposals_inbox
    ON knowledge_proposals(status, created_at DESC);
CREATE INDEX ix_knowledge_proposals_conversation
    ON knowledge_proposals(conversation_id, created_at DESC);

CREATE TABLE research_sessions (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id  UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    query            TEXT NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at     TIMESTAMPTZ,
    CONSTRAINT ck_research_sessions_status CHECK (
        status IN ('PENDING', 'COMPLETED', 'FAILED', 'CANCELLED')
    )
);

CREATE INDEX ix_research_sessions_conversation
    ON research_sessions(conversation_id, created_at DESC);

CREATE TABLE research_sources (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    research_session_id UUID NOT NULL REFERENCES research_sessions(id) ON DELETE CASCADE,
    url                 TEXT NOT NULL,
    title               TEXT,
    domain              VARCHAR(255),
    published_at        TIMESTAMPTZ,
    retrieved_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    excerpt             TEXT,
    content_hash        VARCHAR(128),
    CONSTRAINT uq_research_sources_session_url UNIQUE (research_session_id, url)
);

CREATE TABLE audit_events (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type    VARCHAR(100) NOT NULL,
    aggregate_type VARCHAR(100) NOT NULL,
    aggregate_id  UUID,
    actor_type    VARCHAR(30) NOT NULL,
    details       JSONB NOT NULL DEFAULT '{}'::JSONB,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_audit_events_actor CHECK (
        actor_type IN ('USER', 'SYSTEM', 'ASSISTANT', 'ADMIN')
    )
);

CREATE INDEX ix_audit_events_aggregate
    ON audit_events(aggregate_type, aggregate_id, occurred_at DESC);

CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type  VARCHAR(100) NOT NULL,
    aggregate_id    UUID NOT NULL,
    event_type      VARCHAR(150) NOT NULL,
    payload         JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ,
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    CONSTRAINT ck_outbox_events_attempts CHECK (attempts >= 0)
);

CREATE INDEX ix_outbox_events_pending
    ON outbox_events(created_at)
    WHERE processed_at IS NULL;

-- Application-level invariants that must be enforced by the services:
-- 1. A USER_MESSAGE knowledge source must reference a message whose role is USER.
-- 2. A USER_DOCUMENT knowledge source must reference a document uploaded by the user.
-- 3. A proposal's conversation_id and subject_id must match the conversation's subject.
-- 4. A GLOBAL knowledge item cannot have knowledge_subject_access rows.
-- 5. A SUBJECT knowledge item cannot be shared with its owner subject.
-- 6. Only approved proposals may create/update canonical knowledge.
-- 7. Version snapshots are append-only; never UPDATE or DELETE them in normal flows.
-- 8. The sequence_number for a conversation is allocated transactionally.
