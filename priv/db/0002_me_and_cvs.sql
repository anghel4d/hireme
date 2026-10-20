-- me_and_cvs: the person moves from settings to me (and languages), and a
-- profile an application named becomes a composed CV root it is pinned to.
-- Hand-written: generated additions, the data, then settings drops its
-- columns and applications is rebuilt without profile_id (a column with a
-- foreign key cannot be dropped). The release applies it with foreign keys
-- off, so dropping the old applications deletes no row that names it.
CREATE TABLE "me" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "citizenships" TEXT,
  "field" TEXT,
  "subfields" TEXT,
  "residence_id" INTEGER REFERENCES "places"("id") ON DELETE SET NULL,
  "regions" TEXT,
  "relocate" INTEGER,
  "cv_default_root_id" INTEGER REFERENCES "cv_roots"("id") ON DELETE SET NULL,
  "work_modes" INTEGER,
  "employments" INTEGER,
  "pay_floor" INTEGER,
  "pay_currency" TEXT,
  "available_on" TEXT,
  "notice_days" INTEGER,
  "w_energy" REAL,
  "w_economy" REAL,
  "w_liveability" REAL,
  "w_mobility" REAL,
  "w_language" REAL,
  "w_tech" REAL,
  "w_ease" REAL
) STRICT;
CREATE UNIQUE INDEX "me__single_account_id" ON "me" ("account_id");
CREATE TRIGGER "me__ref_residence_id_insert" BEFORE INSERT ON "me" WHEN NEW."residence_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "places" WHERE "id" = NEW."residence_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref me.residence_id'); END;
CREATE TRIGGER "me__ref_residence_id_update" BEFORE UPDATE OF "residence_id", "account_id" ON "me" WHEN NEW."residence_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "places" WHERE "id" = NEW."residence_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref me.residence_id'); END;
CREATE TRIGGER "me__ref_cv_default_root_id_insert" BEFORE INSERT ON "me" WHEN NEW."cv_default_root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."cv_default_root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref me.cv_default_root_id'); END;
CREATE TRIGGER "me__ref_cv_default_root_id_update" BEFORE UPDATE OF "cv_default_root_id", "account_id" ON "me" WHEN NEW."cv_default_root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."cv_default_root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref me.cv_default_root_id'); END;
CREATE TABLE "languages" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "code" TEXT NOT NULL,
  "level" TEXT NOT NULL
) STRICT;
CREATE INDEX "languages__account_account_id" ON "languages" ("account_id");
CREATE UNIQUE INDEX "languages__natural_code" ON "languages" ("account_id", "code");
CREATE TABLE "cv_roots" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "deleted_at" TEXT,
  "slug" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "format" TEXT NOT NULL,
  "profile_id" INTEGER REFERENCES "profiles"("id") ON DELETE SET NULL,
  "notes" TEXT,
  "version_id" INTEGER REFERENCES "cv_versions"("id") ON DELETE SET NULL
) STRICT;
CREATE INDEX "cv_roots__account_account_id" ON "cv_roots" ("account_id");
CREATE UNIQUE INDEX "cv_roots__unique_slug" ON "cv_roots" ("account_id", "slug") WHERE "deleted_at" IS NULL;
CREATE TRIGGER "cv_roots__ref_profile_id_insert" BEFORE INSERT ON "cv_roots" WHEN NEW."profile_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "profiles" WHERE "id" = NEW."profile_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_roots.profile_id'); END;
CREATE TRIGGER "cv_roots__ref_profile_id_update" BEFORE UPDATE OF "profile_id", "account_id" ON "cv_roots" WHEN NEW."profile_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "profiles" WHERE "id" = NEW."profile_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_roots.profile_id'); END;
CREATE TRIGGER "cv_roots__ref_version_id_insert" BEFORE INSERT ON "cv_roots" WHEN NEW."version_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_versions" WHERE "id" = NEW."version_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_roots.version_id'); END;
CREATE TRIGGER "cv_roots__ref_version_id_update" BEFORE UPDATE OF "version_id", "account_id" ON "cv_roots" WHEN NEW."version_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_versions" WHERE "id" = NEW."version_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_roots.version_id'); END;
CREATE TABLE "cv_versions" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "root_id" INTEGER NOT NULL REFERENCES "cv_roots"("id") ON DELETE CASCADE,
  "n" INTEGER NOT NULL,
  "body" TEXT,
  "blob_sha" TEXT,
  "blob_name" TEXT,
  "blob_type" TEXT,
  "blob_bytes" INTEGER,
  "text" TEXT,
  "note" TEXT,
  "actor" TEXT NOT NULL,
  "key_id" INTEGER
) STRICT;
CREATE INDEX "cv_versions__account_account_id" ON "cv_versions" ("account_id");
CREATE INDEX "cv_versions__index_root_id_id_desc" ON "cv_versions" ("account_id", "root_id", "id" DESC);
CREATE TRIGGER "cv_versions__ref_root_id_insert" BEFORE INSERT ON "cv_versions" WHEN NEW."root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_versions.root_id'); END;
CREATE TRIGGER "cv_versions__ref_root_id_update" BEFORE UPDATE OF "root_id", "account_id" ON "cv_versions" WHEN NEW."root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_versions.root_id'); END;
CREATE TABLE "blobs" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "sha" TEXT NOT NULL,
  "type" TEXT NOT NULL,
  "bytes" INTEGER NOT NULL,
  "data" BLOB NOT NULL,
  "text" TEXT
) STRICT;
CREATE INDEX "blobs__account_account_id" ON "blobs" ("account_id");
CREATE UNIQUE INDEX "blobs__unique_sha" ON "blobs" ("account_id", "sha");
CREATE TABLE "cv_masks" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "pattern" TEXT NOT NULL,
  "note" TEXT
) STRICT;
CREATE INDEX "cv_masks__account_account_id" ON "cv_masks" ("account_id");
CREATE UNIQUE INDEX "cv_masks__unique_name" ON "cv_masks" ("account_id", "name");
CREATE TABLE "cv_rules" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "position" INTEGER NOT NULL DEFAULT 0,
  "root_id" INTEGER NOT NULL REFERENCES "cv_roots"("id") ON DELETE CASCADE,
  "name" TEXT,
  "pattern" TEXT NOT NULL,
  "enabled" INTEGER NOT NULL DEFAULT 1
) STRICT;
CREATE INDEX "cv_rules__account_account_id" ON "cv_rules" ("account_id");
CREATE INDEX "cv_rules__index_position" ON "cv_rules" ("account_id", "position");
CREATE TRIGGER "cv_rules__ref_root_id_insert" BEFORE INSERT ON "cv_rules" WHEN NEW."root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_rules.root_id'); END;
CREATE TRIGGER "cv_rules__ref_root_id_update" BEFORE UPDATE OF "root_id", "account_id" ON "cv_rules" WHEN NEW."root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref cv_rules.root_id'); END;


