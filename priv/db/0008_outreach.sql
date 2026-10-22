-- outreach: the messages table becomes outreach, the OutreachItem rows
-- (docs/mail/outreach_type.md). Written by hand: a rename, a dropped
-- column and the renamed indexes and triggers are no additive step, so the
-- table is rebuilt from the declaration's DDL and its rows carried over:
-- channel becomes kind (x becomes x_dm), sent_at becomes at, status goes
-- (derived now), and every row that predates the type was the system's.
-- Its number and its surviving column ids stay; the dropped status column
-- is retired in schema/hireme.schema.
CREATE TABLE "outreach" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "direction" TEXT,
  "from_addr" TEXT,
  "to_addr" TEXT,
  "cc_addr" TEXT,
  "subject" TEXT,
  "body" TEXT,
  "message_id" TEXT,
  "thread_key" TEXT,
  "at" TEXT,
  "corporation_id" INTEGER REFERENCES "corporations"("id") ON DELETE SET NULL,
  "application_id" INTEGER REFERENCES "applications"("id") ON DELETE SET NULL,
  "contact_id" INTEGER REFERENCES "contacts"("id") ON DELETE SET NULL,
  "mission_id" INTEGER REFERENCES "missions"("id") ON DELETE SET NULL,
  "link" TEXT,
  "report" TEXT,
  "actor" TEXT NOT NULL DEFAULT 'system',
  "filing" TEXT NOT NULL DEFAULT 'unfiled',
  "filed_by" TEXT,
  "evidence" TEXT,
  "seen" INTEGER NOT NULL DEFAULT 0,
  "bounced_at" TEXT,
  "reply_to" TEXT,
  "in_reply_to" TEXT,
  "refs" TEXT,
  "gmail_msgid" INTEGER,
  "gmail_thrid" INTEGER,
  "labels" TEXT,
  "headers" TEXT,
  "pipe" TEXT,
  "handle" TEXT,
  "fields" TEXT,
  "reference" TEXT,
  "channel" TEXT
) STRICT;
INSERT INTO "outreach" ("id", "account_id", "rev", "inserted_at", "updated_at", "kind", "direction", "from_addr", "to_addr", "cc_addr", "subject", "body", "message_id", "thread_key", "at", "corporation_id", "application_id", "contact_id", "actor")
  SELECT "id", "account_id", "rev", "inserted_at", "updated_at", CASE "channel" WHEN 'x' THEN 'x_dm' ELSE "channel" END, "direction", "from_addr", "to_addr", "cc_addr", "subject", "body", "message_id", "thread_key", "sent_at", "corporation_id", "application_id", "contact_id", 'system' FROM "messages";
DROP TABLE "messages";
CREATE INDEX "outreach__account_account_id" ON "outreach" ("account_id");
CREATE UNIQUE INDEX "outreach__natural_message_id" ON "outreach" ("account_id", "message_id") WHERE message_id is not null;
CREATE INDEX "outreach__index_thread_key" ON "outreach" ("account_id", "thread_key");
CREATE INDEX "outreach__index_application_id" ON "outreach" ("account_id", "application_id");
CREATE INDEX "outreach__index_contact_id" ON "outreach" ("account_id", "contact_id");
CREATE INDEX "outreach__index_mission_id" ON "outreach" ("account_id", "mission_id");
CREATE INDEX "outreach__index_at_desc" ON "outreach" ("account_id", "at" DESC);
CREATE TRIGGER "outreach__ref_corporation_id_insert" BEFORE INSERT ON "outreach" WHEN NEW."corporation_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "corporations" WHERE "id" = NEW."corporation_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.corporation_id'); END;
CREATE TRIGGER "outreach__ref_corporation_id_update" BEFORE UPDATE OF "corporation_id", "account_id" ON "outreach" WHEN NEW."corporation_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "corporations" WHERE "id" = NEW."corporation_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.corporation_id'); END;
CREATE TRIGGER "outreach__ref_application_id_insert" BEFORE INSERT ON "outreach" WHEN NEW."application_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "applications" WHERE "id" = NEW."application_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.application_id'); END;
CREATE TRIGGER "outreach__ref_application_id_update" BEFORE UPDATE OF "application_id", "account_id" ON "outreach" WHEN NEW."application_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "applications" WHERE "id" = NEW."application_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.application_id'); END;
CREATE TRIGGER "outreach__ref_contact_id_insert" BEFORE INSERT ON "outreach" WHEN NEW."contact_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "contacts" WHERE "id" = NEW."contact_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.contact_id'); END;
CREATE TRIGGER "outreach__ref_contact_id_update" BEFORE UPDATE OF "contact_id", "account_id" ON "outreach" WHEN NEW."contact_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "contacts" WHERE "id" = NEW."contact_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.contact_id'); END;
CREATE TRIGGER "outreach__ref_mission_id_insert" BEFORE INSERT ON "outreach" WHEN NEW."mission_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "missions" WHERE "id" = NEW."mission_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.mission_id'); END;
CREATE TRIGGER "outreach__ref_mission_id_update" BEFORE UPDATE OF "mission_id", "account_id" ON "outreach" WHEN NEW."mission_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "missions" WHERE "id" = NEW."mission_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref outreach.mission_id'); END;