-- The person, from settings; the w_* weights keep their meaning.
INSERT INTO "me" ("account_id", "rev", "inserted_at", "updated_at", "citizenships", "field", "w_energy", "w_economy", "w_liveability", "w_mobility", "w_language", "w_tech", "w_ease")
  SELECT "account_id", 1, "inserted_at", "updated_at", "citizenships", "field", "w_energy", "w_economy", "w_liveability", "w_mobility", "w_language", "w_tech", "w_ease" FROM "settings";
-- settings.languages was U+001F-joined codes with no level: each becomes a row at c1.
WITH RECURSIVE split("account_id", "code", "rest", "at") AS (
  SELECT "account_id", '', "languages" || char(31), "updated_at" FROM "settings" WHERE "languages" IS NOT NULL
  UNION ALL
  SELECT "account_id", substr("rest", 1, instr("rest", char(31)) - 1), substr("rest", instr("rest", char(31)) + 1), "at" FROM split WHERE "rest" != ''
)
INSERT OR IGNORE INTO "languages" ("account_id", "rev", "inserted_at", "updated_at", "code", "level")
  SELECT DISTINCT "account_id", 1, "at", "at", lower(trim("code")), 'c1' FROM split WHERE trim("code") != '';
-- Every profile becomes a composed root of its own slug and name.
INSERT INTO "cv_roots" ("account_id", "rev", "inserted_at", "updated_at", "slug", "name", "format", "profile_id")
  SELECT "account_id", 1, "inserted_at", "updated_at", "slug", "name", 'composed', "id" FROM "profiles";

ALTER TABLE "settings" DROP COLUMN "citizenships";
ALTER TABLE "settings" DROP COLUMN "languages";
ALTER TABLE "settings" DROP COLUMN "field";
ALTER TABLE "settings" DROP COLUMN "w_energy";
ALTER TABLE "settings" DROP COLUMN "w_economy";
ALTER TABLE "settings" DROP COLUMN "w_liveability";
ALTER TABLE "settings" DROP COLUMN "w_mobility";
ALTER TABLE "settings" DROP COLUMN "w_language";
ALTER TABLE "settings" DROP COLUMN "w_tech";
ALTER TABLE "settings" DROP COLUMN "w_ease";

PRAGMA legacy_alter_table = ON;
CREATE TABLE "applications__new" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
  "rev" INTEGER NOT NULL DEFAULT 1,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "no" INTEGER NOT NULL,
  "corporation_id" INTEGER REFERENCES "corporations"("id") ON DELETE SET NULL,
  "place_id" INTEGER REFERENCES "places"("id") ON DELETE SET NULL,
  "contact_id" INTEGER REFERENCES "contacts"("id") ON DELETE SET NULL,
  "batch_id" INTEGER REFERENCES "batches"("id") ON DELETE SET NULL,
  "company" TEXT,
  "role" TEXT,
  "location" TEXT,
  "work_mode" TEXT,
  "employment" TEXT,
  "comp_raw" TEXT,
  "channel" TEXT,
  "listing_raw" TEXT,
  "listing_format" TEXT,
  "listing_url" TEXT,
  "canonical_url" TEXT,
  "listing_on" TEXT,
  "keywords" TEXT,
  "keywords_version" INTEGER,
  "source_id" INTEGER REFERENCES "sources"("id") ON DELETE SET NULL,
  "stage" TEXT NOT NULL DEFAULT 'discovered',
  "pips" TEXT,
  "stage_on" TEXT,
  "stage_notes" TEXT,
  "status" TEXT NOT NULL DEFAULT 'open',
  "gate" TEXT,
  "freshness" TEXT,
  "heat_override" INTEGER NOT NULL DEFAULT 0,
  "heat_override_reason" TEXT,
  "score_100" INTEGER,
  "applied_on" TEXT,
  "replied_on" TEXT,
  "closed_on" TEXT,
  "outcome" TEXT,
  "notes" TEXT,
  "battleplan" TEXT,
  "letter_raw" TEXT,
  "cv_theme" TEXT,
  "cv_root_id" INTEGER REFERENCES "cv_roots"("id") ON DELETE SET NULL,
  "cv_pinned_by" TEXT,
  "cv_version_id" INTEGER REFERENCES "cv_versions"("id") ON DELETE SET NULL
) STRICT;
-- A profile an application named is now its pin, set by the operator.
INSERT INTO "applications__new" ("id", "account_id", "rev", "inserted_at", "updated_at", "no", "corporation_id", "place_id", "contact_id", "batch_id", "company", "role", "location", "work_mode", "employment", "comp_raw", "channel", "listing_raw", "listing_format", "listing_url", "canonical_url", "listing_on", "keywords", "keywords_version", "source_id", "stage", "pips", "stage_on", "stage_notes", "status", "gate", "freshness", "heat_override", "heat_override_reason", "score_100", "applied_on", "replied_on", "closed_on", "outcome", "notes", "battleplan", "letter_raw", "cv_theme", "cv_root_id", "cv_pinned_by", "cv_version_id")
  SELECT a."id", a."account_id", a."rev", a."inserted_at", a."updated_at", a."no", a."corporation_id", a."place_id", a."contact_id", a."batch_id", a."company", a."role", a."location", a."work_mode", a."employment", a."comp_raw", a."channel", a."listing_raw", a."listing_format", a."listing_url", a."canonical_url", a."listing_on", a."keywords", a."keywords_version", a."source_id", a."stage", a."pips", a."stage_on", a."stage_notes", a."status", a."gate", a."freshness", a."heat_override", a."heat_override_reason", a."score_100", a."applied_on", a."replied_on", a."closed_on", a."outcome", a."notes", a."battleplan", a."letter_raw", a."cv_theme", r."id", CASE WHEN r."id" IS NULL THEN NULL ELSE 'operator' END, NULL
  FROM "applications" a LEFT JOIN "cv_roots" r ON r."profile_id" = a."profile_id" AND r."account_id" = a."account_id";
DROP TABLE "applications";
ALTER TABLE "applications__new" RENAME TO "applications";
CREATE INDEX "applications__account_account_id" ON "applications" ("account_id");
CREATE UNIQUE INDEX "applications__natural_canonical_url" ON "applications" ("account_id", "canonical_url") WHERE canonical_url is not null;
CREATE UNIQUE INDEX "applications__unique_no" ON "applications" ("account_id", "no");
CREATE INDEX "applications__index_stage" ON "applications" ("account_id", "stage");
CREATE INDEX "applications__index_corporation_id" ON "applications" ("account_id", "corporation_id");
CREATE INDEX "applications__index_batch_id" ON "applications" ("account_id", "batch_id");
CREATE TRIGGER "applications__ref_corporation_id_insert" BEFORE INSERT ON "applications" WHEN NEW."corporation_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "corporations" WHERE "id" = NEW."corporation_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.corporation_id'); END;
CREATE TRIGGER "applications__ref_corporation_id_update" BEFORE UPDATE OF "corporation_id", "account_id" ON "applications" WHEN NEW."corporation_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "corporations" WHERE "id" = NEW."corporation_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.corporation_id'); END;
CREATE TRIGGER "applications__ref_place_id_insert" BEFORE INSERT ON "applications" WHEN NEW."place_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "places" WHERE "id" = NEW."place_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.place_id'); END;
CREATE TRIGGER "applications__ref_place_id_update" BEFORE UPDATE OF "place_id", "account_id" ON "applications" WHEN NEW."place_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "places" WHERE "id" = NEW."place_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.place_id'); END;
CREATE TRIGGER "applications__ref_contact_id_insert" BEFORE INSERT ON "applications" WHEN NEW."contact_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "contacts" WHERE "id" = NEW."contact_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.contact_id'); END;
CREATE TRIGGER "applications__ref_contact_id_update" BEFORE UPDATE OF "contact_id", "account_id" ON "applications" WHEN NEW."contact_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "contacts" WHERE "id" = NEW."contact_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.contact_id'); END;
CREATE TRIGGER "applications__ref_batch_id_insert" BEFORE INSERT ON "applications" WHEN NEW."batch_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "batches" WHERE "id" = NEW."batch_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.batch_id'); END;
CREATE TRIGGER "applications__ref_batch_id_update" BEFORE UPDATE OF "batch_id", "account_id" ON "applications" WHEN NEW."batch_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "batches" WHERE "id" = NEW."batch_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.batch_id'); END;
CREATE TRIGGER "applications__ref_source_id_insert" BEFORE INSERT ON "applications" WHEN NEW."source_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "sources" WHERE "id" = NEW."source_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.source_id'); END;
CREATE TRIGGER "applications__ref_source_id_update" BEFORE UPDATE OF "source_id", "account_id" ON "applications" WHEN NEW."source_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "sources" WHERE "id" = NEW."source_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.source_id'); END;
CREATE TRIGGER "applications__ref_cv_root_id_insert" BEFORE INSERT ON "applications" WHEN NEW."cv_root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."cv_root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.cv_root_id'); END;
CREATE TRIGGER "applications__ref_cv_root_id_update" BEFORE UPDATE OF "cv_root_id", "account_id" ON "applications" WHEN NEW."cv_root_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_roots" WHERE "id" = NEW."cv_root_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.cv_root_id'); END;
CREATE TRIGGER "applications__ref_cv_version_id_insert" BEFORE INSERT ON "applications" WHEN NEW."cv_version_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_versions" WHERE "id" = NEW."cv_version_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.cv_version_id'); END;
CREATE TRIGGER "applications__ref_cv_version_id_update" BEFORE UPDATE OF "cv_version_id", "account_id" ON "applications" WHEN NEW."cv_version_id" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "cv_versions" WHERE "id" = NEW."cv_version_id" AND "account_id" IS NEW."account_id") BEGIN SELECT RAISE(ABORT, 'ref applications.cv_version_id'); END;
PRAGMA legacy_alter_table = OFF;
